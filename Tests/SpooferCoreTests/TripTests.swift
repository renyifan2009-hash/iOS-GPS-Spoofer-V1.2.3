import XCTest
@testable import SpooferCore

final class TripTypesTests: XCTestCase {
    func testProfileFromSpeed() {
        XCTAssertEqual(MotionProfile.forSpeed(1.4).kind, .walk)
        XCTAssertEqual(MotionProfile.forSpeed(3).kind, .run)
        XCTAssertEqual(MotionProfile.forSpeed(6).kind, .cycle)
        XCTAssertEqual(MotionProfile.forSpeed(31).kind, .drive)
        XCTAssertTrue(MotionProfile.walk.isOnFoot)
        XCTAssertNil(MotionProfile.walk.lateralAcceleration)
    }

    func testSeededRandomIsRepeatable() {
        var a = SplitMix64(seed: 42), b = SplitMix64(seed: 42)
        XCTAssertEqual((0..<5).map { _ in a.next() }, (0..<5).map { _ in b.next() })
    }

    func testGaussianHasUnitSpread() {
        var rng = SplitMix64(seed: 7)
        let samples = (0..<20_000).map { _ in rng.gaussian() }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(samples.count)
        XCTAssertEqual(mean, 0, accuracy: 0.03)
        XCTAssertEqual(variance, 1, accuracy: 0.05)
    }

    func testLightsFollowTheTimingModel() {
        var rng = SplitMix64(seed: 3)
        var red = 0, turnsGreen = 0, longestQueue = 0
        var waits: [Double] = []
        for _ in 0..<20_000 {
            switch TripOdds.light(.drive, &rng) {
            case .green:
                break
            case .turnsGreen(let speed):
                turnsGreen += 1
                XCTAssertTrue((2...5).contains(speed))
            case .red(let wait, let queue):
                red += 1
                waits.append(wait)
                longestQueue = max(longestQueue, queue)
                XCTAssertGreaterThan(wait, 0)
                XCTAssertLessThanOrEqual(wait, 72 + 1 + 1.5 * 5 + 1e-9)   // the longest red, plus a full queue
            }
        }
        // Red for 40–60% of the cycle.
        XCTAssertEqual(Double(red + turnsGreen) / 20_000, 0.5, accuracy: 0.03)
        XCTAssertGreaterThan(turnsGreen, 0)
        // What's left of a 24–72 s red, plus the queue pulling away: about 27 s.
        let mean = waits.reduce(0, +) / Double(waits.count)
        XCTAssertEqual(mean, 27, accuracy: 4)
        XCTAssertEqual(longestQueue, 5)
        // On foot the walk signal is shorter, so the wait comes more often.
        var walkerWaits = 0
        for _ in 0..<20_000 { if case .red = TripOdds.light(.walk, &rng) { walkerWaits += 1 } }
        XCTAssertGreaterThan(Double(walkerWaits) / 20_000, 0.55)
    }

    func testSignBumpAndBreakOdds() {
        var rng = SplitMix64(seed: 5)
        for _ in 0..<500 {
            XCTAssertTrue((0.8...3.2).contains(TripOdds.stopSignWait(&rng)))
            XCTAssertTrue((1...2.5).contains(TripOdds.rollingStopSpeed(&rng)))
            XCTAssertTrue((780...1320).contains(TripOdds.breakLength(&rng)))
        }
        XCTAssertEqual(TripOdds.calmingSpeed("hump") ?? 0, 18 * 0.44704, accuracy: 1e-9)
        XCTAssertGreaterThan(TripOdds.calmingSpeed("table") ?? 0, TripOdds.calmingSpeed("hump") ?? 0)
        XCTAssertNil(TripOdds.calmingSpeed("chicane"))
        var total = 0
        for _ in 0..<10_000 { total += TripOdds.poisson(1.5, &rng) }
        XCTAssertEqual(Double(total) / 10_000, 1.5, accuracy: 0.05)
    }

    func testUniqueFeaturePoints() {
        let p = GeoPoint(37, -122)
        let features = RoadFeatures(features: [
            RoadFeature(kind: .trafficSignal, distance: 10, point: p),
            RoadFeature(kind: .trafficSignal, distance: 900, point: p),   // the same light, passed twice
            RoadFeature(kind: .stopSign, distance: 50, point: GeoPoint(37.001, -122)),
        ])
        XCTAssertEqual(features.uniqueCount(of: .trafficSignal), 1)
        XCTAssertEqual(features.uniqueCount(of: .stopSign), 1)
    }
}

