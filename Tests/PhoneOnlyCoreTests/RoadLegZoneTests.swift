import XCTest
@testable import PhoneOnlyCore

final class RoadLegZoneTests: XCTestCase {
    func testEachLegGetsItsOwnStretch() {
        let zones = SpeedZone.legs(ends: [0, 500, 500, 1200], speeds: [20, 15, nil])
        XCTAssertEqual(zones, [SpeedZone(start: 0, end: 500, speed: 20)],
                       "a leg with no length, or no speed, gets no stretch")
        XCTAssertEqual(SpeedZone.legs(ends: [0, 300, 900], speeds: [10, 30]),
                       [SpeedZone(start: 0, end: 300, speed: 10), SpeedZone(start: 300, end: 900, speed: 30)])
        XCTAssertEqual(SpeedZone.legs(ends: [0, 300], speeds: [.nan]), [], "not a speed")
    }

    /// A long route's legs are thinned together to fit, each keeping its two ends.
    func testLegsAreThinnedTogetherAndKeepTheirEnds() {
        // A wiggly line every ~11 m: 1000 points a leg, 2 m off the straight line.
        func leg(from start: Double) -> [GeoPoint] {
            (0..<1000).map { i in GeoPoint(37 + (i % 2 == 0 ? 0 : 0.00002), start + Double(i) * 0.0001) }
        }
        let legs: [[GeoPoint]?] = [leg(from: -122), nil, leg(from: -121.8)]
        let thin = RouteSimplifier.simplify(legs: legs, maxPoints: 200)
        XCTAssertEqual(thin.count, 3)
        XCTAssertNil(thin[1], "a straight leg stays straight")
        let total = thin.reduce(0) { $0 + ($1?.count ?? 0) }
        XCTAssertLessThanOrEqual(total, 200)
        for (before, after) in [(legs[0]!, thin[0]!), (legs[2]!, thin[2]!)] {
            XCTAssertEqual(after.first, before.first)
            XCTAssertEqual(after.last, before.last)
        }
        // Already small enough: only the metre-or-less wiggles go.
        let close = RouteSimplifier.simplify(legs: [[GeoPoint(37, -122), GeoPoint(37.001, -122), GeoPoint(37.001, -121.999)]],
                                             maxPoints: 1000)
        XCTAssertEqual(close[0]?.count, 3, "a real corner is kept")
    }
}
