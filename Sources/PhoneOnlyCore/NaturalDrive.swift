import Foundation

/// Drives a `StandaloneRoute` like a person would, for the iPhone-only mode: it pulls away gently,
/// slows for corners and before each stop, wanders a little around the chosen speed, and now and then
/// stops at a corner for a red light or a stop sign (a walk waits to cross instead). The chosen speed
/// is the top speed.
///
/// It runs a route clock: `elapsed` is the route's own timeline (at full speed), which this advances
/// more slowly than real time whenever the car is slower than its top speed. Waits at your stops run
/// in real time.
public struct NaturalDrive: Sendable {
    public struct Step: Equatable, Sendable {
        /// Where on the route's timeline the car is now: pass it to `StandaloneRoute.sample(at:)`.
        public var elapsed: Double
        /// Metres per second right now.
        public var speed: Double
        /// Why it's standing still at a corner, as a `RouteWait` reason ("light", "sign", "crossing"), or nil.
        public var reason: String?
        /// Seconds left of that, when there's a reason.
        public var remaining: Double?

        public init(elapsed: Double, speed: Double, reason: String? = nil, remaining: Double? = nil) {
            self.elapsed = elapsed
            self.speed = speed
            self.reason = reason
            self.remaining = remaining
        }
    }

    public let route: StandaloneRoute
    public let driving: Bool
    private(set) public var elapsed = 0.0
    /// Speed as a share of the top speed.
    private var share = 0.0
    private var cruise = 0.95
    private var cruiseTarget = 0.95
    private var cruiseClock = 0.0
    private var hold: (reason: String, left: Double)?
    /// The next corner to decide about, and which pass of a repeating route it is in.
    private var nextTurn = 0
    private var pass = 0
    private var random: NaturalRandom

    public init(route: StandaloneRoute, driving: Bool, seed: UInt64 = .random(in: 0 ... .max)) {
        self.route = route
        self.driving = driving
        random = NaturalRandom(seed: seed)
    }

    /// Move the car on by `dt` seconds of real time.
    public mutating func advance(dt: Double) -> Step {
        let dt = dt.isFinite ? min(max(dt, 0), 5) : 0
        if var held = hold {
            held.left -= dt
            share = 0
            if held.left > 0 {
                hold = held
                return Step(elapsed: elapsed, speed: 0, reason: held.reason, remaining: held.left)
            }
            hold = nil
        }
        // One of your stops (or the wait before leaving): the route's own timeline counts it down.
        if route.waiting(at: elapsed) != nil {
            share = 0
            elapsed += dt
            return Step(elapsed: elapsed, speed: 0, reason: nil, remaining: nil)
        }
        wanderCruise(dt)
        let target = targetShare()
        let rate = target > share ? (driving ? 0.16 : 0.9) : (driving ? 0.4 : 1.4)
        share += max(-rate * dt, min(rate * dt, target - share))
        share = min(max(share, 0), 1.05)
        let before = elapsed
        elapsed += dt * share
        decideCorners(from: before, to: elapsed)
        if let held = hold {
            share = 0
            return Step(elapsed: elapsed, speed: 0, reason: held.reason, remaining: held.left)
        }
        return Step(elapsed: elapsed, speed: share * route.speed, reason: nil, remaining: nil)
    }

    /// Around the chosen speed, picking a new pace now and then the way a driver eases on and off.
    private mutating func wanderCruise(_ dt: Double) {
        cruiseClock -= dt
        if cruiseClock <= 0 {
            cruiseTarget = driving ? random.uniform(0.84, 1.0) : random.uniform(0.82, 1.05)
            cruiseClock = random.uniform(12, 35)
        }
        cruise += (cruiseTarget - cruise) * min(1, dt / 6)
    }