final class CurveSpeedsTests: XCTestCase {
    /// 200 m north, then 200 m east: one right-angle corner.
    private func corner() -> RoutePath {
        let start = GeoPoint(37.0, -122.0)
        let bend = start.moved(by: 200, bearing: 0)
        return RoutePath([start, bend, bend.moved(by: 200, bearing: 90)])
    }

    func testRightAngleRadius() {
        let b = GeoPoint(37, -122)
        let r = CurveSpeeds.circumradius(b.moved(by: 12, bearing: 180), b, b.moved(by: 12, bearing: 90))
        XCTAssertEqual(r, 8.49, accuracy: 0.1)
        XCTAssertEqual(CurveSpeeds.circumradius(b.moved(by: 12, bearing: 180), b, b.moved(by: 12, bearing: 0)),
                       .infinity)
    }

    func testCarSlowsForACorner() {
        let limits = CurveSpeeds.limits(along: corner(), profile: .drive)
        XCTAssertEqual(limits.count, 1)
        XCTAssertEqual(limits.first?.distance ?? 0, 200, accuracy: 1)
        XCTAssertEqual(limits.first?.speed ?? 0, 4.76, accuracy: 0.1)   // √(2.0 × 11.3): an 11 m arc
    }

    func testWalkersDontSlowAndStraightRoadsHaveNoLimits() {
        XCTAssertTrue(CurveSpeeds.limits(along: corner(), profile: .walk).isEmpty)
        let a = GeoPoint(37, -122)
        let straight = RoutePath([a, a.moved(by: 100, bearing: 0), a.moved(by: 200, bearing: 0)])
        XCTAssertTrue(CurveSpeeds.limits(along: straight, profile: .drive).isEmpty)
    }
}

final class TripPlannerTests: XCTestCase {
    static func line(_ metres: Double) -> RoutePath {
        let a = GeoPoint(37, -122)
        return RoutePath([a, a.moved(by: metres, bearing: 0)])
    }

    func testSegmentTime() {
        // 1000 m from rest to rest, cruise 10 m/s, a = b = 1: 10 s up (50 m), 900 m at 10, 10 s down.
        XCTAssertEqual(TripTiming.segmentTime(length: 1000, entry: 0, exit: 0, cruise: 10,
                                              acceleration: 1, braking: 1), 110, accuracy: 1e-6)
        // Too short to reach cruise: 100 m, peak √100 = 10, so 20 s.
        XCTAssertEqual(TripTiming.segmentTime(length: 100, entry: 0, exit: 0, cruise: 30,
                                              acceleration: 1, braking: 1), 20, accuracy: 1e-6)
        XCTAssertEqual(TripTiming.segmentTime(length: 100, entry: 10, exit: 10, cruise: 10,
                                              acceleration: 1, braking: 1), 10, accuracy: 1e-6)
    }

    func testOnceEndsWithADestinationStopAndWaypointWaits() {
        let planner = TripPlanner(path: Self.line(2000), loopMode: .once, settings: TripSettings(topSpeed: 15),
                                  waypointStops: [WaypointStop(index: 1, distance: 1000, wait: 60)])
        let plan = planner.lapPlan(lap: 0, seed: 1)
        XCTAssertEqual(plan.stops.map(\.reason), [.waypoint(1), .destination])
        XCTAssertEqual(plan.stops.last?.wait, .infinity)
        XCTAssertEqual(plan.stops.first?.distance ?? 0, 1000, accuracy: 1e-9)
    }

    func testRedLightsAreRandomButRepeatable() {
        let lights = (1...100).map {
            RoadFeature(kind: .trafficSignal, distance: Double($0) * 290, point: GeoPoint(37, -122))
        }
        let planner = TripPlanner(path: Self.line(30_000), loopMode: .loop, settings: TripSettings(topSpeed: 15),
                                  features: RoadFeatures(features: lights))
        let a = planner.lapPlan(lap: 3, seed: 9), b = planner.lapPlan(lap: 3, seed: 9)
        XCTAssertEqual(a, b)
        let reds = a.stops.filter { $0.reason == .redLight }
        XCTAssertGreaterThan(reds.count, 35)
        XCTAssertLessThan(reds.count, 65)          // about half of 100
        XCTAssertNotEqual(planner.lapPlan(lap: 4, seed: 9), a)
        // Each red stops at the line, or a few car lengths back behind the cars already waiting.
        var queues = Set<Int>()
        for red in reds {
            let cars = (290 - red.distance.truncatingRemainder(dividingBy: 290) - TripOdds.stopLineOffset)
                / TripOdds.queueSpacing
            XCTAssertEqual(cars, cars.rounded(), accuracy: 1e-6)
            queues.insert(Int(cars.rounded()))
        }
        XCTAssertTrue(queues.contains(0))
        XCTAssertTrue(queues.isSubset(of: Set(0...5)))
        XCTAssertGreaterThan(queues.count, 2)
    }

