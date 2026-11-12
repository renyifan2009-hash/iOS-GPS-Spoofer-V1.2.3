import Foundation
import RemoteAPI
import SpooferCore

/// A route on the roads the iPhone sent with it (`RouteRequest.legs`): the legs joined end to end, where
/// each of your stops falls along them, and Apple Maps' typical speed for each leg, for the stretches
/// OpenStreetMap has no limit for.
public struct RoadRoute: Sendable, Equatable {
    /// Through every stop in order, on the roads (straight where a leg had none). A loop's way back to the
    /// start is part of it when it was sent.
    public let path: RoutePath
    /// Metres along `path` of each waypoint, in the request's order: the stop numbers the iPhone shows.
    public let stopDistances: [Double]
    /// Apple Maps' expected speed for each leg that has one, as stretches of `path`.
    public let legZones: [SpeedZone]
    /// How many legs had a road.
    public let roadLegs: Int

    /// How far a leg may start or end from the stop it joins, metres. The iPhone pins its legs to the
    /// stops, so anything further is a leg meant for some other route.
    static let endTolerance = 150.0

    /// nil when the request has no legs, or they don't fit its stops.
    public init?(request: RouteRequest) {
        guard request.isValid, let legs = request.usableLegs else { return nil }
        let stops = request.waypoints.map { GeoPoint($0.latitude, $0.longitude) }
        var ends = stops
        if legs.count == stops.count { ends.append(stops[0]) }   // a loop's way back
        var points: [GeoPoint] = [ends[0]]
        /// Index in `points` where each leg ends.
        var legEnds: [Int] = []
        var roads = 0
        for (i, leg) in legs.enumerated() {
            let a = ends[i], b = ends[i + 1]
            var piece = [a, b]
            if let leg {
                let raw = leg.points.map { GeoPoint($0.latitude, $0.longitude) }
                guard let first = raw.first, let last = raw.last,
                      Geo.distance(first, a) <= Self.endTolerance, Geo.distance(last, b) <= Self.endTolerance
                else { return nil }
                // Pinned to the exact stops, so the route meets the pins and the legs meet each other.
                piece = raw
                piece[0] = a
                piece[piece.count - 1] = b
                roads += 1
            }
            points += piece.dropFirst()
            legEnds.append(points.count - 1)
        }
        let path = RoutePath(points)
        guard path.length > 0 else { return nil }
        var zones: [SpeedZone] = []
        var start = 0.0
        for (leg, end) in zip(legs, legEnds) {
            let finish = path.cumulative[end]
            if let leg, let seconds = leg.expectedSeconds,
               let speed = SpeedZone.cruise(meters: leg.meters ?? (finish - start), expectedSeconds: seconds),
               finish > start {
                zones.append(SpeedZone(start: start, end: finish, speed: speed))
            }
            start = finish
        }
        self.path = path
        stopDistances = [0] + legEnds.prefix(stops.count - 1).map { path.cumulative[$0] }
        legZones = zones
        roadLegs = roads
    }
}
