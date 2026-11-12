import Foundation
import RemoteAPI
import SpooferCore
import XCTest
@testable import SpooferRemote

/// Routes on the roads the iPhone sends (protocol version 3): the legs, where the stops fall on them, and
/// driving at each road's limit.
final class RoadRouteTests: XCTestCase {
    private let a = RouteRequest.Waypoint(latitude: 37.3349, longitude: -122.0090)
    private let b = RouteRequest.Waypoint(latitude: 37.3349, longitude: -122.0050)
    private let c = RouteRequest.Waypoint(latitude: 37.3349, longitude: -122.0010)
    /// A to B the long way round: 230 m north, east, and back south (about 820 m, not 350).
    private var detour: RoadLeg {
        RoadLeg(points: [(37.3349, -122.0090), (37.3370, -122.0090), (37.3370, -122.0050), (37.3349, -122.0050)],
                meters: 820, expectedSeconds: 60)
    }

    private func roundTrip(_ request: RouteRequest) throws -> RouteRequest {
        try RemoteAPI.makeDecoder().decode(RouteRequest.self, from: RemoteAPI.makeEncoder().encode(request))
    }

    // MARK: Wire

    func testLegsAndLimitsRoundTripOverTheWire() throws {
        let request = RouteRequest(waypoints: [a, b, c], followRoads: true, travelMode: "driving", speed: 12,
                                   legs: [detour, nil], followSpeedLimits: true)
        XCTAssertEqual(try roundTrip(request), request)
        XCTAssertEqual(RemoteAPI.version, 3)
    }

    /// An older iPhone sends neither: the Mac drives as before.
    func testAnOlderIPhoneSendsNoRoadsAndNoLimits() throws {
        let json = #"{"waypoints":[{"latitude":1,"longitude":2},{"latitude":3,"longitude":4}],"speed":5,"followRoads":true}"#
        let request = try RemoteAPI.makeDecoder().decode(RouteRequest.self, from: Data(json.utf8))
        XCTAssertNil(request.legs)
        XCTAssertNil(request.followSpeedLimits)
        XCTAssertNil(RoadRoute(request: request))
        XCTAssertFalse(RouteRunner.followsLimits(request))
    }

    /// Roads that can't be read are dropped, not the route.
    func testUnreadableLegsLeaveTheRouteStanding() throws {
        let json = #"{"waypoints":[{"latitude":1,"longitude":2},{"latitude":3,"longitude":4}],"speed":5,"legs":"nope"}"#
        let request = try RemoteAPI.makeDecoder().decode(RouteRequest.self, from: Data(json.utf8))
        XCTAssertTrue(request.isValid)
        XCTAssertNil(request.legs)
    }

    func testLegsMustFitTheStops() {
        var request = RouteRequest(waypoints: [a, b, c], followRoads: true, legs: [detour, nil])
        XCTAssertNotNil(request.usableLegs)
        request.legs = [detour]
        XCTAssertNil(request.usableLegs, "one leg short")
        request.legs = [detour, nil, nil]
        XCTAssertNil(request.usableLegs, "a way back on a route that doesn't loop")
        request.loopMode = "loop"
        XCTAssertNotNil(request.usableLegs, "a loop has its way back")
        request.legs = [RoadLeg(coordinates: [37.3349, -122.0090, 95, 0]), nil, nil]
        XCTAssertNil(request.usableLegs, "a point that isn't a place")
        request.legs = [RoadLeg(coordinates: [37.3349, -122.0090, 37.3349]), nil, nil]
        XCTAssertNil(request.usableLegs, "half a point")
        let tooMany = [Double](repeating: 37.3349, count: (RemoteAPI.maxRoadPoints + 1) * 2)
        request.legs = [RoadLeg(coordinates: tooMany), nil, nil]
        XCTAssertNil(request.usableLegs, "more road than a route carries")
    }

    func testCoordinatesAreKeptToSixDecimals() {
        let leg = RoadLeg(points: [(37.123456789, -122.987654321), (37.2, -122.1)])
        XCTAssertEqual(leg.coordinates, [37.123457, -122.987654, 37.2, -122.1])
        XCTAssertEqual(leg.pointCount, 2)
        XCTAssertTrue(leg.isValid)
    }

    // MARK: Roads

    func testTheRouteFollowsTheLegsAndKnowsWhereEachStopIs() throws {
        let request = RouteRequest(waypoints: [a, b, c], followRoads: true, travelMode: "driving",
                                   legs: [detour, nil])
        let roads = try XCTUnwrap(RoadRoute(request: request))
        XCTAssertEqual(roads.roadLegs, 1)
        XCTAssertEqual(roads.path.points.count, 5, "the detour's four points, then straight on to C")
        XCTAssertEqual(roads.stopDistances.count, 3)
        XCTAssertEqual(roads.stopDistances[0], 0)
        XCTAssertEqual(roads.stopDistances[1], 820, accuracy: 10, "B is at the end of the detour, not 350 m in")
        XCTAssertEqual(roads.stopDistances[2], roads.path.length, accuracy: 1e-6)
        XCTAssertEqual(roads.legZones.count, 1, "Apple Maps' speed for the leg it found")
        XCTAssertEqual(roads.legZones[0].speed, 820 / 60 * 1.15, accuracy: 0.01)
    }

    /// A leg for somewhere else is not driven.
    func testLegsThatDontMeetTheStopsAreIgnored() {
        let elsewhere = RoadLeg(points: [(40.0, -74.0), (40.01, -74.0)])
        let request = RouteRequest(waypoints: [a, b], followRoads: true, legs: [elsewhere])
        XCTAssertNotNil(request.usableLegs)
        XCTAssertNil(RoadRoute(request: request))
    }