    func testBackAndForthMirrorsFeatures() {
        var settings = TripSettings(topSpeed: 15)
        settings.trafficLights = false
        let planner = TripPlanner(path: Self.line(1000), loopMode: .pingPong, settings: settings,
                                  features: RoadFeatures(features: [
                                      RoadFeature(kind: .stopSign, distance: 300, point: GeoPoint(37, -122)),
                                  ]))
        let plan = planner.lapPlan(lap: 0, seed: 1)
        XCTAssertEqual(plan.length, 2000, accuracy: 1e-6)
        // A full stop or a rolling one, 2 m before the sign: on the way out, and at 1700 − 2 on the way back.
        let signs = (plan.stops.filter { $0.reason == .stopSign }.map(\.distance)
            + plan.limits.filter { $0.speed <= 2.5 }.map(\.distance)).sorted()
        XCTAssertEqual(signs.count, 2)
        XCTAssertEqual(signs.first ?? 0, 298, accuracy: 1e-6)
        XCTAssertEqual(signs.last ?? 0, 1698, accuracy: 1e-6)
        XCTAssertTrue(plan.stops.contains { $0.reason == .turnaround && abs($0.distance - 1000) < 1e-6 })
    }

    func testSpeedZonesCapCruise() {
        let planner = TripPlanner(path: Self.line(1000), loopMode: .once, settings: TripSettings(topSpeed: 30),
                                  features: RoadFeatures(zones: [SpeedZone(start: 200, end: 600, speed: 10)]))
        let plan = planner.lapPlan(lap: 0, seed: 2)
        XCTAssertEqual(plan.cruise(at: 100, settings: planner.settings), 30, accuracy: 1e-9)
        XCTAssertEqual(plan.cruise(at: 400, settings: planner.settings), 10 * plan.driverFactor, accuracy: 1e-9)
    }

    /// "Drive at the speed limit": the limit wins even above the chosen speed, which only counts where no
    /// limit is known.
    func testCruiseAtLimitsDrivesTheLimitEvenAboveTheChosenSpeed() {
        let zones = RoadFeatures(zones: [SpeedZone(start: 200, end: 600, speed: 25)])
        var settings = TripSettings(topSpeed: 10, profile: .drive)
        let capped = TripPlanner(path: Self.line(1000), loopMode: .once, settings: settings, features: zones)
        let cappedPlan = capped.lapPlan(lap: 0, seed: 2)
        XCTAssertEqual(cappedPlan.cruise(at: 400, settings: settings), 10, accuracy: 1e-9, "off: the limit only slows")

        settings.cruiseAtLimits = true
        let atLimits = TripPlanner(path: Self.line(1000), loopMode: .once, settings: settings, features: zones)
        let plan = atLimits.lapPlan(lap: 0, seed: 2)
        XCTAssertEqual(plan.cruise(at: 400, settings: settings), 25 * plan.driverFactor, accuracy: 1e-9)
        XCTAssertEqual(plan.cruise(at: 100, settings: settings), 10, accuracy: 1e-9, "no limit known: the chosen speed")
        XCTAssertLessThan(atLimits.expectedLapTime(), capped.expectedLapTime() - 10)
    }

    func testExpectedLapTimeAndPaceFit() {
        let planner = TripPlanner(path: Self.line(3000), loopMode: .once, settings: TripSettings(topSpeed: 10))
        // 3000 m at 10 m/s from rest to rest, a = 1.8, b = 2.7: about 300 + 10/3.6 + 10/5.4 s.
        XCTAssertEqual(planner.expectedLapTime(), 304.6, accuracy: 0.5)
        let factor = planner.fittedPaceFactor(for: 600)
        var slower = planner
        slower.update(settings: TripSettings(topSpeed: 10, paceFactor: factor))
        XCTAssertEqual(slower.expectedLapTime(), 600, accuracy: 3)
    }
}

final class TripControllerTests: XCTestCase {
    typealias Entry = (t: Double, s: Double, v: Double, status: TripStatus)

