import PhoneOnlyCore
import XCTest

final class NaturalDriveTests: XCTestCase {
    private func point(_ from: StandaloneRoute.Point, meters: Double, bearing: Double) -> StandaloneRoute.Point {
        let p = PhoneGeo.moved(latitude: from.latitude, longitude: from.longitude, meters: meters, bearing: bearing)
        return StandaloneRoute.Point(p.latitude, p.longitude)
    }

    /// 300 m east, then 300 m north: one right-angle corner.
    private func lShape(waits: [Double] = [0, 0], repeatMode: String = "once") throws -> StandaloneRoute {
        let a = StandaloneRoute.Point(37.0, -122.0)
        let b = point(a, meters: 300, bearing: 90)
        let c = point(b, meters: 300, bearing: 0)
        return try StandaloneRoute(legs: [[a, b, c]], waits: waits, speed: 15, repeatMode: repeatMode)
    }

    func testAnLShapedRouteHasOneRightAngleCorner() throws {
        let route = try lShape()
        XCTAssertEqual(route.turns.count, 1)
        XCTAssertEqual(route.turns[0].degrees, 90, accuracy: 2)
        XCTAssertEqual(route.turns[0].time, 20, accuracy: 0.5)   // 300 m at 15 m/s
    }

    func testAStraightRouteHasNoCorners() throws {
        let a = StandaloneRoute.Point(37.0, -122.0)
        let route = try StandaloneRoute(legs: [[a, point(a, meters: 200, bearing: 45), point(a, meters: 400, bearing: 45)]],
                                        waits: [0, 0], speed: 10, repeatMode: "once")
        XCTAssertTrue(route.turns.isEmpty)
    }

    func testTheCornerAndTheEndAreSeenAhead() throws {
        let route = try lShape()
        let corner = try XCTUnwrap(route.slowdownAhead(at: 18, within: 60))
        XCTAssertEqual(corner.degrees, 90, accuracy: 2)
        XCTAssertEqual(corner.meters, 30, accuracy: 2)
        let end = try XCTUnwrap(route.slowdownAhead(at: 38, within: 60))
        XCTAssertEqual(end.degrees, 180)
        XCTAssertNil(route.slowdownAhead(at: 2, within: 60), "straight road ahead")
    }

    func testDrivingPullsAwaySlowsForTheCornerNeverSpeedsAndFinishes() throws {
        let route = try lShape()
        var drive = NaturalDrive(route: route, driving: true, seed: 7)
        var fastest = 0.0, atCorner = Double.infinity, cruising = 0.0
        var seconds = 0.0
        var first = drive.advance(dt: 0.25)
        XCTAssertLessThan(first.speed, 2, "a car pulls away; it doesn't start at top speed")
        while seconds < 600 {
            first = drive.advance(dt: 0.25)
            seconds += 0.25
            fastest = max(fastest, first.speed)
            if first.reason == nil, abs(first.elapsed - route.turns[0].time) < 0.5 { atCorner = min(atCorner, first.speed) }
            if (10...12).contains(first.elapsed) { cruising = max(cruising, first.speed) }
            if route.sample(at: first.elapsed).finished { break }
        }
        XCTAssertTrue(route.sample(at: drive.elapsed).finished, "the drive gets there")
        XCTAssertLessThanOrEqual(fastest, 15 * 1.05 + 0.001)
        XCTAssertLessThan(atCorner, cruising * 0.75, "slower round the corner than on the straight")
        XCTAssertGreaterThan(seconds, route.duration, "a real drive takes longer than the top speed would")
    }

    func testYourStopsStillWaitInRealTime() throws {
        let route = try lShape(waits: [30, 0])   // leave after 30 s
        var drive = NaturalDrive(route: route, driving: true, seed: 1)
        for _ in 0..<100 { _ = drive.advance(dt: 0.25) }     // 25 s
        XCTAssertNotNil(route.waiting(at: drive.elapsed))
        XCTAssertEqual(drive.elapsed, 25, accuracy: 0.01)
    }

    func testTheSameSeedDrivesTheSameWay() throws {
        let route = try lShape()
        var a = NaturalDrive(route: route, driving: true, seed: 42)
        var b = NaturalDrive(route: route, driving: true, seed: 42)
        for _ in 0..<400 { XCTAssertEqual(a.advance(dt: 0.25), b.advance(dt: 0.25)) }
    }

    func testWobbleStaysNearAndIsOffAtZero() {
        var wobble = GPSWobble(size: 3, seed: 3)
        var sum = 0.0, farthest = 0.0
        for _ in 0..<2000 {
            let o = wobble.step(dt: 1)
            let d = hypot(o.east, o.north)
            sum += d * d
            farthest = max(farthest, d)
        }
        let rms = (sum / 2000).squareRoot()
        XCTAssertGreaterThan(rms, 0.5)
        XCTAssertLessThan(rms, 9)
        XCTAssertLessThan(farthest, 40)
        var off = GPSWobble(size: 0, seed: 3)
        let o = off.step(dt: 1)
        XCTAssertEqual(o.east, 0)
        XCTAssertEqual(o.north, 0)
    }
}
