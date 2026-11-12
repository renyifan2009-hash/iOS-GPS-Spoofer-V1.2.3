import Foundation

/// A road from OpenStreetMap: its shape and tags.
public struct OSMWay: Sendable, Equatable {
    public var id: Int64
    public var points: [GeoPoint]
    public var tags: [String: String]
    /// The id of the node at each point (empty when not known).
    public var nodeIDs: [Int64]

    public init(id: Int64, points: [GeoPoint], tags: [String: String], nodeIDs: [Int64] = []) {
        self.id = id
        self.points = points
        self.tags = tags
        self.nodeIDs = nodeIDs
    }
}

/// Road speed limits from OpenStreetMap tags.
public enum SpeedLimits {
    static let kmh = 1 / 3.6
    static let mph = 0.44704

    /// Usual limits by road type, km/h, when a road has no `maxspeed`.
    static let defaults: [String: Double] = [
        "motorway": 110, "motorway_link": 60, "trunk": 90, "trunk_link": 50,
        "primary": 70, "primary_link": 50, "secondary": 60, "secondary_link": 40,
        "tertiary": 50, "tertiary_link": 40, "unclassified": 50, "residential": 40,
        "living_street": 15, "service": 20, "road": 50,
    ]

    /// Zone codes (`DE:urban`, `GB:nsl_dual`…), m/s.
    static let zoneCodes: [String: Double] = [
        "urban": 50 * kmh, "rural": 90 * kmh, "motorway": 120 * kmh, "trunk": 100 * kmh,
        "living_street": 20 * kmh, "bicycle_road": 30 * kmh, "school": 30 * kmh,
        "nsl_single": 60 * mph, "nsl_dual": 70 * mph, "nsl_restricted": 30 * mph,
    ]

    /// `maxspeed` in m/s: "50", "30 mph", "DE:urban", "none"; nil for
    /// "signals", "variable" and anything it can't read.
    public static func parse(maxspeed raw: String) -> Double? {
        let value = (raw.split(separator: ";").first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "none": return 130 * kmh
        case "walk": return 7 * kmh
        case "", "signals", "variable", "unknown": return nil
        default: break
        }
        if let colon = value.firstIndex(of: ":") {
            let code = String(value[value.index(after: colon)...])
            if let speed = zoneCodes[code] { return speed }
            if code.hasPrefix("zone"), let number = Double(code.dropFirst(4)) { return number * kmh }
            return nil
        }
        let parts = value.split(separator: " ")
        guard let number = parts.first.flatMap({ Double($0) }), number > 0, number < 300 else { return nil }
        if parts.count > 1, parts[1].hasPrefix("mph") { return number * mph }
        if parts.count > 1, parts[1].hasPrefix("knots") { return number * 0.514444 }
        return number * kmh
    }

    /// A road's limit in m/s, or nil if it isn't a road for cars.
    public static func speed(tags: [String: String]) -> Double? {
        guard let highway = tags["highway"], let fallback = defaults[highway] else { return nil }
        return tags["maxspeed"].flatMap(parse(maxspeed:)) ?? fallback * kmh
    }

