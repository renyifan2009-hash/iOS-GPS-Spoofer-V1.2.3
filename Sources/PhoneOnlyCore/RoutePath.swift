import Foundation

/// A polyline indexed by distance, so "where is the device after N metres?" is
/// a binary search.
public struct RoutePath: Sendable, Equatable {
    public let points: [GeoPoint]
    /// Cumulative distance (metres) at each point; `cumulative[0] == 0`.
    public let cumulative: [Double]

    /// A path holds only real places. A point that is NaN, infinite or off the
    /// map is left out: `Geo.distance` would call it half the Earth away, and
    /// positions that cannot be put on a grid stop the app.
    public init(_ points: [GeoPoint]) {
        let points = points.allSatisfy(\.isValid) ? points : points.filter(\.isValid)
        self.points = points
        var cumulative: [Double] = []
        cumulative.reserveCapacity(points.count)
        var total = 0.0
        for (i, p) in points.enumerated() {
            if i > 0 { total += Geo.distance(points[i - 1], p) }
            cumulative.append(total)
        }
        self.cumulative = cumulative
    }

    public var length: Double { cumulative.last ?? 0 }
    public var isEmpty: Bool { points.isEmpty }
    public var start: GeoPoint? { points.first }
    public var end: GeoPoint? { points.last }

    /// First and last points are (practically) the same place.
    public var isClosed: Bool {
        guard points.count > 2, let a = points.first, let b = points.last else { return false }
        return Geo.distance(a, b) < 1
    }

    /// The same path with a final segment back to the start (no-op if closed).
    public func closed() -> RoutePath {
        guard points.count > 1, !isClosed, let first = points.first else { return self }
        return RoutePath(points + [first])
    }

    public func reversed() -> RoutePath { RoutePath(points.reversed()) }

    /// Position and heading after travelling `distance` metres from the start
    /// (clamped to the path).
    public func sample(at distance: Double) -> RouteSample {
        guard let first = points.first else { return RouteSample(point: GeoPoint(0, 0), bearing: 0) }
        guard points.count > 1, length > 0 else { return RouteSample(point: first, bearing: 0) }
        let d = min(max(distance, 0), length)

        // Last index whose cumulative distance is <= d, capped so i+1 is valid.
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cumulative[mid] <= d { lo = mid } else { hi = mid - 1 }
        }
        let i = min(lo, points.count - 2)
        let segment = cumulative[i + 1] - cumulative[i]
        let t = segment > 0 ? (d - cumulative[i]) / segment : 0
        let point = Geo.interpolate(points[i], points[i + 1], fraction: t)
        return RouteSample(point: point, bearing: bearing(ofSegmentAt: i))
    }

    /// Heading of segment `i`, looking past zero-length segments.
    private func bearing(ofSegmentAt i: Int) -> Double {
        var j = i
        while j < points.count - 1 {
            if cumulative[j + 1] - cumulative[j] > 0.01 { return Geo.bearing(from: points[j], to: points[j + 1]) }
            j += 1
        }
        j = i
        while j > 0 {
            if cumulative[j] - cumulative[j - 1] > 0.01 { return Geo.bearing(from: points[j - 1], to: points[j]) }
            j -= 1
        }
        return 0
    }
}

public struct RouteSample: Sendable, Equatable {
    public var point: GeoPoint
    /// Direction of travel, degrees clockwise from north.
    public var bearing: Double

    public init(point: GeoPoint, bearing: Double) {
        self.point = point
        self.bearing = bearing
    }
}

/// What happens at the end of a route.
public enum LoopMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Stop at the destination.
    case once
    /// Drive back to the start and go round again, forever.
    case loop
    /// Turn around at each end and retrace the route, forever.
    case pingPong

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .once: return "Once"
        case .loop: return "Loop"
        case .pingPong: return "Back & forth"
        }
    }

    public var symbolName: String {
        switch self {
        case .once: return "arrow.right"
        case .loop: return "repeat"
        case .pingPong: return "arrow.left.arrow.right"
        }
    }
}

/// Distance-driven playback of a route. Advance it by however far the device
/// moved since the last tick; speed changes and pauses need no bookkeeping.
public struct RoutePlayback: Sendable, Equatable {
    public let path: RoutePath
    public let loopMode: LoopMode
    /// Total metres travelled since the start (across laps).
    public private(set) var travelled: Double = 0

    public init(path: RoutePath, loopMode: LoopMode, travelled: Double = 0) {
        self.path = loopMode == .loop ? path.closed() : path
        self.loopMode = loopMode
        self.travelled = 0
        seek(toDistance: travelled)
    }