    /// The share of top speed to aim for: the cruise, less for a corner or a stop coming up. It never
    /// aims for nothing while moving, or the car would stop short of the stop it slows for.
    private func targetShare() -> Double {
        let lookahead = driving ? max(40, route.speed * 5) : 8
        guard let ahead = route.slowdownAhead(at: elapsed, within: lookahead) else { return cruise }
        let atCorner: Double
        if ahead.degrees >= 180 {
            atCorner = 0.12
        } else if driving {
            atCorner = max(0.22, 1 - ahead.degrees / 125)
        } else {
            atCorner = max(0.55, 1 - ahead.degrees / 300)
        }
        let blend = min(1, max(0, ahead.meters / lookahead))
        return max(driving ? 0.1 : 0.3, min(cruise, atCorner + (cruise - atCorner) * blend))
    }

    /// Passing a corner between `from` and `to` on the timeline: sometimes it's a red light or a sign.
    private mutating func decideCorners(from: Double, to: Double) {
        let turns = route.turns
        guard !turns.isEmpty, route.duration > 0 else { return }
        var guardCount = 0
        while guardCount < turns.count + 1 {
            guardCount += 1
            if nextTurn >= turns.count {
                guard route.repeats else { return }
                nextTurn = 0
                pass += 1
            }
            let at = Double(pass) * route.duration + turns[nextTurn].time
            guard at <= to else { return }
            let turn = turns[nextTurn]
            nextTurn += 1
            guard at > from - 0.001, hold == nil else { continue }
            if let stop = stopFor(degrees: turn.degrees) { hold = stop }
        }
    }

    private mutating func stopFor(degrees: Double) -> (reason: String, left: Double)? {
        let roll = random.uniform(0, 1)
        if driving {
            guard degrees >= 45 else { return nil }
            if roll < 0.28 { return ("light", random.uniform(12, 50)) }
            if roll < 0.46 { return ("sign", random.uniform(2, 4.5)) }
            return nil
        }
        guard degrees >= 60, roll < 0.18 else { return nil }
        return ("crossing", random.uniform(4, 20))
    }
}

/// GPS that looks like a phone's own: the position wanders a few metres around the true one over
/// half a minute or so, and once in a while slips a bit further for a few seconds, as a reading
/// does near buildings. Off, it adds nothing.
public struct GPSWobble: Sendable {
    /// Typical wander, metres.
    public var size: Double
    private var east = 0.0
    private var north = 0.0
    private var glitchEast = 0.0
    private var glitchNorth = 0.0
    private var random: NaturalRandom

    public init(size: Double, seed: UInt64 = .random(in: 0 ... .max)) {
        self.size = size
        random = NaturalRandom(seed: seed)
    }

    /// The offset to add now, after `dt` seconds.
    public mutating func step(dt: Double) -> (east: Double, north: Double) {
        guard size > 0, dt.isFinite, dt > 0 else { return (0, 0) }
        let dt = min(dt, 10)
        let keep = exp(-dt / 25)
        let fresh = size / 2.0.squareRoot() * (1 - keep * keep).squareRoot()
        east = keep * east + fresh * random.gaussian()
        north = keep * north + fresh * random.gaussian()
        // A slip about every three minutes, fading over a few seconds.
        let fade = exp(-dt / 3)
        glitchEast *= fade
        glitchNorth *= fade
        if random.uniform(0, 1) < dt / 180 {
            let reach = random.uniform(size * 1.8, size * 3.5)
            let angle = random.uniform(0, 2 * .pi)
            glitchEast = reach * sin(angle)
            glitchNorth = reach * cos(angle)
        }
        return (east + glitchEast, north + glitchNorth)
    }

    /// `point` moved by this step's offset.
    public mutating func apply(latitude: Double, longitude: Double, dt: Double) -> (latitude: Double, longitude: Double) {
        let offset = step(dt: dt)
        let meters = hypot(offset.east, offset.north)
        guard meters > 0 else { return (latitude, longitude) }
        return PhoneGeo.moved(latitude: latitude, longitude: longitude, meters: meters,
                              bearing: atan2(offset.east, offset.north) * 180 / .pi)
    }
}

/// SplitMix64: small, fast, and repeatable from a seed, so tests can pin a drive down.
struct NaturalRandom: Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ..< 1
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }

    /// Standard normal (Box–Muller).
    mutating func gaussian() -> Double {
        let u = max(unit(), .leastNonzeroMagnitude)
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * unit())
    }
}
