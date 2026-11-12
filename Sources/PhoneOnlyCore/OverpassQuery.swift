import Foundation

/// How AnyWhere asks OpenStreetMap's public Overpass API about the roads under a route. Shared by the
/// Mac's trip planner (which also asks for lights and signs) and the iPhone's speed limits.
public enum OverpassQuery {
    /// Public Overpass instances: the main one first, then others for when it's busy or unreachable
    /// (some networks and VPNs can't reach every one).
    public static let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
    ]

    /// How far from the route a road may be and still be the one it drives on, in metres.
    public static let roadRadius = 6.0

    /// Pieces of at most 15 km, simplified to 150 points or fewer; `padding` widens the search by how
    /// far the simplified line may stray.
    public static func chunks(of path: RoutePath) -> [(points: [GeoPoint], padding: Double)] {
        guard path.points.count >= 2 else { return [] }
        var chunks: [(points: [GeoPoint], padding: Double)] = []
        var start = 0
        while start < path.points.count - 1 {
            var end = start + 1
            while end < path.points.count - 1, path.cumulative[end] - path.cumulative[start] < 15_000 { end += 1 }
            let piece = Array(path.points[start...end])
            var tolerance = 2.0
            var simple = RouteSimplifier.simplify(piece, tolerance: tolerance)
            while simple.count > 150 && tolerance < 200 {
                tolerance *= 1.6
                simple = RouteSimplifier.simplify(piece, tolerance: tolerance)
            }
            chunks.append((simple, tolerance))
            start = end
        }
        return chunks
    }

    /// The points of a line for an `around` filter: "lat,lon,lat,lon…".
    public static func line(_ points: [GeoPoint]) -> String {
        points.map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }.joined(separator: ",")
    }

    /// The roads for cars within `radius` metres of `line`.
    public static func roadClause(radius: Int, line: String) -> String {
        "way(around:\(radius),\(line))"
            + "[highway~\"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|service|road)(_link)?$\"];"
    }

    /// Only the roads (with their shapes and tags) near a piece of route.
    public static func roads(for points: [GeoPoint], padding: Double) -> String {
        let radius = Int((roadRadius + padding).rounded(.up))
        return "[out:json][timeout:25];(" + roadClause(radius: radius, line: line(points)) + ");out geom;"
    }

    /// A query as the form body Overpass expects.
    public static func body(_ query: String) -> Data {
        Data("data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)".utf8)
    }
}

/// The speed limits along a route, from OpenStreetMap: each road's `maxspeed`, or the usual limit for
/// its kind of road when it has none (the same rules as the Mac's trips). For the iPhone-only mode,
/// which has no Mac to ask. Only the route's own pieces are sent, to the public Overpass servers.
public struct RoadSpeedLimits: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let userAgent: String
    let timeBudget: Double
    let transport: Transport

    /// `timeBudget` is the most the whole lookup may take, in seconds: past that, the route drives with
    /// what has loaded (and the chosen speed where nothing has).
    public init(userAgent: String, timeBudget: Double = 20,
                transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.userAgent = userAgent
        self.timeBudget = timeBudget
        self.transport = transport
    }

    /// The limits along `points`, as stretches by distance from the first point (metres). Empty when
    /// nothing could be loaded: no network, or no roads for cars under the route.
    public func zones(along points: [GeoPoint]) async -> [SpeedZone] {
        let path = RoutePath(points)
        guard path.length > 0 else { return [] }
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(1, timeBudget)))
        var ways: [Int64: OSMWay] = [:]
        var failuresInARow = 0
        for chunk in OverpassQuery.chunks(of: path) {
            guard !Task.isCancelled, ContinuousClock.now < deadline, failuresInARow < 3 else { break }
            if let answer = await fetch(OverpassQuery.roads(for: chunk.points, padding: chunk.padding), deadline: deadline) {
                for way in answer.ways { ways[way.id] = way }
                failuresInARow = 0
            } else {
                failuresInARow += 1
            }
        }
        return SpeedLimits.zones(along: path, ways: Array(ways.values))
    }

    /// One piece, from the first server that answers in time.
    private func fetch(_ query: String, deadline: ContinuousClock.Instant) async -> OverpassAnswer? {
        for endpoint in OverpassQuery.endpoints {
            let left = ContinuousClock.now.duration(to: deadline)
            let seconds = Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
            guard seconds > 0.5, !Task.isCancelled else { return nil }
            var request = URLRequest(url: endpoint, timeoutInterval: min(12, seconds))
            request.httpMethod = "POST"
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = OverpassQuery.body(query)
            do {
                let (data, response) = try await transport(request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                return try OverpassAnswer.decode(data)
            } catch {
                continue   // unreachable, too slow, busy or unreadable: the next server
            }
        }
        return nil
    }
}
