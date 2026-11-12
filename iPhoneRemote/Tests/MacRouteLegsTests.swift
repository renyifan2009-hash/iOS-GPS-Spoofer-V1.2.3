import Foundation
import PhoneOnlyCore
import RemoteAPI
import XCTest
@testable import AnyWhere

/// The roads a route takes to the Mac in Mac mode: one leg per pair of stops, in the shape the Mac checks.
@MainActor
final class MacRouteLegsTests: XCTestCase {
    private func request(loop: String, closed: Bool = false) -> RouteRequest {
        var stops: [RouteRequest.Waypoint] = [.init(latitude: 37.3349, longitude: -122.0090),
                                              .init(latitude: 37.3349, longitude: -122.0050)]
        if closed { stops.append(stops[0]) }
        return RouteRequest(waypoints: stops, followRoads: true, travelMode: "driving", loopMode: loop)
    }

    private func leg(_ points: [StandaloneRoute.Point]) -> AppleMapsLeg {
        AppleMapsLeg(points: points, meters: 820, expectedSeconds: 60)
    }

    /// A loop drives back to its start on roads too, unless its last stop already is the start.
    func testALoopGetsAWayBack() {
        XCTAssertEqual(MacRouteLegs.stops(of: request(loop: "once")).count, 2)
        let loop = MacRouteLegs.stops(of: request(loop: "loop"))
        XCTAssertEqual(loop.count, 3)
        XCTAssertEqual(loop.last, loop.first)
        XCTAssertEqual(MacRouteLegs.stops(of: request(loop: "loop", closed: true)).count, 3, "already back at the start")
    }

    func testWhatGoesToTheMacFitsTheRoute() throws {
        let a = StandaloneRoute.Point(37.3349, -122.0090), b = StandaloneRoute.Point(37.3349, -122.0050)
        let road = leg([a, .init(37.3370, -122.0090), .init(37.3370, -122.0050), b])
        var sent = request(loop: "loop")
        sent.legs = MacRouteLegs.wire([road, nil])
        let legs = try XCTUnwrap(sent.legs)
        XCTAssertEqual(legs.count, 2)
        XCTAssertNil(legs[1], "a leg Apple Maps had no road for is left for the Mac")
        XCTAssertEqual(legs[0]?.pointCount, 4, "corners are kept")
        XCTAssertEqual(legs[0]?.expectedSeconds, 60)
        XCTAssertNotNil(sent.usableLegs, "the Mac takes them as they are")
        // It survives the trip over the wire.
        let back = try RemoteAPI.makeDecoder().decode(RouteRequest.self, from: RemoteAPI.makeEncoder().encode(sent))
        XCTAssertEqual(back.legs, sent.legs)
    }

    func testNoRoadsAtAllSendsNone() {
        XCTAssertNil(MacRouteLegs.wire([nil, nil]), "the Mac finds the roads itself, as before")
    }

    /// The limit toggle shows for a Mac that can drive at the limits, and not for an older one.
    func testOnlyANewerMacDrivesAtTheLimits() {
        let connection = ConnectionManager()
        XCTAssertFalse(connection.drivesAtSpeedLimits, "not heard from the Mac yet: don't offer it")
    }
}