    /// Drives a playback with the controller until `done`, logging each tick.
    private func drive(_ planner: TripPlanner, seed: UInt64 = 1, dt: Double = 0.5, until limit: Double = 3600,
                       done: (RoutePlayback, TripController) -> Bool) -> [Entry] {
        var playback = RoutePlayback(path: planner.path, loopMode: planner.loopMode)
        var trip = TripController(planner: planner, seed: seed)
        var t = 0.0
        var log: [Entry] = []
        while t < limit && !done(playback, trip) {
            playback.advance(by: trip.step(dt: dt, lapDistance: playback.lapDistance, lap: playback.lap))
            t += dt
            log.append((t, playback.travelled, trip.speed, trip.status))
        }
        return log
    }

    func testStopsAtAStopWaitsAndRespectsPhysics() {
        let planner = TripPlanner(path: TripPlannerTests.line(1000), loopMode: .once,
                                  settings: TripSettings(topSpeed: 15),
                                  waypointStops: [WaypointStop(index: 1, distance: 500, wait: 10)])
        let log = drive(planner) { playback, _ in playback.isFinished }
        var last = 0.0
        for entry in log {
            XCTAssertLessThanOrEqual(entry.v, 15 + 1e-9)
            XCTAssertLessThanOrEqual(entry.v - last, MotionProfile.drive.acceleration * 0.5 + 1e-9)
            last = entry.v
        }
        let stopped = log.filter { abs($0.s - 500) < 0.01 && $0.v == 0 }
        XCTAssertEqual(Double(stopped.count) * 0.5, 10, accuracy: 1.01)
        XCTAssertEqual(log.last?.s ?? 0, 1000, accuracy: 1e-6)
    }

    func testPredictionMatchesTheDrive() {
        let lights = (1...12).map {
            RoadFeature(kind: .trafficSignal, distance: Double($0) * 400, point: GeoPoint(37, -122))
        }
        let planner = TripPlanner(path: TripPlannerTests.line(5000), loopMode: .once,
                                  settings: TripSettings(topSpeed: 20),
                                  features: RoadFeatures(features: lights,
                                                         zones: [SpeedZone(start: 1000, end: 3000, speed: 12)]))
        let predicted = TripController(planner: planner, seed: 5).timeToLapEnd(from: 0)
        let log = drive(planner, seed: 5, dt: 0.25) { playback, _ in playback.isFinished }
        XCTAssertEqual(log.last?.t ?? 0, predicted, accuracy: predicted * 0.03)
    }

    func testSeekResyncsAndHaltStopsDead() {
        let planner = TripPlanner(path: TripPlannerTests.line(2000), loopMode: .once,
                                  settings: TripSettings(topSpeed: 15))
        var trip = TripController(planner: planner, seed: 1)
        _ = trip.step(dt: 0.5, lapDistance: 0, lap: 0)
        _ = trip.step(dt: 0.5, lapDistance: 1500, lap: 0)   // jumped ahead
        XCTAssertEqual(trip.status, .moving)
        trip.halt()
        XCTAssertEqual(trip.speed, 0)
    }

    func testLongDrivesTakeABreak() {
        let planner = TripPlanner(path: TripPlannerTests.line(400_000), loopMode: .once,
                                  settings: TripSettings(topSpeed: 30))
        let log = drive(planner, dt: 2, until: 4 * 3600) { _, trip in
            if case .stopped(.rest, _) = trip.status { return true }
            return false
        }
        XCTAssertGreaterThan(log.last?.t ?? 0, 1.7 * 3600)
        XCTAssertLessThan(log.last?.t ?? .infinity, 2.4 * 3600)
    }
}

final class DriftAndTrackTests: XCTestCase {
    func testDriftSizeAndSlowChange() {
        var drift = GPSDrift(size: 5, timeConstant: 30, seed: 11)
        var radial: [Double] = []
        var previous = (east: 0.0, north: 0.0)
        var jumps: [Double] = []
        for i in 0..<40_000 {
            let now = drift.step(dt: 1)
            if i > 300 { radial.append(now.east * now.east + now.north * now.north) }
            jumps.append(hypot(now.east - previous.east, now.north - previous.north))
            previous = now
        }
        let rms = (radial.reduce(0, +) / Double(radial.count)).squareRoot()
        XCTAssertEqual(rms, 5, accuracy: 0.6)
        // One second moves it far less than its size: it wanders, it doesn't jump.
        XCTAssertLessThan(jumps.reduce(0, +) / Double(jumps.count), 1.5)
    }

