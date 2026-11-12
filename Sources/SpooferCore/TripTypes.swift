import Foundation

/// A small seedable random number generator (SplitMix64), so a trip's random
/// choices can be repeated (in tests, and for the same lap after a replan).
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension RandomNumberGenerator {
    /// A standard normal sample (Box–Muller).
    public mutating func gaussian() -> Double {
        let u1 = Double.random(in: Double.ulpOfOne..<1, using: &self)
        let u2 = Double.random(in: 0..<1, using: &self)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    /// True with probability `p`.
    public mutating func chance(_ p: Double) -> Bool {
        Double.random(in: 0..<1, using: &self) < p
    }
}

/// How a kind of traveller speeds up, slows down and takes corners.
public struct MotionProfile: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable { case walk, run, cycle, drive }

    public let kind: Kind
    /// Comfortable speeding up from a stop, m/s².
    public let acceleration: Double
    /// Comfortable braking, m/s².
    public let braking: Double
    /// Sideways acceleration accepted in curves, m/s²; nil: doesn't slow for curves.
    public let lateralAcceleration: Double?
    /// Slowest speed through the tightest turn, m/s.
    public let minimumTurnSpeed: Double

    public static let walk = MotionProfile(kind: .walk, acceleration: 0.5, braking: 0.8,
                                           lateralAcceleration: nil, minimumTurnSpeed: 0)
    public static let run = MotionProfile(kind: .run, acceleration: 1.0, braking: 1.5,
                                          lateralAcceleration: nil, minimumTurnSpeed: 0)
    public static let cycle = MotionProfile(kind: .cycle, acceleration: 1.0, braking: 2.0,
                                            lateralAcceleration: 2.5, minimumTurnSpeed: 3.0)
    public static let drive = MotionProfile(kind: .drive, acceleration: 1.8, braking: 2.7,
                                            lateralAcceleration: 2.0, minimumTurnSpeed: 3.5)

    /// The profile for a top speed (m/s).
    public static func forSpeed(_ speed: Double) -> MotionProfile {
        switch speed {
        case ..<2.2: return .walk
        case ..<4.5: return .run
        case ..<9: return .cycle
        default: return .drive
        }
    }

    public var isOnFoot: Bool { kind == .walk || kind == .run }
}

/// The odds and waits for lights, signs and breaks. The sources are in
/// docs/design/realistic-trips.md, under Research notes.
public enum TripOdds {
    /// How far before a light's position the stop line is, metres.
    public static let stopLineOffset = 6.0
    /// Room each car waiting ahead at a red light takes, metres.
    public static let queueSpacing = 7.5

    /// What a traffic light does on one pass.
    public enum Light: Sendable, Equatable {
        case green
        /// It turns green as you get there: slow to this speed (m/s), don't stop.
        case turnsGreen(Double)
        /// Red: stop `queue` cars back from the line, and wait.
        case red(wait: TimeInterval, queue: Int)
    }

    /// Real signal timing isn't known, so each pass makes one up: a cycle of
    /// 60–120 s, green for 40–60% of it for traffic (25–55% for someone on foot,
    /// whose walk signal is shorter), reached at a random moment. When it's red,
    /// the wait is what's left of the red, so short waits are as common as long ones.
    public static func light(_ profile: MotionProfile, _ rng: inout SplitMix64) -> Light {
        let cycle = Double.random(in: 60...120, using: &rng)
        let green = profile.isOnFoot ? Double.random(in: 0.25...0.55, using: &rng)
                                     : Double.random(in: 0.4...0.6, using: &rng)
        let red = cycle * (1 - green)
        let arrival = Double.random(in: 0..<cycle, using: &rng)   // seconds into the red
        guard arrival < red else { return .green }
        let left = red - arrival
        if profile.isOnFoot {
            // Stepping off takes a few seconds once it says walk.
            return left < 2 ? .green : .red(wait: left + Double.random(in: 1.5...4, using: &rng), queue: 0)
        }
        // Cars that got there earlier in the red wait ahead: about one per 15 s of it.
        let queue = min(5, poisson(arrival / 15, &rng))
        if queue == 0, left < 3 { return .turnsGreen(Double.random(in: 2...5, using: &rng)) }
        // Once it's green, the first car moves off after about a second, and each one after it 1.5 s later.
        return .red(wait: left + 1 + 1.5 * Double(queue), queue: queue)
    }

    /// A crossing light on its own (not at a junction) stops traffic only when
    /// someone has pressed the button: 1 pass in 4, for 2–25 s.
    public static let crossingRedForTraffic = 0.25

    public static func crossingWait(_ rng: inout SplitMix64) -> TimeInterval {
        Double.random(in: 2...25, using: &rng)
    }

