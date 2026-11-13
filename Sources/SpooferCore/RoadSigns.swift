import Foundation

/// Which signs and lights near a route are for traffic going the route's way,
/// worked out from the roads they're mapped on. OpenStreetMap puts a stop or
/// yield sign on its road just before the junction it's for, and tags lights and
/// signs that face one way with `traffic_signals:direction` or `direction`.
/// A divided road is two one-way roads side by side: a light on the other half is
/// for the traffic going the other way. Without the roads (they're loaded for
/// driving), everything near the route counts.
struct RoadSigns {
    enum Travel { case forward, backward }

    /// How a light or sign met on the route bears on one way of travelling it.
    enum Fit: Equatable {
        /// On the road the route is on, for traffic going this way.
        case own
        /// A light that isn't on the route's road this way but marks a junction with lights: on a cross
        /// street, on the other half of a divided road where a road crosses, or on a road that wasn't
        /// loaded. It counts only where the route's own road has no light of its own nearby, so the car
        /// doesn't stop twice at one junction.
        case standIn
        /// Not for traffic going this way.
        case none
    }

    private let ways: [OSMWay]
    /// Node id → each road it's on, and where along it.
    private let placements: [Int64: [(way: Int, index: Int)]]
    /// Nodes where three or more road ends meet (driveways and car parks don't count).
    private let junctions: Set<Int64>

    init(ways: [OSMWay], signs: Set<Int64>) {
        var placements: [Int64: [(way: Int, index: Int)]] = [:]
        var degree: [Int64: Int] = [:]
        for (w, way) in ways.enumerated() where !way.nodeIDs.isEmpty && way.nodeIDs.count == way.points.count {
            let last = way.nodeIDs.count - 1
            for (i, id) in way.nodeIDs.enumerated() {
                if signs.contains(id) { placements[id, default: []].append((w, i)) }
                if way.tags["highway"] != "service" { degree[id, default: 0] += i == 0 || i == last ? 1 : 2 }
            }
        }
        self.ways = ways
        self.placements = placements
        junctions = Set(degree.filter { $0.value >= 3 }.keys)
    }

    /// How `node`, met `distance` metres along `path`, bears on going along the route and on coming back
    /// the other way.
    func fit(of node: OSMNode, kind: RoadFeature.Kind, along path: RoutePath,
             at distance: Double) -> (forward: Fit, backward: Fit) {
        guard kind != .signalCrossing else { return (.own, .own) }
        guard let places = placements[node.id], !places.isEmpty else {
            // On no road that was loaded. A light may still mark the junction; a sign is taken as the route's.
            let fit: Fit = kind == .trafficSignal ? .standIn : .own
            return (fit, fit)
        }
        return (fit(node, kind: kind, places: places, heading: Self.heading(along: path, at: distance, back: false)),
                fit(node, kind: kind, places: places, heading: Self.heading(along: path, at: distance, back: true)))
    }

    private func fit(_ node: OSMNode, kind: RoadFeature.Kind, places: [(way: Int, index: Int)],
                     heading: Double) -> Fit {
        var onRoute = false, onOtherHalf = false, onCrossStreet = false
        for place in places {
            let way = ways[place.way]
            guard let travel = Self.travel(on: way, at: place.index, heading: heading) else {
                onCrossStreet = true
                continue
            }
            // A one-way road the route would run against is the other half of a divided road.
            if let allowed = Self.oneWay(way), allowed != travel {
                onOtherHalf = true
                continue
            }
            onRoute = true
            if let faces = facing(of: node, kind: kind, on: way, at: place.index), faces != travel { continue }
            return .own
        }
        // On the route's road but for the other way, or a sign on some other road.
        guard !onRoute, kind == .trafficSignal else { return .none }
        // The other half's light between junctions is its own crossing light, nothing to do with this side.
        if onOtherHalf, !onCrossStreet, !junctions.contains(node.id) { return .none }
        return .standIn
    }

    /// Which way along `way` traffic may go, when it may only go one way.
    static func oneWay(_ way: OSMWay) -> Travel? {
        switch way.tags["oneway"]?.lowercased() {
        case "yes", "true", "1": return .forward
        case "-1", "reverse": return .backward
        case .some: return nil
        case nil: break
        }
        if ["roundabout", "circular"].contains(way.tags["junction"] ?? "") || way.tags["highway"] == "motorway" {
            return .forward
        }
        return nil
    }

    /// Which way along `way` the sign or light at `index` faces traffic; nil for both ways.
    private func facing(of node: OSMNode, kind: RoadFeature.Kind, on way: OSMWay, at index: Int) -> Travel? {
        let key = kind == .trafficSignal ? "traffic_signals:direction" : "direction"
        switch node.tags[key]?.lowercased() {
        case "forward": return .forward
        case "backward": return .backward
        default: break
        }
        // An untagged stop or yield sign, or light, is for traffic heading into the junction
        // just past it. One on the junction itself (an all-way stop, a light mapped on the
        // crossing) is for everyone.
        guard kind == .stopSign || kind == .giveWay || kind == .trafficSignal, node.tags["stop"] != "all",
              !junctions.contains(node.id) else { return nil }
        switch (junctionDistance(on: way, from: index, step: 1), junctionDistance(on: way, from: index, step: -1)) {
        case let (ahead?, behind?): return abs(ahead - behind) < 5 ? nil : (ahead < behind ? .forward : .backward)
        case (_?, nil): return .forward
        case (nil, _?): return .backward
        case (nil, nil): return nil
        }
    }

    /// Metres along `way` from `index` to the nearest junction that way (`step`
    /// is +1 or −1), if there's one within 40 m.
    private func junctionDistance(on way: OSMWay, from index: Int, step: Int) -> Double? {
        var travelled = 0.0
        var i = index
        while i + step >= 0, i + step < way.points.count {
            travelled += Geo.distance(way.points[i], way.points[i + step])
            if travelled > 40 { return nil }
            i += step
            if junctions.contains(way.nodeIDs[i]) { return travelled }
        }
        return nil
    }

    /// Which way the route goes along `way` at `index`; nil when it isn't on that road there.
    static func travel(on way: OSMWay, at index: Int, heading: Double) -> Travel? {
        let p = way.points, n = p.count
        guard n >= 2, index >= 0, index < n else { return nil }
        let forward = index > 0 ? Geo.bearing(from: p[index - 1], to: p[index]) : Geo.bearing(from: p[0], to: p[1])
        let backward = index < n - 1 ? Geo.bearing(from: p[index + 1], to: p[index])
                                     : Geo.bearing(from: p[n - 1], to: p[n - 2])
        if abs(Geo.bearingDelta(from: heading, to: forward)) < 35 { return .forward }
        if abs(Geo.bearingDelta(from: heading, to: backward)) < 35 { return .backward }
        return nil
    }

    /// The route's heading over the 10 m before `distance`; for the way back,
    /// coming from the 10 m beyond it.
    static func heading(along path: RoutePath, at distance: Double, back: Bool) -> Double {
        let length = path.length
        let d = min(max(distance, 0), length)
        if back {
            let from = min(length, d + 10), to = max(0, min(d, from - 10))
            return Geo.bearing(from: path.sample(at: from).point, to: path.sample(at: to).point)
        }
        let from = max(0, d - 10), to = min(length, max(d, from + 10))
        return Geo.bearing(from: path.sample(at: from).point, to: path.sample(at: to).point)
    }
}