    func testRealisticTrackHoldsAtStopsAndEnds() throws {
        let path = TripPlannerTests.line(800)
        let planner = TripPlanner(path: path, loopMode: .once, settings: TripSettings(topSpeed: 12),
                                  waypointStops: [WaypointStop(index: 1, distance: 400, wait: 30)])
        let track = try RouteBuilder.timedTrack(path: path, loopMode: .once,
                                                trip: TripController(planner: planner, seed: 1))
        XCTAssertGreaterThan(track.count, 10)
        XCTAssertTrue(zip(track, track.dropFirst()).allSatisfy { $0.offset < $1.offset })
        let holds = zip(track, track.dropFirst()).filter {
            $0.latitude == $1.latitude && $0.longitude == $1.longitude && $1.offset - $0.offset >= 29
        }
        XCTAssertEqual(holds.count, 1)
        let last = try XCTUnwrap(track.last)
        XCTAssertEqual(GeoPoint(last.latitude, last.longitude).distance(to: path.end!), 0, accuracy: 0.5)
    }
}

final class JunctionGuessTests: XCTestCase {
    /// A city grid: 30 blocks of 150 m with a right-angle turn after each.
    private func zigzag() -> RoutePath {
        var points = [GeoPoint(37, -122)]
        for i in 0..<30 { points.append(points.last!.moved(by: 150, bearing: i % 2 == 0 ? 0 : 90)) }
        return RoutePath(points)
    }

    func testSharpTurnsBecomeJunctionsOnlyWhenAsked() {
        let path = zigzag()
        let plain = TripPlanner(path: path, loopMode: .loop, settings: TripSettings(topSpeed: 15))
        XCTAssertTrue(plain.lapPlan(lap: 0, seed: 4).stops.isEmpty)
        let guessing = TripPlanner(path: path, loopMode: .loop,
                                   settings: TripSettings(topSpeed: 15, guessJunctions: true))
        let reds = guessing.lapPlan(lap: 0, seed: 4).stops.filter { $0.reason == .redLight }
        XCTAssertGreaterThan(reds.count, 3)      // about 35% of 29 turns
        XCTAssertLessThan(reds.count, 20)
        // Walkers don't guess.
        let walking = TripPlanner(path: path, loopMode: .loop,
                                  settings: TripSettings(topSpeed: 1.4, guessJunctions: true))
        XCTAssertTrue(walking.lapPlan(lap: 0, seed: 4).stops.isEmpty)
    }
}

final class LoopStopTests: XCTestCase {
    func testALoopWaitsAtItsStartEachLap() {
        let a = GeoPoint(37, -122)
        let square = RoutePath([a, a.moved(by: 300, bearing: 0), a.moved(by: 300, bearing: 0).moved(by: 300, bearing: 90), a])
        let planner = TripPlanner(path: square, loopMode: .loop, settings: TripSettings(topSpeed: 10),
                                  waypointStops: [WaypointStop(index: 0, distance: 0, wait: 20)])
        var playback = RoutePlayback(path: planner.path, loopMode: .loop)
        var trip = TripController(planner: planner, seed: 1)
        var waitedAtStart = 0.0
        var t = 0.0
        while t < 600 && playback.lap < 2 {
            playback.advance(by: trip.step(dt: 0.5, lapDistance: playback.lapDistance, lap: playback.lap))
            t += 0.5
            if case .stopped(.waypoint(0), _) = trip.status {
                waitedAtStart += 0.5
                XCTAssertLessThan(playback.current.point.distance(to: a), 1)
            }
        }
        XCTAssertEqual(playback.lap, 2)
        // 20 s before leaving, then 20 s at the end of each of two laps.
        XCTAssertEqual(waitedAtStart, 60, accuracy: 2)
    }

    func testGuessesOnlyWithoutMapData() {
        var points = [GeoPoint(37, -122)]
        for i in 0..<20 { points.append(points.last!.moved(by: 150, bearing: i % 2 == 0 ? 0 : 90)) }
        let withData = TripPlanner(path: RoutePath(points), loopMode: .loop,
                                   settings: TripSettings(topSpeed: 15, trafficLights: true, guessJunctions: true),
                                   features: RoadFeatures(features: [
                                       RoadFeature(kind: .stopSign, distance: 75, point: points[0]),
                                   ]))
        XCTAssertTrue(withData.lapPlan(lap: 0, seed: 2).stops.allSatisfy { $0.reason != .redLight })
    }
}