    /// A car comes to a full stop at a stop sign about half the time, then
    /// waits 1–3 s; otherwise it rolls through at walking pace.
    public static let fullStopAtSign = 0.5

    public static func stopSignWait(_ rng: inout SplitMix64) -> TimeInterval {
        triangular(&rng, low: 0.8, mode: 1.6, high: 3.2)
    }

    /// A rolling stop's slowest speed, m/s.
    public static func rollingStopSpeed(_ rng: inout SplitMix64) -> Double {
        Double.random(in: 1...2.5, using: &rng)
    }

    /// Yield: usually slow to this speed (m/s); sometimes stop for a gap.
    public static let giveWaySpeed = 4.0
    public static let giveWayStop = 0.3

    public static func giveWayWait(_ rng: inout SplitMix64) -> TimeInterval {
        Double.random(in: 1...4, using: &rng)
    }

    /// Speed over traffic calming (`traffic_calming=*` in OpenStreetMap), m/s.
    public static func calmingSpeed(_ value: String) -> Double? {
        let mph = 0.44704
        switch value {
        case "hump", "yes": return 18 * mph
        case "cushion": return 25 * mph   // cars can straddle the gaps
        case "table": return 23 * mph
        case "bump": return 8 * mph
        default: return nil
        }
    }

    /// Without map data: a sharp turn (slower than this, m/s) is taken to be a
    /// junction, which has traffic lights this often.
    public static let junctionTurnSpeed = 7.0
    public static let junctionHasLight = 0.7

    /// Drivers keep a little under or over the limit for the whole trip.
    public static let driverFactor = 0.95...1.05

    /// Driving time before a break, and the break itself.
    public static let meanBreakInterval: TimeInterval = 2 * 3600
    public static let meanBreakLength: TimeInterval = 17.5 * 60

    public static func breakInterval(_ rng: inout SplitMix64) -> TimeInterval {
        Double.random(in: 1.75 * 3600...2.25 * 3600, using: &rng)
    }

    public static func breakLength(_ rng: inout SplitMix64) -> TimeInterval {
        Double.random(in: 780...1320, using: &rng)
    }

    /// On foot: a short pause (a phone, a shop window) every few minutes of walking.
    public static let meanPauseInterval: TimeInterval = 330
    public static let meanPauseLength: TimeInterval = 15

    public static func pauseInterval(_ rng: inout SplitMix64) -> TimeInterval {
        Double.random(in: 180...480, using: &rng)
    }

    public static func pauseLength(_ rng: inout SplitMix64) -> TimeInterval {
        Double.random(in: 5...25, using: &rng)
    }

    static func triangular(_ rng: inout SplitMix64, low: Double, mode: Double, high: Double) -> Double {
        let u = Double.random(in: 0..<1, using: &rng)
        let cut = (mode - low) / (high - low)
        if u < cut { return low + ((high - low) * (mode - low) * u).squareRoot() }
        return high - ((high - low) * (high - mode) * (1 - u)).squareRoot()
    }

    /// A Poisson-distributed count with this mean (Knuth's method; small means only).
    static func poisson(_ mean: Double, _ rng: inout SplitMix64) -> Int {
        guard mean > 0 else { return 0 }
        let limit = exp(-mean)
        var product = Double.random(in: 0..<1, using: &rng)
        var count = 0
        while product > limit, count < 50 {
            count += 1
            product *= Double.random(in: 0..<1, using: &rng)
        }
        return count
    }
}

/// What a trip does, chosen in the app.
public struct TripSettings: Sendable, Equatable {
    /// The chosen speed, m/s: the cruise speed, and the cap when speed limits apply (unless
    /// `cruiseAtLimits`, when it's only the speed where no limit is known).
    public var topSpeed: Double
    public var profile: MotionProfile
    public var trafficLights: Bool
    public var stopSigns: Bool
    public var slowForTurns: Bool
    public var speedLimits: Bool
    public var breaks: Bool
    /// 0…0.3: slow random speed changes.
    public var speedVariation: Double
    /// Multiplies every cruise speed (pacing by duration fits the lap time with it).
    public var paceFactor: Double
    /// Scales cruising speed for the time-of-day traffic (`Congestion`): 1 is
    /// free-flowing, lower is slower than the limit. 1 unless the app opts in.
    public var trafficFactor: Double
    /// No map data for this road route: treat its sharp turns as junctions,
    /// where a car sometimes waits as if at a red light.
    public var guessJunctions: Bool
    /// Drive each road at about its limit (times the driver's habit), even above `topSpeed`, which
    /// then only counts where no limit is known. Off, a limit only ever slows the trip below `topSpeed`.
    public var cruiseAtLimits: Bool

