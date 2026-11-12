import Foundation

/// A WGS-84 coordinate in decimal degrees.
public struct GeoPoint: Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(_ latitude: Double, _ longitude: Double) {
        self.init(latitude: latitude, longitude: longitude)
    }

    /// Finite and within ±90° / ±180°.
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    /// The farthest north or south MapKit's flat (Mercator) world reaches, in degrees. Past it the
    /// map has no place to put a point, and some MapKit calls (setCenter among them) raise an
    /// Objective-C exception that nothing can catch: the app aborts. The device can legitimately be
    /// at a pole, so only the map's camera is kept inside.
    public static let mapMaxLatitude = 85.0

    /// This point as something the map can be centred on: nil when it isn't a real place (NaN,
    /// infinite, out of range), otherwise with the latitude held inside the map's world.
    public var mapSafe: GeoPoint? {
        guard isValid else { return nil }
        return GeoPoint(latitude: min(max(latitude, -Self.mapMaxLatitude), Self.mapMaxLatitude), longitude: longitude)
    }

    /// True when both components are within `tolerance` degrees of `other`'s.
    public func isClose(to other: GeoPoint, tolerance: Double = 1e-9) -> Bool {
        abs(latitude - other.latitude) <= tolerance && abs(longitude - other.longitude) <= tolerance
    }

    public func distance(to other: GeoPoint) -> Double { Geo.distance(self, other) }
    public func bearing(to other: GeoPoint) -> Double { Geo.bearing(from: self, to: other) }
    public func moved(by distance: Double, bearing: Double) -> GeoPoint {
        Geo.destination(from: self, distance: distance, bearing: bearing)
    }
}

/// Spherical-earth geodesy. Accurate to well under 0.5% — plenty for moving a
/// simulated location around.
public enum Geo {
    public static let earthRadius = 6_371_000.0

    @inline(__always) package static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    @inline(__always) package static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Great-circle (haversine) distance in metres.
    public static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let dLat = radians(b.latitude - a.latitude)
        let dLon = radians(b.longitude - a.longitude)
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(radians(a.latitude)) * cos(radians(b.latitude)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from true north in [0, 360).
    public static func bearing(from a: GeoPoint, to b: GeoPoint) -> Double {
        let φ1 = radians(a.latitude), φ2 = radians(b.latitude)
        let Δλ = radians(b.longitude - a.longitude)
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return normalizedBearing(degrees(atan2(y, x)))
    }

    /// The point `distance` metres from `start` along `bearing` (degrees).
    public static func destination(from start: GeoPoint, distance: Double, bearing: Double) -> GeoPoint {
        guard distance != 0 else { return start }
        let δ = distance / earthRadius
        let θ = radians(bearing)
        let φ1 = radians(start.latitude), λ1 = radians(start.longitude)
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return GeoPoint(latitude: degrees(φ2), longitude: normalizedLongitude(degrees(λ2)))
    }

    /// Straight-line interpolation in lat/lon space (fine for the short segments
    /// routes are made of), taking the short way across the antimeridian.
    public static func interpolate(_ a: GeoPoint, _ b: GeoPoint, fraction t: Double) -> GeoPoint {
        var dLon = b.longitude - a.longitude
        if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
        return GeoPoint(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: normalizedLongitude(a.longitude + dLon * t)
        )
    }

    /// Wrap a longitude into [-180, 180].
    public static func normalizedLongitude(_ longitude: Double) -> Double {
        guard longitude.isFinite else { return longitude }
        if (-180...180).contains(longitude) { return longitude }
        var l = (longitude + 180).truncatingRemainder(dividingBy: 360)
        if l < 0 { l += 360 }
        return l - 180
    }

    /// Wrap a bearing into [0, 360).
    public static func normalizedBearing(_ bearing: Double) -> Double {
        guard bearing.isFinite else { return 0 }
        let b = bearing.truncatingRemainder(dividingBy: 360)
        return b < 0 ? b + 360 : b
    }

    /// Smallest signed difference `to - from` between two bearings, in (-180, 180].
    public static func bearingDelta(from: Double, to: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }

    /// Total length of a polyline, in metres.
    public static func length(of points: [GeoPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    /// Compass point for a bearing ("N", "NE", …).
    public static func compassPoint(_ bearing: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((normalizedBearing(bearing) + 22.5) / 45) % 8
        return names[index]
    }
}