final class PauseTests: XCTestCase {
    func testWalkersPauseNowAndThen() {
        let planner = TripPlanner(path: TripPlannerTests.line(5000), loopMode: .once,
                                  settings: TripSettings(topSpeed: 1.4))
        var playback = RoutePlayback(path: planner.path, loopMode: .once)
        var trip = TripController(planner: planner, seed: 3)
        var pauses = 0
        var pausedFor = 0.0
        var wasPaused = false
        var t = 0.0
        while t < 1800 && !playback.isFinished {
            playback.advance(by: trip.step(dt: 0.5, lapDistance: playback.lapDistance, lap: playback.lap))
            t += 0.5
            if case .stopped(.pause, _) = trip.status {
                if !wasPaused { pauses += 1 }
                pausedFor += 0.5
                wasPaused = true
            } else {
                wasPaused = false
            }
        }
        XCTAssertGreaterThanOrEqual(pauses, 3)           // 30 minutes of walking, one every 3–8 min
        XCTAssertLessThanOrEqual(pauses, 10)
        XCTAssertGreaterThan(pausedFor / Double(pauses), 4)
        XCTAssertLessThan(pausedFor / Double(pauses), 26)
    }
}

/// Cases found in review.
final class TripEdgeTests: XCTestCase {
    private func drive(_ planner: TripPlanner, seed: UInt64 = 1, dt: Double = 0.5, seconds: Double,
                       each: (RoutePlayback, TripController, Double) -> Void = { _, _, _ in }) -> (RoutePlayback, TripController) {
        var playback = RoutePlayback(path: planner.path, loopMode: planner.loopMode)
        var trip = TripController(planner: planner, seed: seed)
        var t = 0.0
        while t < seconds && !playback.isFinished {
            let before = trip.speed
            playback.advance(by: trip.step(dt: dt, lapDistance: playback.lapDistance, lap: playback.lap))
            t += dt
            each(playback, trip, before)
        }
        return (playback, trip)
    }

    func testASignAtTheEndCantStopTheTripShortOfIt() {
        let path = TripPlannerTests.line(1000)
        let planner = TripPlanner(path: path, loopMode: .once, settings: TripSettings(topSpeed: 15),
                                  features: RoadFeatures(features: [
                                      RoadFeature(kind: .stopSign, distance: 1000, point: path.end!),
                                  ]))
        let plan = planner.lapPlan(lap: 0, seed: 1)
        XCTAssertEqual(plan.stops.last?.reason, .destination)
        XCTAssertEqual(plan.stops.last?.distance ?? 0, 1000, accuracy: 1e-9)
        let (playback, _) = drive(planner, seconds: 600)
        XCTAssertTrue(playback.isFinished)
    }

    func testALoopSlowsForAStopJustPastItsStart() {
        let a = GeoPoint(37, -122)
        let square = RoutePath([a, a.moved(by: 400, bearing: 0), a.moved(by: 400, bearing: 0).moved(by: 400, bearing: 90),
                                a.moved(by: 400, bearing: 90), a])
        let planner = TripPlanner(path: square, loopMode: .loop, settings: TripSettings(topSpeed: 15),
                                  features: RoadFeatures(features: [
                                      RoadFeature(kind: .stopSign, distance: 16, point: a.moved(by: 16, bearing: 0)),
                                  ]))
        let braking = MotionProfile.drive.braking
        var hardest = 0.0
        var slowestAtTheSign = Double.infinity
        _ = drive(planner, seconds: 900) { playback, trip, before in
            hardest = max(hardest, (before - trip.speed) / 0.5)
            if playback.lap >= 1, abs(playback.lapDistance - 14) < 3 { slowestAtTheSign = min(slowestAtTheSign, trip.speed) }
        }
        XCTAssertLessThanOrEqual(slowestAtTheSign, 2.6)            // the sign after the seam still counts: a stop or a roll
        XCTAssertLessThanOrEqual(hardest, 1.6 * braking + 1e-6)  // and it brakes for it in time
    }