    /// Length of one lap: the route, or out-and-back for ping-pong.
    public var cycleLength: Double {
        loopMode == .pingPong ? path.length * 2 : path.length
    }

    public var isFinished: Bool {
        loopMode == .once && travelled >= path.length
    }

    /// Completed laps (always 0 for `.once`).
    public var lap: Int {
        guard loopMode != .once, cycleLength > 0 else { return 0 }
        return Int(travelled / cycleLength)
    }

    /// Distance into the current lap.
    public var lapDistance: Double {
        guard cycleLength > 0 else { return 0 }
        if loopMode == .once { return min(travelled, path.length) }
        return travelled.truncatingRemainder(dividingBy: cycleLength)
    }

    /// 0…1 progress through the current lap.
    public var lapFraction: Double {
        guard cycleLength > 0 else { return 1 }
        return min(1, lapDistance / cycleLength)
    }

    /// Metres left until the destination (`.once`) or the end of this lap.
    public var remainingInLap: Double {
        max(0, cycleLength - lapDistance)
    }

    public var current: RouteSample {
        guard cycleLength > 0 else { return path.sample(at: 0) }
        switch loopMode {
        case .once, .loop:
            return path.sample(at: lapDistance)
        case .pingPong:
            let d = lapDistance
            if d <= path.length { return path.sample(at: d) }
            var sample = path.sample(at: cycleLength - d)
            sample.bearing = Geo.normalizedBearing(sample.bearing + 180)
            return sample
        }
    }

    @discardableResult
    public mutating func advance(by metres: Double) -> RouteSample {
        guard metres.isFinite, metres > 0 else { return current }
        travelled += metres
        if loopMode == .once { travelled = min(travelled, path.length) }
        return current
    }

    /// Jump to `distance` metres from the start of the route.
    public mutating func seek(toDistance distance: Double) {
        let d = max(0, distance.isFinite ? distance : 0)
        travelled = loopMode == .once ? min(d, path.length) : d
    }

    /// Jump to a fraction of the current lap.
    public mutating func seek(toLapFraction fraction: Double) {
        let f = min(max(fraction, 0), 1)
        let lapStart = Double(lap) * cycleLength
        seek(toDistance: lapStart + f * cycleLength)
    }
}

/// Ramer–Douglas–Peucker simplification, for turning dense imported tracks into
/// a manageable set of editable waypoints.
public enum RouteSimplifier {
    /// Drop points that deviate less than `tolerance` metres from the line
    /// through their neighbours. Endpoints are always kept.
    ///
    /// Positions that are not real places (NaN, infinite, off the map) are left
    /// out first: one of them would turn every distance into NaN, and the whole
    /// track would collapse to its two ends.
    public static func simplify(_ points: [GeoPoint], tolerance: Double) -> [GeoPoint] {
        guard points.count > 2, tolerance > 0 else { return points }
        guard points.allSatisfy(\.isValid) else { return simplify(points.filter(\.isValid), tolerance: tolerance) }
        let lat0 = Geo.radians(points.map(\.latitude).reduce(0, +) / Double(points.count))
        let k = Geo.earthRadius * .pi / 180
        let xy = points.map { (x: $0.longitude * k * cos(lat0), y: $0.latitude * k) }

        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let span = stack.popLast() {
            let (first, last) = span
            guard last > first + 1 else { continue }
            var maxDistance = -1.0
            var index = first
            for i in (first + 1)..<last {
                let d = perpendicularDistance(xy[i], xy[first], xy[last])
                if d > maxDistance { maxDistance = d; index = i }
            }
            if maxDistance > tolerance {
                keep[index] = true
                stack.append((first, index))
                stack.append((index, last))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    /// Simplify until at most `maxPoints` remain, raising the tolerance as needed.
    public static func simplify(_ points: [GeoPoint], maxPoints: Int) -> [GeoPoint] {
        guard points.allSatisfy(\.isValid) else { return simplify(points.filter(\.isValid), maxPoints: maxPoints) }
        guard points.count > max(2, maxPoints) else { return points }
        var tolerance = 1.0
        var result = simplify(points, tolerance: tolerance)
        var attempts = 0
        while result.count > max(2, maxPoints) && attempts < 40 {
            tolerance *= 1.6
            result = simplify(points, tolerance: tolerance)
            attempts += 1
        }
        return result
    }

    private static func perpendicularDistance(
        _ p: (x: Double, y: Double), _ a: (x: Double, y: Double), _ b: (x: Double, y: Double)
    ) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