    /// Speed zones along `path`: every `spacing` metres, the limit of the road
    /// under the route (running the same way, either direction), merged into stretches.
    public static func zones(along path: RoutePath, ways: [OSMWay], spacing: Double = 20) -> [SpeedZone] {
        guard path.length > 0, spacing > 0, spacing.isFinite, !ways.isEmpty else { return [] }
        var segments: [(a: GeoPoint, b: GeoPoint, speed: Double)] = []
        for way in ways {
            guard let speed = speed(tags: way.tags), way.points.count >= 2 else { continue }
            for i in 0..<(way.points.count - 1) where way.points[i].isValid && way.points[i + 1].isValid {
                segments.append((way.points[i], way.points[i + 1], speed))
            }
        }
        guard !segments.isEmpty else { return [] }

        let cell = 0.0005
        func key(_ x: Int, _ y: Int) -> Int64 {
            Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y)))
        }
        var grid: [Int64: [Int]] = [:]
        for (index, segment) in segments.enumerated() {
            let dLat = segment.b.latitude - segment.a.latitude
            // The short way round, so a road over the antimeridian is a few cells, not the whole globe.
            let dLon = GridCells.longitudeDelta(from: segment.a.longitude, to: segment.b.longitude)
            let span = max(abs(dLat), abs(dLon))
            let steps = max(1, Int((span / (cell / 2)).rounded(.up)))
            for k in 0...steps {
                let t = Double(k) / Double(steps)
                let lon = segment.a.longitude + dLon * t
                let lat = segment.a.latitude + dLat * t
                let id = key(GridCells.column(of: lon, cell: cell), GridCells.row(of: lat, cell: cell))
                if grid[id]?.last != index { grid[id, default: []].append(index) }
            }
        }

        let count = Int(path.length / spacing) + 1
        var speeds = [Double?](repeating: nil, count: count)
        let k = Geo.earthRadius * .pi / 180
        for n in 0..<count {
            let sample = path.sample(at: min(path.length, Double(n) * spacing))
            let p = sample.point
            guard p.isValid else { continue }   // not a real place: no road to find
            let cosLat = cos(Geo.radians(p.latitude))
            func xy(_ q: GeoPoint) -> (x: Double, y: Double) {
                (Geo.normalizedLongitude(q.longitude - p.longitude) * k * cosLat, (q.latitude - p.latitude) * k)
            }
            var candidates = Set<Int>()
            let x = GridCells.column(of: p.longitude, cell: cell), y = GridCells.row(of: p.latitude, cell: cell)
            for dx in -1...1 {
                let column = GridCells.wrapped(column: x + dx, cell: cell)
                for dy in -1...1 { candidates.formUnion(grid[key(column, y + dy)] ?? []) }
            }
            var best: (offset: Double, speed: Double)?
            for index in candidates.sorted() {
                let segment = segments[index]
                let turn = abs(Geo.bearingDelta(from: sample.bearing, to: Geo.bearing(from: segment.a, to: segment.b)))
                guard turn < 35 || turn > 145 else { continue }   // the same road, not a cross street
                let a = xy(segment.a), b = xy(segment.b)
                let ex = b.x - a.x, ey = b.y - a.y
                let lengthSquared = ex * ex + ey * ey
                let t = lengthSquared > 0 ? max(0, min(1, -(a.x * ex + a.y * ey) / lengthSquared)) : 0
                let offset = hypot(a.x + t * ex, a.y + t * ey)
                guard offset <= 12 else { continue }
                if best == nil || offset < best!.offset { best = (offset, segment.speed) }
            }
            speeds[n] = best?.speed
        }

        // Short gaps (junctions, small mapping gaps) keep the speed before them.
        var last: Double?
        var gap = 0
        for n in 0..<count {
            if let speed = speeds[n] {
                last = speed
                gap = 0
            } else if let last, gap < 10 {
                speeds[n] = last
                gap += 1
            }
        }
        var zones: [SpeedZone] = []
        for n in 0..<count {
            guard let speed = speeds[n] else { continue }
            let start = Double(n) * spacing, end = min(path.length, start + spacing)
            guard end > start else { continue }
            if let previous = zones.last, previous.speed == speed, abs(previous.end - start) < 1e-6 {
                zones[zones.count - 1].end = end
            } else {
                zones.append(SpeedZone(start: start, end: end, speed: speed))
            }
        }
        // Slivers shorter than 60 m join the zone before them.
        var merged: [SpeedZone] = []
        for zone in zones {
            if zone.end - zone.start < 60, let previous = merged.last, abs(previous.end - zone.start) < 1e-6 {
                merged[merged.count - 1].end = zone.end
            } else {
                merged.append(zone)
            }
        }
        return merged
    }
}

/// A stretch of road with a speed limit.
public struct SpeedZone: Sendable, Equatable, Codable {
    public var start: Double
    public var end: Double
    /// m/s.
    public var speed: Double

    public init(start: Double, end: Double, speed: Double) {
        self.start = start
        self.end = end
        self.speed = speed
    }
}

extension SpeedZone {
    /// `primary` where it covers the way, `fallback` in the gaps: sorted, with no overlaps. For the
    /// iPhone, where a road's own limit (OpenStreetMap) beats Apple Maps' typical speed for the leg.
    public static func merged(primary: [SpeedZone], fallback: [SpeedZone]) -> [SpeedZone] {
        let primary = primary.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var result = primary
        for zone in fallback where zone.end > zone.start {
            var pieces = [zone]
            for covered in result {
                pieces = pieces.flatMap { piece -> [SpeedZone] in
                    guard covered.end > piece.start, covered.start < piece.end else { return [piece] }
                    var left: [SpeedZone] = []
                    if covered.start > piece.start {
                        left.append(SpeedZone(start: piece.start, end: covered.start, speed: piece.speed))
                    }
                    if covered.end < piece.end {
                        left.append(SpeedZone(start: covered.end, end: piece.end, speed: piece.speed))
                    }
                    return left
                }
            }
            result += pieces
        }
        return result.sorted { $0.start < $1.start }
    }

    /// One speed per leg of a route, as stretches: leg `i` runs from `ends[i]` to `ends[i + 1]` (metres along
    /// the route). A leg with no speed, or no length, gets no stretch.
    public static func legs(ends: [Double], speeds: [Double?]) -> [SpeedZone] {
        zip(zip(ends, ends.dropFirst()), speeds).compactMap { span, speed in
            guard let speed, speed.isFinite, speed > 0, span.1 > span.0 else { return nil }
            return SpeedZone(start: span.0, end: span.1, speed: speed)
        }
    }

    /// A cruise speed from Apple Maps' expected travel time for a leg (m/s). That time already
    /// counts the slowing for corners and lights the drive adds itself, so the cruise is a bit above
    /// the average: kept between 10 and 75 mph.
    public static func cruise(meters: Double, expectedSeconds: Double) -> Double? {
        guard meters.isFinite, expectedSeconds.isFinite, meters > 50, expectedSeconds > 0 else { return nil }
        return min(75 * SpeedLimits.mph, max(10 * SpeedLimits.mph, meters / expectedSeconds * 1.15))
    }
}