    func testBackAndForthTurnsAroundAtBothEnds() {
        let planner = TripPlanner(path: TripPlannerTests.line(800), loopMode: .pingPong, settings: TripSettings(topSpeed: 15))
        let plan = planner.lapPlan(lap: 0, seed: 1)
        let turns = plan.stops.filter { $0.reason == .turnaround }.map(\.distance)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns.last ?? 0, 1599.5, accuracy: 1e-6)
    }

    func testAClosedLoopSlowsForTheCornerWhereItCloses() {
        let a = GeoPoint(37, -122)
        let square = RoutePath([a, a.moved(by: 300, bearing: 0), a.moved(by: 300, bearing: 0).moved(by: 300, bearing: 90),
                                a.moved(by: 300, bearing: 90), a])
        let limits = CurveSpeeds.limits(along: square, profile: .drive)
        XCTAssertEqual(limits.first?.distance ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(limits.last?.distance ?? -1, square.length, accuracy: 1e-6)
        XCTAssertEqual(limits.count, 5)                           // 3 corners inside, plus the closing one twice
    }

    func testASlightKinkIsNotACorner() {
        let a = GeoPoint(37, -122)
        let kink = RoutePath([a, a.moved(by: 300, bearing: 0), a.moved(by: 300, bearing: 0).moved(by: 300, bearing: 6)])
        XCTAssertTrue(CurveSpeeds.limits(along: kink, profile: .drive).isEmpty)
        // A real 100 m-radius curve, drawn every 5 m.
        let centre = a.moved(by: 100, bearing: 90)
        let arc = RoutePath((0...30).map { centre.moved(by: 100, bearing: 270 + Double($0) * 3) })
        let slowest = CurveSpeeds.limits(along: arc, profile: .drive).map(\.speed).min() ?? 0
        XCTAssertEqual(slowest, ((MotionProfile.drive.lateralAcceleration ?? 0) * 100).squareRoot(), accuracy: 2.5)
    }

    func testSwitchingFromWalkingToDrivingDoesntBringABreakForward() {
        var settings = TripSettings(topSpeed: 1.4)
        let path = TripPlannerTests.line(60_000)
        var trip = TripController(planner: TripPlanner(path: path, loopMode: .once, settings: settings), seed: 2)
        var playback = RoutePlayback(path: path, loopMode: .once)
        for _ in 0..<20 { playback.advance(by: trip.step(dt: 0.5, lapDistance: playback.lapDistance, lap: 0)) }
        settings = TripSettings(topSpeed: 25)
        trip.update(settings: settings)
        var t = 0.0
        while t < 1800 {
            playback.advance(by: trip.step(dt: 1, lapDistance: playback.lapDistance, lap: 0))
            t += 1
            if case .stopped(.rest, _) = trip.status { XCTFail("a break \(t) s after switching to driving"); return }
        }
    }

    func testPaceFitStaysSaneWhenWaitsExceedTheTime() {
        let planner = TripPlanner(path: TripPlannerTests.line(2000), loopMode: .once, settings: TripSettings(topSpeed: 10),
                                  waypointStops: [WaypointStop(index: 1, distance: 1000, wait: 1800)])
        XCTAssertEqual(planner.fittedPaceFactor(for: 600), 4, accuracy: 1e-9)
    }
}

/// Research-backed behaviour added after the first pass.
final class RoadBehaviourTests: XCTestCase {
    func testStopSignsAreSometimesRollingStops() {
        let signs = (1...200).map {
            RoadFeature(kind: .stopSign, distance: Double($0) * 100, point: GeoPoint(37, -122))
        }
        let planner = TripPlanner(path: TripPlannerTests.line(20_100), loopMode: .once,
                                  settings: TripSettings(topSpeed: 15), features: RoadFeatures(features: signs))
        let plan = planner.lapPlan(lap: 0, seed: 3)
        let full = plan.stops.filter { $0.reason == .stopSign }.count
        let rolling = plan.limits.filter { $0.speed <= 2.5 }.count
        XCTAssertEqual(full + rolling, 200)
        XCTAssertEqual(Double(full) / 200, TripOdds.fullStopAtSign, accuracy: 0.1)
    }

    func testSignsForOneDirectionCountOnlyOnThatLeg() {
        /// How many times a yield sign 300 m along a 1 km road is met going out and coming back.
        func legs(_ facing: RoadFeature.Facing, _ mode: LoopMode) -> (out: Int, back: Int) {
            var settings = TripSettings(topSpeed: 15)
            settings.trafficLights = false
            let planner = TripPlanner(path: TripPlannerTests.line(1000), loopMode: mode, settings: settings,
                                      features: RoadFeatures(features: [
                                          RoadFeature(kind: .giveWay, distance: 300, point: GeoPoint(37, -122), facing: facing),
                                      ]))
            let lap = planner.lapPlan(lap: 0, seed: 1)
            // A full stop 2 m before it, or slowing at it.
            let places = lap.stops.filter { $0.reason == .giveWay }.map(\.distance)
                + lap.limits.filter { $0.speed == TripOdds.giveWaySpeed }.map(\.distance)
            return (places.filter { $0 < 1000 }.count, places.filter { $0 > 1000 }.count)
        }
        XCTAssertTrue(legs(.both, .pingPong) == (1, 1))
        XCTAssertTrue(legs(.forward, .pingPong) == (1, 0))
        XCTAssertTrue(legs(.backward, .pingPong) == (0, 1))
        XCTAssertTrue(legs(.forward, .once) == (1, 0))
        XCTAssertTrue(legs(.backward, .once) == (0, 0))
        XCTAssertTrue(legs(.backward, .loop) == (0, 0))
    }

