import CoreLocation
import MapKit
import PhoneOnlyCore
import RemoteAPI

/// One leg of road from Apple Maps, between two stops: its points (starting at the first stop and ending at
/// the second), its length and how long Apple expects it to take. This iPhone drives these itself; in Mac
/// mode they go to the Mac with the route, so it drives the same roads.
struct AppleMapsLeg: Sendable {
    var points: [StandaloneRoute.Point]
    var meters: Double
    var expectedSeconds: Double?

    /// The request for one leg. Kept by the caller while it runs, so it can be cancelled.
    @MainActor
    static func directions(from a: StandaloneRoute.Point, to b: StandaloneRoute.Point, driving: Bool) -> MKDirections {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: a.latitude, longitude: a.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: b.latitude, longitude: b.longitude)))
        request.transportType = driving ? .automobile : .walking
        return MKDirections(request: request)
    }

    @MainActor
    static func calculate(_ directions: MKDirections, from a: StandaloneRoute.Point,
                          to b: StandaloneRoute.Point) async throws -> AppleMapsLeg {
        // Older MapKit SDKs return a non-Sendable Response from the async overlay. Convert it
        // inside the completion callback so only our Sendable points cross back to the actor.
        try await withCheckedThrowingContinuation { continuation in
            directions.calculate { response, error in
                if let error { continuation.resume(throwing: error); return }
                guard let best = response?.routes.first, case let polyline = best.polyline, polyline.pointCount >= 2,
                      polyline.pointCount <= 100_000 else {
                    continuation.resume(throwing: StandaloneRoute.Problem.invalid)
                    return
                }
                var coordinates = [CLLocationCoordinate2D](repeating: .init(), count: polyline.pointCount)
                polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
                // Explicit endpoints preserve the chosen stops and continuity between legs.
                let seconds = best.expectedTravelTime
                continuation.resume(returning: AppleMapsLeg(
                    points: [a] + coordinates.map { StandaloneRoute.Point($0.latitude, $0.longitude) } + [b],
                    meters: best.distance, expectedSeconds: seconds > 0 ? seconds : nil))
            }
        }
    }
}

/// The roads of a route for the Mac to drive (Mac mode): one Apple Maps leg per pair of stops, and the way
/// back for a loop, thinned to a size the Mac takes.
enum MacRouteLegs {
    /// Legs shorter than this go straight, as on the Mac: Apple Maps can't do better over a few metres.
    static let shortLeg = 25.0
    /// All legs together, at most: a few hundred kilometres of road, well inside what the Mac accepts.
    static let maxPoints = 30_000

    /// The stops each leg joins, in order: the route's own, and back to the first for a loop that doesn't
    /// end there (the same rule as `RouteRequest.usableLegs`).
    static func stops(of request: RouteRequest) -> [StandaloneRoute.Point] {
        var stops = request.waypoints.map { StandaloneRoute.Point($0.latitude, $0.longitude) }
        if request.loopMode == "loop", let first = request.waypoints.first, let last = request.waypoints.last,
           first.latitude != last.latitude || first.longitude != last.longitude {
            stops.append(stops[0])
        }
        return stops
    }

    /// What goes on the wire: each leg thinned (all of them together under `maxPoints`), nil where Apple
    /// Maps had no road. nil when no leg has one: the Mac then finds the roads itself.
    static func wire(_ legs: [AppleMapsLeg?]) -> [RoadLeg?]? {
        guard legs.contains(where: { $0 != nil }) else { return nil }
        let thinned = RouteSimplifier.simplify(
            legs: legs.map { $0?.points.map { GeoPoint($0.latitude, $0.longitude) } }, maxPoints: maxPoints)
        return zip(legs, thinned).map { leg, points in
            guard let leg, let points else { return nil }
            return RoadLeg(points: points.map { ($0.latitude, $0.longitude) }, meters: leg.meters,
                           expectedSeconds: leg.expectedSeconds)
        }
    }
}
