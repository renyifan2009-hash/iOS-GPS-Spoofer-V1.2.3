import Foundation

/// A local route timeline: travel at the selected speed, wait at stops and repeat without a Mac.
/// Road directions are supplied by the iPhone app; this type never substitutes straight lines for
/// a failed directions request.
public struct StandaloneRoute: Sendable {
    public struct Point: Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public init(_ latitude: Double, _ longitude: Double) { self.latitude = latitude; self.longitude = longitude }
        public var isValid: Bool {
            latitude.isFinite && longitude.isFinite && (-85...85).contains(latitude) && (-180...180).contains(longitude)
        }
    }
    private struct Segment: Sendable {
        var from: Point
        var to: Point
        var start: Double
        var end: Double
        /// Which waypoint a wait is at (0 is the start); nil while travelling.
        var stop: Int? = nil
    }
    private let segments: [Segment]
    public let duration: Double
    public let repeats: Bool
    public let speed: Double
    public let start: Point

    /// A corner on the path: where it is on the timeline (at full speed, within one pass) and how sharp.
    public struct Turn: Equatable, Sendable {
        public var time: Double
        public var degrees: Double
    }

    /// The corners of one pass, in order. Road directions bend a corner over several close points,
    /// so points within `turnMergeMeters` of each other count as one corner.
    public private(set) var turns: [Turn] = []
    static let turnMergeMeters = 25.0

    public enum Problem: Error, LocalizedError {
        case invalid
        public var errorDescription: String? { "This route needs distinct map positions, a valid speed and reasonable waits." }
    }

    /// Paths include their endpoints. Waits are in seconds, one per waypoint.
    public init(legs: [[Point]], waits: [Double], speed: Double, repeatMode: String) throws {
        guard !legs.isEmpty, legs.count <= SavedRoute.maxStops, waits.count == legs.count + 1,
              waits.allSatisfy({ $0.isFinite && (0...86400).contains($0) }),
              speed.isFinite, speed > 0, speed <= JoystickInput.maxSpeed,
              ["once", "loop", "pingPong"].contains(repeatMode),
              legs.allSatisfy({ $0.count >= 2 && $0.allSatisfy(\.isValid) }),
              legs.reduce(0, { $0 + $1.count }) <= 100_000 else { throw Problem.invalid }
        for i in 1..<legs.count where legs[i - 1].last != legs[i].first { throw Problem.invalid }
        var segments: [Segment] = []
        var elapsed = 0.0
        func add(_ from: Point, _ to: Point, _ seconds: Double, stop: Int? = nil) {
            guard seconds > 0 else { return }
            segments.append(Segment(from: from, to: to, start: elapsed, end: elapsed + seconds, stop: stop))
            elapsed += seconds
        }
        func travel(_ points: [Point]) {
            for i in 1..<points.count {
                add(points[i - 1], points[i], Self.distance(points[i - 1], points[i]) / speed)
            }
        }
        let first = legs[0][0]
        add(first, first, waits[0], stop: 0)
        for (i, leg) in legs.enumerated() {
            travel(leg)
            let end = leg[leg.count - 1]
            add(end, end, waits[i + 1], stop: i + 1)
        }
        if repeatMode == "pingPong" {
            for i in legs.indices.reversed() {
                let reverse = Array(legs[i].reversed())
                travel(reverse)
                if i > 0 { add(reverse.last!, reverse.last!, waits[i], stop: i) }
            }
        }
        // Loop callers supply a road leg back to the starting point. Refuse a discontinuous jump.
        if repeatMode == "loop", legs.last?.last != first { throw Problem.invalid }
        guard legs.contains(where: { leg in zip(leg, leg.dropFirst()).contains { Self.distance($0, $1) > 0.01 } }),
              elapsed.isFinite, elapsed > 0 else { throw Problem.invalid }
        self.segments = segments; self.duration = elapsed; self.repeats = repeatMode != "once"
        self.speed = speed; self.start = first
        self.turns = Self.findTurns(in: segments, speed: speed)
    }

    private static func findTurns(in segments: [Segment], speed: Double) -> [Turn] {
        var turns: [Turn] = []
        // A corner being gathered: where it began, how far it has swung, and (in metres along the
        // path) where it began and where its latest bend was. A long sweeping curve isn't a corner, so
        // one corner spans at most `2 × turnMergeMeters`.
        var open: (time: Double, degrees: Double, startMeters: Double, lastMeters: Double)?
        var previous: Segment?
        var meters = 0.0
        for segment in segments {
            let length = (segment.end - segment.start) * speed
            defer { meters += segment.stop == nil ? length : 0 }
            guard segment.stop == nil, distance(segment.from, segment.to) > 0.5 else {
                // A wait is its own stop: a corner before it doesn't carry over.
                if segment.stop != nil {
                    if let corner = open { turns.append(Turn(time: corner.time, degrees: abs(corner.degrees))) }
                    open = nil
                    previous = nil
                }
                continue
            }
            if let before = previous {
                let change = signedChange(from: bearing(before.from, before.to), to: bearing(segment.from, segment.to))
                if var corner = open, meters - corner.lastMeters <= turnMergeMeters,
                   meters - corner.startMeters <= 2 * turnMergeMeters {
                    corner.degrees += change
                    corner.lastMeters = meters
                    open = corner
                } else {
                    if let corner = open { turns.append(Turn(time: corner.time, degrees: abs(corner.degrees))) }
                    open = abs(change) >= 3 ? (segment.start, change, meters, meters) : nil
                }
            }
            previous = segment
        }
        if let corner = open { turns.append(Turn(time: corner.time, degrees: abs(corner.degrees))) }
        return turns.filter { $0.degrees >= 20 }
    }

    /// -180...180: how far the heading swings going from `a` to `b`.
    static func signedChange(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return d
    }

    /// Time into the current pass, for a timeline that may repeat.
    private func passTime(_ elapsed: Double) -> Double {
        var t = elapsed.isFinite ? max(0, elapsed) : 0
        if repeats { t.formTruncatingRemainder(dividingBy: duration) }
        return t
    }

    /// What's ahead within `meters` of `elapsed`: the sharpest corner (0...180 degrees, where 180 means
    /// the route stops there: a wait, or the end of a one-way trip) and how far away it is. Nil while
    /// standing at a stop, or when the way ahead is straight.
    public func slowdownAhead(at elapsed: Double, within meters: Double) -> (degrees: Double, meters: Double)? {
        let t = passTime(elapsed)
        guard t < duration, meters > 0 else { return nil }
        guard var index = segments.firstIndex(where: { t >= $0.start && t < $0.end }) else { return nil }
        guard segments[index].stop == nil else { return nil }
        var heading = Self.bearing(segments[index].from, segments[index].to)
        var travelled = (segments[index].end - t) * speed
        var sharpest: (degrees: Double, meters: Double)?
        var swing = 0.0
        var steps = 0
        while travelled <= meters, steps < segments.count {
            steps += 1
            index += 1
            if index >= segments.count {
                guard repeats else { return (180, travelled) }
                index = 0
            }
            let next = segments[index]
            if next.stop != nil { return (180, travelled) }
            guard Self.distance(next.from, next.to) > 0.5 else { continue }
            let nextHeading = Self.bearing(next.from, next.to)
            swing += Self.signedChange(from: heading, to: nextHeading)
            heading = nextHeading
            if abs(swing) > (sharpest?.degrees ?? 10) { sharpest = (min(180, abs(swing)), travelled) }
            travelled += (next.end - next.start) * speed
        }
        return sharpest
    }

    /// The heading of travel at `elapsed`, degrees clockwise from north. Nil while standing at a stop.
    public func heading(at elapsed: Double) -> Double? {
        let t = passTime(elapsed)
        guard t < duration, let segment = segments.first(where: { t >= $0.start && t < $0.end }),
              segment.stop == nil, Self.distance(segment.from, segment.to) > 0.01 else { return nil }
        return Self.bearing(segment.from, segment.to)
    }

    public func sample(at elapsed: Double) -> (point: Point, progress: Double, finished: Bool, moving: Bool) {
        var t = elapsed.isFinite ? max(0, elapsed) : 0
        if repeats { t.formTruncatingRemainder(dividingBy: duration) }
        if t >= duration { return (segments.last!.to, 1, true, false) }
        var low = 0, high = segments.count - 1
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].end <= t { low = mid + 1 } else { high = mid }
        }
        let segment = segments[low]
        let fraction = min(1, max(0, (t - segment.start) / (segment.end - segment.start)))
        let meters = Self.distance(segment.from, segment.to)
        if meters < 0.01 { return (segment.from, t / duration, false, false) }
        let p = PhoneGeo.moved(latitude: segment.from.latitude, longitude: segment.from.longitude,
                               meters: meters * fraction, bearing: Self.bearing(segment.from, segment.to))
        return (Point(p.latitude, p.longitude), t / duration, false, true)
    }

    /// While the route stands at one of its waypoints `elapsed` seconds in: which one (0 is the start, so a wait
    /// there is "leaving in") and how long is left. nil while travelling or after a one-way route ends.
    public func waiting(at elapsed: Double) -> (stop: Int, remaining: Double)? {
        var t = elapsed.isFinite ? max(0, elapsed) : 0
        if repeats { t.formTruncatingRemainder(dividingBy: duration) }
        guard t < duration else { return nil }
        guard let segment = segments.first(where: { t >= $0.start && t < $0.end }), let stop = segment.stop else { return nil }
        return (stop, segment.end - t)
    }

    public static func distance(_ a: Point, _ b: Point) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1, dl = (b.longitude - a.longitude) * .pi / 180
        let h = pow(sin(dp / 2), 2) + cos(p1) * cos(p2) * pow(sin(dl / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, h))))
    }

    private static func bearing(_ a: Point, _ b: Point) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        return atan2(sin(dl) * cos(p2), cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)) * 180 / .pi
    }
}