    func testALoopDrivesItsWayBackOnTheRoadSent() throws {
        let back = RoadLeg(points: [(37.3349, -122.0050), (37.3330, -122.0050), (37.3330, -122.0090), (37.3349, -122.0090)])
        let request = RouteRequest(waypoints: [a, b], followRoads: true, loopMode: "loop", legs: [detour, back])
        let roads = try XCTUnwrap(RoadRoute(request: request))
        XCTAssertTrue(roads.path.isClosed)
        XCTAssertEqual(try RouteRunner.playedPath(for: request).length, roads.path.length, accuracy: 1e-6,
                       "already closed: no straight line added back to the start")
    }

    func testTheRunnerDrivesTheRoadNotAStraightLine() throws {
        let request = RouteRequest(waypoints: [a, b], followRoads: true, travelMode: "driving", speed: 10,
                                   realistic: false, legs: [detour])
        let runner = try RouteRunner.build(from: request)
        XCTAssertEqual(runner.duration, 82, accuracy: 3, "820 m at 10 m/s")
        XCTAssertEqual(runner.position(at: runner.duration / 2).point.latitude, 37.3370, accuracy: 1e-4,
                       "half way, it's on the far side of the detour")
    }

    /// A wait at a stop happens at that stop, where the legs meet, whatever shape the road is.
    func testAWaitIsAtItsStopOnTheRoad() throws {
        var middle = b
        middle.wait = 60
        let request = RouteRequest(waypoints: [a, middle, c], followRoads: true, travelMode: "driving", speed: 10,
                                   realistic: false, legs: [detour, nil])
        let runner = try RouteRunner.build(from: request)
        let stop = GeoPoint(b.latitude, b.longitude)
        let parked = stride(from: 0.0, to: runner.duration, by: 1).filter {
            runner.position(at: $0).point.distance(to: stop) < 1
        }
        XCTAssertGreaterThanOrEqual(parked.count, 58)
        XCTAssertGreaterThan(parked.first ?? 0, 70, "after the detour, not part way along it")
    }

    // MARK: Limits

    /// About 3.5 km east, gently bent like a road: long enough for the cruise to matter.
    private func longRequest(followSpeedLimits: Bool?, expectedSeconds: Double? = 150) -> RouteRequest {
        let leg = RoadLeg(points: [(37.33, -122.03), (37.331, -122.01), (37.33, -121.99)], meters: 3550,
                          expectedSeconds: expectedSeconds)
        return RouteRequest(waypoints: [.init(latitude: 37.33, longitude: -122.03), .init(latitude: 37.33, longitude: -121.99)],
                            followRoads: true, travelMode: "driving", speed: 8, realistic: true,
                            legs: [leg], followSpeedLimits: followSpeedLimits)
    }

    func testFollowingLimitsDrivesAppleMapsSpeedWhenOpenStreetMapHasNothing() throws {
        let capped = try RouteRunner.build(from: longRequest(followSpeedLimits: nil))
        let atLimits = try RouteRunner.build(from: longRequest(followSpeedLimits: true))
        XCTAssertGreaterThan(capped.duration, 3550 / 8 - 1, "the chosen speed is the most it ever goes")
        // Apple Maps: 3550 m in 150 s, so about 27 m/s.
        XCTAssertLessThan(atLimits.duration, capped.duration / 2)
    }

    func testOpenStreetMapLimitsComeFirst() throws {
        let path = try RouteRunner.playedPath(for: longRequest(followSpeedLimits: true))
        let features = RoadFeatures(zones: [SpeedZone(start: 0, end: path.length, speed: 12)])
        let runner = try RouteRunner.build(from: longRequest(followSpeedLimits: true), features: features)
        // 12 m/s, give or take the driver's habit and getting going: not Apple Maps' 27, nor the chosen 8.
        XCTAssertGreaterThan(runner.duration, path.length / 12 / 1.06)
        XCTAssertLessThan(runner.duration, path.length / 12 / 0.94 + 30)
    }

    func testLimitsAreOnlyForDrivingLikeAPersonOnRoads() {
        XCTAssertTrue(RouteRunner.followsLimits(longRequest(followSpeedLimits: true)))
        var request = longRequest(followSpeedLimits: true)
        request.realistic = false
        XCTAssertFalse(RouteRunner.followsLimits(request))
        request = longRequest(followSpeedLimits: true)
        request.travelMode = "walking"
        XCTAssertFalse(RouteRunner.followsLimits(request))
        XCTAssertFalse(RouteRunner.followsLimits(longRequest(followSpeedLimits: false)))
    }

    // MARK: Server

    /// A route with its roads may be bigger than other calls, which stay small.
    func testOnlyARouteMayCarryABigBody() {
        func head(_ path: String, _ length: Int) -> String {
            "POST \(path) HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n"
        }
        let body = String(repeating: "x", count: 300_000)
        guard case .complete(let request) = HTTPRequest.parse(Data((head("/route", body.count) + body).utf8)) else {
            return XCTFail("a 300 KB route should be read")
        }
        XCTAssertEqual(request.body.count, 300_000)
        XCTAssertEqual(HTTPRequest.parse(Data(head("/location", 300_000).utf8)),
                       .invalid(status: 413, message: "Request too large."))
        XCTAssertEqual(HTTPRequest.parse(Data(head("/route", RemoteAPI.maxRouteBodyBytes + 1).utf8)),
                       .invalid(status: 413, message: "Request too large."))
    }
}