    func testAStopForTheWayBackStaysOnTheWayBack() {
        // A light 5 m from the far end of an out-and-back route: on the way back
        // it's met right after the U-turn, so the car waits at the turn, never
        // on the way out (even behind a queue).
        let planner = TripPlanner(path: TripPlannerTests.line(1000), loopMode: .pingPong,
                                  settings: TripSettings(topSpeed: 15),
                                  features: RoadFeatures(features: [
                                      RoadFeature(kind: .trafficSignal, distance: 995, point: GeoPoint(37, -122)),
                                  ]))
        var waitedAtTheTurn = 0
        for lap in 0..<80 {
            let plan = planner.lapPlan(lap: lap, seed: 6)
            for stop in plan.stops where stop.reason == .redLight {
                XCTAssertTrue(stop.distance <= 989 + 1e-6 || stop.distance >= 1000 - 1e-6,
                              "lap \(lap): a red-light stop at \(stop.distance)")
                if abs(stop.distance - 1000) < 1e-6 { waitedAtTheTurn += 1 }
            }
            XCTAssertTrue(plan.limits.allSatisfy { $0.distance <= 989 + 1e-6 || $0.distance >= 1000 - 1e-6 })
        }
        XCTAssertGreaterThan(waitedAtTheTurn, 10)
    }

    func testMergingIntoTheTurnKeepsTheLongerWaitsReason() {
        let merged = TripPlanner.merged([
            TripStop(distance: 999, wait: 30, reason: .redLight),
            TripStop(distance: 1000, wait: 0, reason: .turnaround),
        ])
        XCTAssertEqual(merged, [TripStop(distance: 1000, wait: 30, reason: .redLight)])
        let end = TripPlanner.merged([
            TripStop(distance: 998, wait: 2, reason: .stopSign),
            TripStop(distance: 1000, wait: .infinity, reason: .destination),
        ])
        XCTAssertEqual(end, [TripStop(distance: 1000, wait: .infinity, reason: .destination)])
    }

    func testSpeedBumpsSlowCarsOnly() {
        let bump = RoadFeature(kind: .trafficCalming, distance: 500, point: GeoPoint(37, -122),
                               speed: TripOdds.calmingSpeed("hump"))
        func limits(_ settings: TripSettings) -> [TripLimit] {
            TripPlanner(path: TripPlannerTests.line(1000), loopMode: .once, settings: settings,
                        features: RoadFeatures(features: [bump])).lapPlan(lap: 0, seed: 1).limits
        }
        XCTAssertEqual(limits(TripSettings(topSpeed: 15)), [TripLimit(distance: 500, speed: 18 * 0.44704)])
        XCTAssertEqual(limits(TripSettings(topSpeed: 1.4)), [])
        XCTAssertEqual(limits(TripSettings(topSpeed: 15, slowForTurns: false)), [])
    }

    func testALightThatTurnsGreenOnlySlowsTheCar() {
        // Enough lights that some turn green just as the car gets there (it's
        // rare: by then there are usually cars waiting ahead).
        let lights = (1...4000).map {
            RoadFeature(kind: .trafficSignal, distance: Double($0) * 250, point: GeoPoint(37, -122))
        }
        let planner = TripPlanner(path: TripPlannerTests.line(1_000_100), loopMode: .once,
                                  settings: TripSettings(topSpeed: 15), features: RoadFeatures(features: lights))
        let plan = planner.lapPlan(lap: 0, seed: 8)
        let slowed = plan.limits.filter { abs($0.distance.truncatingRemainder(dividingBy: 250) - 244) < 1e-6 }
        XCTAssertFalse(slowed.isEmpty)
        XCTAssertTrue(slowed.allSatisfy { (2...5).contains($0.speed) })
        // Only slows: there's no stop at those lights as well (a queue would be up to 37.5 m back).
        for limit in slowed {
            XCTAssertFalse(plan.stops.contains { $0.reason == .redLight && limit.distance - $0.distance < 40
                && $0.distance <= limit.distance })
        }
    }
}
