import Foundation
import MapKit
import SpooferCore

/// Road-following geometry between waypoints, via Apple Maps directions.
/// Legs are cached, so editing one waypoint only re-requests its two legs.
@MainActor
final class DirectionsService {
    static let shared = DirectionsService()

    /// Why a leg fell back to a straight line.
    enum Failure: Error, Equatable {
        /// Apple Maps has no route there (across water, no roads or paths).
        case noRoute
        /// Apple Maps limits how many directions one Mac can ask for in a
        /// minute; a long route with many stops can hit that.
        case busy
        /// No answer: offline, or Apple's servers had a problem.
        case unreachable

        /// Worth asking again later.
        var isTemporary: Bool { self != .noRoute }

        /// Which reason to show when legs failed for different ones: the
        /// fixable kind first.
        var rank: Int {
            switch self {
            case .unreachable: 2
            case .busy: 1
            case .noRoute: 0
            }
        }
    }

    struct Result: Sendable {
        let points: [GeoPoint]
        let failedLegs: Int
        let failure: Failure?
    }

    private var cache: [String: [GeoPoint]] = [:]

    /// Legs shorter than this are drawn straight without asking: Apple Maps
    /// can't do better over a few metres, and may answer "no route".
    private static let shortLeg = 25.0

    private init() {}

    func route(through waypoints: [GeoPoint], mode: TravelMode) async -> Result {
        guard waypoints.count >= 2 else { return Result(points: waypoints, failedLegs: 0, failure: nil) }
        var points: [GeoPoint] = []
        var failed = 0
        var failure: Failure?
        for (a, b) in zip(waypoints, waypoints.dropFirst()) {
            if Task.isCancelled { break }
            var leg: [GeoPoint]
            let key = Self.key(a, b, mode)
            if let cached = cache[key] {
                leg = cached
            } else if Geo.distance(a, b) < Self.shortLeg {
                leg = [a, b]
            } else {
                // Once a leg has used up its retries for a temporary reason,
                // the rest get one try each: offline, every leg would wait.
                switch await Self.fetchLeg(from: a, to: b, mode: mode, retries: failure?.isTemporary == true ? 0 : 2) {
                case .success(let fetched):
                    leg = fetched
                    // A leg primed meanwhile (the iPhone's, for a route it sent) is the one to keep.
                    if cache[key] == nil { cache[key] = fetched }
                    if cache.count > 500 { cache.removeAll() }
                case .failure(let reason):
                    leg = [a, b]
                    failed += 1
                    if reason.rank >= (failure?.rank ?? -1) { failure = reason }
                }
            }
            // Pin the leg to the exact waypoints so the drawn route meets the pins.
            leg[0] = a
            leg[leg.count - 1] = b
            if !points.isEmpty { leg.removeFirst() }
            points += leg
        }
        return Result(points: points, failedLegs: failed, failure: failure)
    }

    /// A leg found elsewhere (the iPhone's Apple Maps, for a route it sent), so it isn't asked for again
    /// and the Mac drives the same roads the iPhone showed.
    func prime(from a: GeoPoint, to b: GeoPoint, mode: TravelMode, points: [GeoPoint]) {
        guard points.count >= 2 else { return }
        if cache.count >= 500 { cache.removeAll() }
        cache[Self.key(a, b, mode)] = points
    }

    private static func key(_ a: GeoPoint, _ b: GeoPoint, _ mode: TravelMode) -> String {
        String(format: "%.6f,%.6f>%.6f,%.6f|", a.latitude, a.longitude, b.latitude, b.longitude) + mode.rawValue
    }

    private static func fetchLeg(from a: GeoPoint, to b: GeoPoint, mode: TravelMode,
                                 retries: Int) async -> Swift.Result<[GeoPoint], Failure> {
        var attempt = 0
        while true {
            let result = await requestLeg(from: a, to: b, mode: mode)
            guard case .failure(let reason) = result, reason.isTemporary, attempt < retries else { return result }
            attempt += 1
            // A busy answer clears within a minute; a dropped connection often
            // sooner. The waits stay short so the route shows up quickly.
            try? await Task.sleep(for: .seconds(attempt == 1 ? 2 : 6))
            if Task.isCancelled { return result }
        }
    }

    private static func requestLeg(from a: GeoPoint, to b: GeoPoint,
                                   mode: TravelMode) async -> Swift.Result<[GeoPoint], Failure> {
        #if DEBUG
        // SPOOFER_DIRECTIONS_FAIL=busy|unreachable|noRoute: pretend Apple Maps
        // answered that way, to see how the app handles it.
        switch ProcessInfo.processInfo.environment["SPOOFER_DIRECTIONS_FAIL"] {
        case "busy": return .failure(.busy)
        case "unreachable": return .failure(.unreachable)
        case "noRoute": return .failure(.noRoute)
        default: break
        }
        #endif
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: a.latitude, longitude: a.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: b.latitude, longitude: b.longitude)))
        request.transportType = mode == .walking ? .walking : .automobile
        request.requestsAlternateRoutes = false
        let directions = MKDirections(request: request)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Swift.Result<[GeoPoint], Failure>, Never>) in
            directions.calculate { response, error in
                guard let polyline = response?.routes.first?.polyline, polyline.pointCount >= 2 else {
                    continuation.resume(returning: .failure(Self.classify(error)))
                    return
                }
                var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
                polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
                continuation.resume(returning: .success(coords.map { GeoPoint($0.latitude, $0.longitude) }))
            }
        }
    }

    nonisolated static func classify(_ error: Error?) -> Failure {
        guard let error else { return .noRoute }
        if let mapKit = error as? MKError {
            switch mapKit.code {
            case .directionsNotFound, .placemarkNotFound: return .noRoute
            case .loadingThrottled: return .busy
            default: return .unreachable
            }
        }
        return .unreachable
    }
}

extension DirectionsService.Failure {
    /// "1 leg uses a straight line" / "3 legs use straight lines".
    static func legs(_ count: Int) -> String {
        count == 1 ? "1 leg uses a straight line" : "\(count) legs use straight lines"
    }

    /// For the route card, after "N legs use straight lines".
    var shortReason: String {
        switch self {
        case .noRoute: "Apple Maps has no route there."
        case .busy: "Apple Maps is busy. Try again in a minute."
        case .unreachable: "Couldn't reach Apple Maps."
        }
    }

    /// For the activity log.
    func logLine(failedLegs count: Int, mode: TravelMode) -> String {
        switch self {
        case .noRoute:
            "Apple Maps has no \(mode.label.lowercased()) route there, so \(Self.legs(count))."
        case .busy:
            "Apple Maps is getting too many requests from this Mac, so \(Self.legs(count)). Click Try Again in a minute."
        case .unreachable:
            "Couldn't reach Apple Maps, so \(Self.legs(count)). Check the internet connection, then click Try Again."
        }
    }
}
