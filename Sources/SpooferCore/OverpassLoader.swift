import Foundation
import PhoneOnlyCore

/// Loads traffic lights, stop and yield signs, signal crossings, speed bumps and
/// speed limits near a route from OpenStreetMap's public Overpass API: in pieces
/// of about 15 km, one request at a time, cached on disk for 30 days.
public struct OverpassLoader: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Public Overpass instances: the main one first, then others for when it's
    /// busy or unreachable (some networks and VPNs can't reach every one).
    public static let endpoints = OverpassQuery.endpoints

    /// Seconds to wait for one server before trying the next.
    static let requestTimeout: TimeInterval = 25

    /// Seconds one lookup may take in all, however long the route. Past that,
    /// what has loaded is used and the rest is left for a later try (every piece
    /// that loaded is cached, so a later try only asks for what is missing).
    public static let defaultTimeBudget: TimeInterval = 90

    /// Pieces in a row that no server could answer, before the rest are left
    /// for a later try: a network that failed three times is not about to work.
    static let giveUpAfter = 3

    let userAgent: String
    let cacheDirectory: URL?
    let timeBudget: TimeInterval
    let transport: Transport
    /// Which servers answered lately, so later lookups start with one that works.
    private let servers: ServerOrder

    public init(userAgent: String, cacheDirectory: URL?, timeBudget: TimeInterval = defaultTimeBudget,
                transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.userAgent = userAgent
        self.cacheDirectory = cacheDirectory
        self.timeBudget = timeBudget
        self.transport = transport
        servers = ServerOrder(Self.endpoints)
    }

    /// The device has no way to reach anyone, so trying more servers is pointless.
    static func isOffline(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(error.code)
    }

    /// The servers to try, best first: one that answered moves to the front,
    /// one that failed to the back.
    actor ServerOrder {
        private var order: [URL]

        init(_ order: [URL]) { self.order = order }

        var current: [URL] { order }

        func answered(_ url: URL) {
            order.removeAll { $0 == url }
            order.insert(url, at: 0)
        }

        func failed(_ url: URL) {
            guard order.count > 1, order.contains(url) else { return }
            order.removeAll { $0 == url }
            order.append(url)
        }
    }

    /// Search radii in metres around the route. Lights cover a whole junction;
    /// signs must be on the route's own road, not a side street.
    static let signalRadius = 18.0, signRadius = 6.0, crossingRadius = 12.0, roadRadius = 6.0
    /// How far along the route a junction's lights reach: a cross street's light, or the other half of a
    /// divided road's, within this of the route's own light belongs to the same junction.
    static let junctionReach = 50.0

    /// Everything known along `path`. `roads` also loads the roads themselves
    /// (for driving): their speed limits, and which signs are for which direction.
    public func features(along path: RoutePath, roads: Bool,
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> RoadFeatures {
        if let cacheDirectory { Self.pruneCache(cacheDirectory) }
        let chunks = Self.chunks(of: path)
        guard !chunks.isEmpty else { return .none }
        var nodes: [Int64: OSMNode] = [:]
        var ways: [Int64: OSMWay] = [:]
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, timeBudget)))
        var loaded = 0, failures = 0, leftOut = 0
        var failuresInARow = 0
        var offline = false
        var lastError: Error?
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            // Out of time, or the servers have failed several pieces running: use what
            // loaded. (Offline, pieces already cached still load, and cost nothing.)
            if ContinuousClock.now >= deadline {
                lastError = lastError ?? SpoofError("road data took too long to load")
                leftOut = chunks.count - index
                break
            }
            if failuresInARow >= Self.giveUpAfter, !offline {
                leftOut = chunks.count - index
                break
            }
            do {
                let answer = try await fetch(Self.query(for: chunk.points, padding: chunk.padding, roads: roads),
                                             deadline: deadline, cacheOnly: offline)
                for node in answer.nodes { nodes[node.id] = node }
                for way in answer.ways { ways[way.id] = way }
                loaded += 1
                failuresInARow = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                failuresInARow += 1
                lastError = error
                if Self.isOffline(error) { offline = true }
            }
            progress?(Double(index + 1) / Double(chunks.count))
        }
        if loaded == 0, let lastError { throw lastError }
        var features = Self.features(from: OverpassAnswer(nodes: Array(nodes.values), ways: Array(ways.values)),
                                     along: path)
        features.complete = failures == 0 && leftOut == 0
        return features
    }

    // MARK: Queries

    /// Pieces of at most 15 km, simplified to 150 points or fewer; `padding`
    /// widens the search by how far the simplified line may stray.
    static func chunks(of path: RoutePath) -> [(points: [GeoPoint], padding: Double)] {
        OverpassQuery.chunks(of: path)
    }

    static func query(for points: [GeoPoint], padding: Double, roads: Bool) -> String {
        let line = OverpassQuery.line(points)
        func r(_ base: Double) -> Int { Int((base + padding).rounded(.up)) }
        var parts = [
            "node(around:\(r(signalRadius)),\(line))[highway=traffic_signals];",
            "node(around:\(r(signRadius)),\(line))[highway~\"^(stop|give_way)$\"];",
            "node(around:\(r(crossingRadius)),\(line))[highway=crossing][crossing=traffic_signals];",
            "node(around:\(r(signRadius)),\(line))[traffic_calming~\"^(bump|hump|table|cushion|yes)$\"];",
        ]
        if roads {
            parts.append(OverpassQuery.roadClause(radius: r(roadRadius), line: line))
        }
        return "[out:json][timeout:25];(" + parts.joined() + ");out geom;"
    }

    public static func parse(_ data: Data) throws -> OverpassAnswer {
        do {
            return try OverpassAnswer.decode(data)
        } catch let problem as OverpassAnswer.Remark {
            throw SpoofError("OpenStreetMap couldn't answer: \(problem.text)")
        }
    }

    /// What a node is, how near the route it must be (metres), and for traffic
    /// calming the speed over it.
    static func classify(_ node: OSMNode) -> (kind: RoadFeature.Kind, radius: Double, speed: Double?)? {
        switch node.tags["highway"] {
        case "traffic_signals":
            // Lights only for emergency vehicles, flashing ones and ramp meters don't stop traffic.
            if ["emergency", "blinker", "ramp_meter"].contains(node.tags["traffic_signals"] ?? "") { return nil }
            return (.trafficSignal, signalRadius, nil)
        case "stop":
            return (.stopSign, signRadius, nil)
        case "give_way":
            return (.giveWay, signRadius, nil)
        case "crossing" where node.tags["crossing"] == "traffic_signals":
            return (.signalCrossing, crossingRadius, nil)
        default:
            guard let value = node.tags["traffic_calming"], let speed = TripOdds.calmingSpeed(value) else { return nil }
            return (.trafficCalming, signRadius, speed)
        }
    }

    /// Places an answer's nodes along `path` and turns its roads into speed zones.
    public static func features(from answer: OverpassAnswer, along path: RoutePath) -> RoadFeatures {
        let matcher = RouteMatcher(path: path)
        let signs = RoadSigns(ways: answer.ways, signs: Set(answer.nodes.map(\.id)))
        var found: [(feature: RoadFeature, forward: RoadSigns.Fit, backward: RoadSigns.Fit)] = []
        for node in answer.nodes.sorted(by: { $0.id < $1.id }) {
            guard let (kind, radius, speed) = classify(node) else { continue }
            var passes = matcher.passes(near: node.point, radius: radius)
            // A closed loop starts and ends at the same place: something near it
            // is met once, as the lap ends.
            if path.isClosed, passes.count >= 2, let first = passes.first, let last = passes.last,
               first.distance < 40, last.distance > path.length - 40 {
                passes.removeFirst()
            }
            for pass in passes {
                let fit = signs.fit(of: node, kind: kind, along: path, at: pass.distance)
                guard fit.forward != .none || fit.backward != .none else { continue }
                found.append((RoadFeature(kind: kind, distance: pass.distance, point: node.point, speed: speed),
                              fit.forward, fit.backward))
            }
        }
        // Only signs and lights for the route's direction (out and back: either). A light that only
        // marks the junction counts where the route's own road has no light nearby going that way.
        func ownLight(near distance: Double, forward: Bool) -> Bool {
            found.contains { other in
                other.feature.kind == .trafficSignal && (forward ? other.forward : other.backward) == .own
                    && abs(other.feature.distance - distance) <= junctionReach
            }
        }
        var features: [RoadFeature] = []
        for item in found {
            func counts(_ fit: RoadSigns.Fit, forward: Bool) -> Bool {
                switch fit {
                case .own: return true
                case .standIn: return !ownLight(near: item.feature.distance, forward: forward)
                case .none: return false
                }
            }
            let forward = counts(item.forward, forward: true), backward = counts(item.backward, forward: false)
            guard forward || backward else { continue }
            var feature = item.feature
            feature.facing = forward && backward ? .both : (forward ? .forward : .backward)
            features.append(feature)
        }
        var kept = firstOfEachJunction(features)
        // A crossing light at a junction with traffic lights is part of that
        // junction's lights: only mid-block crossing lights stand on their own.
        let lights = kept.filter { $0.kind == .trafficSignal }.map(\.distance)
        kept.removeAll { feature in
            feature.kind == .signalCrossing && lights.contains { abs($0 - feature.distance) < 40 }
        }
        return RoadFeatures(features: kept, zones: SpeedLimits.zones(along: path, ways: answer.ways))
    }

    /// A junction often has a light on each approach: one stop per 30 m (signs
    /// and bumps: 15 m), the first one met. Going along the route and coming
    /// back, the first one met can differ, so each direction picks its own.
    static func firstOfEachJunction(_ features: [RoadFeature]) -> [RoadFeature] {
        let sorted = features.sorted { $0.distance < $1.distance }
        func firsts(in order: [Int], facing: RoadFeature.Facing) -> Set<Int> {
            var kept = Set<Int>()
            var last: [RoadFeature.Kind: Double] = [:]
            for i in order where sorted[i].facing.overlaps(facing) {
                let feature = sorted[i]
                let gap: Double = feature.kind == .trafficSignal || feature.kind == .signalCrossing ? 30 : 15
                if let previous = last[feature.kind], abs(feature.distance - previous) < gap { continue }
                last[feature.kind] = feature.distance
                kept.insert(i)
            }
            return kept
        }
        let forward = firsts(in: Array(sorted.indices), facing: .forward)
        let backward = firsts(in: sorted.indices.reversed(), facing: .backward)
        return sorted.indices.compactMap { i in
            var feature = sorted[i]
            switch (forward.contains(i), backward.contains(i)) {
            case (true, true): feature.facing = .both
            case (true, false): feature.facing = .forward
            case (false, true): feature.facing = .backward
            case (false, false): return nil
            }
            return feature
        }
    }

    // MARK: Fetching

    /// Seconds from now until `deadline` (negative when it has passed).
    private static func seconds(until deadline: ContinuousClock.Instant) -> Double {
        let left = deadline - ContinuousClock.now
        return Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
    }

    /// One piece of road data: from the cache, else from the first server that answers.
    /// `cacheOnly` is for when the device is offline: only the cache is worth asking.
    private func fetch(_ query: String, deadline: ContinuousClock.Instant, cacheOnly: Bool) async throws -> OverpassAnswer {
        let cacheFile = cacheDirectory?.appendingPathComponent(Self.cacheName(for: query))
        if let cacheFile, let attributes = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 30 * 86_400,
           let data = try? Data(contentsOf: cacheFile), let answer = try? Self.parse(data) {
            return answer
        }
        if cacheOnly { throw URLError(.notConnectedToInternet) }
        var lastError: Error = SpoofError("couldn't reach OpenStreetMap")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        /// A server that answered with an error is given a moment before the next is asked.
        /// One that couldn't be reached at all is not worth waiting for.
        var pause = false
        for (index, endpoint) in await servers.current.enumerated() {
            if index > 0 {
                if Self.seconds(until: deadline) <= 0 { break }
                if pause { try await Task.sleep(for: .seconds(1)) }
            }
            let patience = min(Self.requestTimeout, max(1, Self.seconds(until: deadline)))
            var request = URLRequest(url: endpoint, timeoutInterval: patience)
            request.httpMethod = "POST"
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("data=\(encoded)".utf8)
            attempts: for attempt in 0..<2 {
                do {
                    let (data, response) = try await transport(request)
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    if status == 200 {
                        let answer = try Self.parse(data)
                        await servers.answered(endpoint)
                        if let cacheFile {
                            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                                                     withIntermediateDirectories: true)
                            try? data.write(to: cacheFile)
                        }
                        return answer
                    }
                    lastError = SpoofError("OpenStreetMap answered \(status)")
                    pause = true
                    // Out of turns (429): leave this server alone for now; it asks for 30 s.
                    // Busy (503, 504): wait a moment and ask it once more, if there is time.
                    guard attempt == 0, [503, 504].contains(status) else { break attempts }
                    let wait = min(10, max(1, http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 3))
                    guard Self.seconds(until: deadline) > wait else { break attempts }
                    try await Task.sleep(for: .seconds(wait))
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw CancellationError()
                } catch let error as URLError where Self.isOffline(error) {
                    throw error   // no network at all: the other servers can't be reached either
                } catch {
                    // Unreachable, timed out, or an answer it couldn't read: the next server.
                    lastError = error
                    pause = false
                    break attempts
                }
            }
            await servers.failed(endpoint)
        }
        throw lastError
    }

    /// Answers older than 30 days are no use (they're refetched): remove them.
    static func pruneCache(_ directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "json" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) > 30 * 86_400 {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// FNV-1a: a stable file name for a query.
    static func cacheName(for query: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in query.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0100_0000_01B3 }
        return String(format: "%016llx.json", hash)
    }
}