    public init(topSpeed: Double, profile: MotionProfile? = nil, trafficLights: Bool = true,
                stopSigns: Bool = true, slowForTurns: Bool = true, speedLimits: Bool = true,
                breaks: Bool = true, speedVariation: Double = 0, paceFactor: Double = 1,
                trafficFactor: Double = 1, guessJunctions: Bool = false, cruiseAtLimits: Bool = false) {
        self.topSpeed = topSpeed
        self.profile = profile ?? .forSpeed(topSpeed)
        self.trafficLights = trafficLights
        self.stopSigns = stopSigns
        self.slowForTurns = slowForTurns
        self.speedLimits = speedLimits
        self.breaks = breaks
        self.speedVariation = speedVariation
        self.paceFactor = paceFactor
        self.trafficFactor = trafficFactor
        self.guessJunctions = guessJunctions
        self.cruiseAtLimits = cruiseAtLimits
    }

    /// Changing these needs a new plan; the others are read every tick.
    func plansDiffer(from other: TripSettings) -> Bool {
        profile != other.profile || trafficLights != other.trafficLights || stopSigns != other.stopSigns
            || slowForTurns != other.slowForTurns || speedLimits != other.speedLimits
            || guessJunctions != other.guessJunctions
    }
}

/// A place in a lap where the trip comes to a halt.
public struct TripStop: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case redLight, stopSign, giveWay, crossing
        /// One of your stops (index into the waypoints).
        case waypoint(Int)
        case destination, turnaround
        /// A break on a long drive.
        case rest
        /// A short pause on foot.
        case pause
    }

    /// Metres into the lap.
    public var distance: Double
    /// Seconds to wait there; `.infinity` at the destination.
    public var wait: TimeInterval
    public var reason: Reason

    public init(distance: Double, wait: TimeInterval, reason: Reason) {
        self.distance = distance
        self.wait = wait
        self.reason = reason
    }
}

/// The fastest speed at a point (a curve, a yield sign).
public struct TripLimit: Sendable, Equatable {
    public var distance: Double
    public var speed: Double

    public init(distance: Double, speed: Double) {
        self.distance = distance
        self.speed = speed
    }
}

public enum TripStatus: Sendable, Equatable {
    case moving
    /// Stopped for `reason`; `remaining` is nil when it waits until you stop it.
    case stopped(TripStop.Reason, remaining: TimeInterval?)
}

/// One of your stops, with how long to wait there.
public struct WaypointStop: Sendable, Equatable {
    /// Index into the route's waypoints.
    public var index: Int
    /// Metres from the start of the route.
    public var distance: Double
    public var wait: TimeInterval

    public init(index: Int, distance: Double, wait: TimeInterval) {
        self.index = index
        self.distance = distance
        self.wait = wait
    }
}

/// Something on the road that changes how a trip moves.
public struct RoadFeature: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case trafficSignal, stopSign, giveWay, signalCrossing
        /// A speed bump, hump, table or cushion.
        case trafficCalming
    }

    /// Which way along the route it's for. A stop sign before a junction is
    /// only for traffic heading into it; out and back, the way back meets it
    /// from the other side.
    public enum Facing: String, Sendable, Codable {
        case both, forward, backward

        func overlaps(_ other: Facing) -> Bool { self == .both || other == .both || self == other }
    }

    public var kind: Kind
    /// Metres from the start of the route, one entry per time the route passes it.
    public var distance: Double
    public var point: GeoPoint
    public var facing: Facing
    /// Traffic calming: the speed to slow to, m/s.
    public var speed: Double?

    public init(kind: Kind, distance: Double, point: GeoPoint, facing: Facing = .both, speed: Double? = nil) {
        self.kind = kind
        self.distance = distance
        self.point = point
        self.facing = facing
        self.speed = speed
    }
}

/// What OpenStreetMap knows about a route's roads, by distance along it.
public struct RoadFeatures: Sendable, Equatable, Codable {
    public var features: [RoadFeature]
    public var zones: [SpeedZone]
    /// False when some pieces of the route couldn't be loaded.
    public var complete: Bool

    public init(features: [RoadFeature] = [], zones: [SpeedZone] = [], complete: Bool = true) {
        self.features = features
        self.zones = zones
        self.complete = complete
    }

    public static let none = RoadFeatures()

    /// Different places of this kind (a light passed twice counts once). Ones
    /// only for the other direction count only when the route comes back.
    public func uniqueCount(of kind: RoadFeature.Kind, wayBack: Bool = false) -> Int {
        Set(features.filter { $0.kind == kind && (wayBack || $0.facing != .backward) }.map(\.point)).count
    }

    /// Fraction of `length` metres covered by a known speed limit.
    public func speedLimitCoverage(of length: Double) -> Double {
        guard length > 0 else { return 0 }
        return min(1, zones.reduce(0) { $0 + max(0, $1.end - $1.start) } / length)
    }
}
