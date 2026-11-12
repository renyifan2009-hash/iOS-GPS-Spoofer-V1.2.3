import Foundation
import PhoneOnlyCore
import XCTest

final class SpeedLimitDriveTests: XCTestCase {
    private let start = StandaloneRoute.Point(37.0, -122.0)

    private func east(_ meters: Double) -> StandaloneRoute.Point {
        let p = PhoneGeo.moved(latitude: start.latitude, longitude: start.longitude, meters: meters, bearing: 90)
        return StandaloneRoute.Point(p.latitude, p.longitude)
    }

    /// 4 km straight east, chosen speed 30 mph (13.4 m/s).
    private func straight(waits: [Double] = [0, 0]) throws -> StandaloneRoute {
        try StandaloneRoute(legs: [stride(from: 0.0, through: 4_000, by: 100).map(east)], waits: waits,
                            speed: 13.4112, repeatMode: "once")
    }

    /// Drives the whole route and gives the average speed while the car is between `range` metres.
    private func averageSpeed(_ drive: inout NaturalDrive, in ranges: [ClosedRange<Double>]) -> [Double] {
        var sums = [Double](repeating: 0, count: ranges.count), counts = sums
        for _ in 0..<20_000 {
            let step = drive.advance(dt: 0.25)
            let meters = drive.route.meters(at: step.elapsed)
            for (i, range) in ranges.enumerated() where range.contains(meters) && step.reason == nil {
                sums[i] += step.speed
                counts[i] += 1
            }
            if drive.route.sample(at: step.elapsed).finished { break }
        }
        return zip(sums, counts).map { $1 > 0 ? $0 / $1 : 0 }
    }

    func testMetersFollowTheTimelineAndWaitsAddNone() throws {
        let route = try straight(waits: [30, 0])
        XCTAssertEqual(route.passMeters, 4_000, accuracy: 1)
        XCTAssertEqual(route.meters(at: 10), 0, accuracy: 0.001, "waiting before leaving")
        XCTAssertEqual(route.meters(at: 30 + 10), 134.112, accuracy: 0.5)
        XCTAssertEqual(route.meters(at: 1e9), route.passMeters, "past the end")
        XCTAssertEqual(route.passPath.count, 41)
        XCTAssertEqual(route.passPath.first, start)
    }

    func testItDrivesEachRoadNearItsLimitNotTheChosenSpeed() throws {
        let route = try straight()
        let mph = 0.44704
        let zones = [SpeedZone(start: 0, end: 1_800, speed: 25 * mph), SpeedZone(start: 1_800, end: 4_000, speed: 55 * mph)]
        var drive = NaturalDrive(route: route, driving: true, speedLimits: zones, seed: 11)
        let averages = averageSpeed(&drive, in: [800...1_500, 2_600...3_300])
        XCTAssertEqual(averages[0] / (25 * mph), 0.98, accuracy: 0.08, "the 25 mph road at about 25 mph")
        XCTAssertEqual(averages[1] / (55 * mph), 0.98, accuracy: 0.08, "the 55 mph road at about 55, well over the chosen 30")
    }

    func testWhereNoLimitIsKnownItUsesTheChosenSpeed() throws {
        let route = try straight()
        let zones = [SpeedZone(start: 0, end: 1_500, speed: 30)]   // a fast first stretch only
        var drive = NaturalDrive(route: route, driving: true, speedLimits: zones, seed: 3)
        let averages = averageSpeed(&drive, in: [2_300...3_200])
        XCTAssertEqual(averages[0] / 13.4112, 0.98, accuracy: 0.08)
    }

    func testWalkingIgnoresSpeedLimits() throws {
        let route = try StandaloneRoute(legs: [stride(from: 0.0, through: 400, by: 50).map(east)], waits: [0, 0],
                                        speed: 1.4, repeatMode: "once")
        let drive = NaturalDrive(route: route, driving: false, speedLimits: [SpeedZone(start: 0, end: 400, speed: 25)])
        XCTAssertTrue(drive.speedLimits.isEmpty)
        XCTAssertNil(drive.limit(at: 10))
    }

    func testTheLimitIsLookedUpWhereTheCarIs() throws {
        let route = try straight(waits: [20, 0])
        let zones = [SpeedZone(start: 500, end: 900, speed: 20), SpeedZone(start: 0, end: 500, speed: 10)]
        let drive = NaturalDrive(route: route, driving: true, speedLimits: zones)
        XCTAssertEqual(drive.limit(at: 5), 10, "standing at the start")
        XCTAssertEqual(drive.limit(at: 20 + 600 / 13.4112), 20)
        XCTAssertNil(drive.limit(at: 20 + 2_000 / 13.4112), "no limit known there")
    }

    func testARoadsOwnLimitBeatsTheLegsTypicalSpeed() {
        let merged = SpeedZone.merged(primary: [SpeedZone(start: 100, end: 300, speed: 20)],
                                      fallback: [SpeedZone(start: 0, end: 500, speed: 10)])
        XCTAssertEqual(merged, [SpeedZone(start: 0, end: 100, speed: 10), SpeedZone(start: 100, end: 300, speed: 20),
                                SpeedZone(start: 300, end: 500, speed: 10)])
        XCTAssertEqual(SpeedZone.merged(primary: [], fallback: [SpeedZone(start: 0, end: 50, speed: 9)]),
                       [SpeedZone(start: 0, end: 50, speed: 9)])
    }

    func testAppleMapsTimeGivesASensibleCruise() throws {
        // 3.2 km in 6 minutes (about 20 mph on average, lights and corners included): a cruise near 23 mph.
        let cruise = try XCTUnwrap(SpeedZone.cruise(meters: 3_200, expectedSeconds: 360))
        XCTAssertEqual(cruise / 0.44704, 22.9, accuracy: 0.3)
        XCTAssertEqual(try XCTUnwrap(SpeedZone.cruise(meters: 100_000, expectedSeconds: 1_200)) / 0.44704, 75, accuracy: 0.01)
        XCTAssertNil(SpeedZone.cruise(meters: 10, expectedSeconds: 5), "too short to say")
    }

    // MARK: Loading from OpenStreetMap

    /// An Overpass answer: one road along the route, signed 35 mph.
    private func answer(maxspeed: String) -> Data {
        let geometry = stride(from: 0.0, through: 4_000, by: 200).map(east)
            .map { "{\"lat\":\($0.latitude),\"lon\":\($0.longitude)}" }.joined(separator: ",")
        return Data("""
        {"elements":[{"type":"way","id":7,"tags":{"highway":"primary","maxspeed":"\(maxspeed)"},"geometry":[\(geometry)]}]}
        """.utf8)
    }

    func testItLoadsTheLimitsAlongTheRoute() async throws {
        let route = try straight()
        let data = answer(maxspeed: "35 mph")
        let loader = RoadSpeedLimits(userAgent: "AnyWhere-test", timeBudget: 5) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(String(decoding: request.httpBody ?? Data(), as: UTF8.self).hasPrefix("data="))
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let zones = await loader.zones(along: route.passPath.map { GeoPoint($0.latitude, $0.longitude) })
        let covered = zones.reduce(0) { $0 + $1.end - $1.start }
        XCTAssertGreaterThan(covered, 3_800, "nearly all of the route is on that road")
        XCTAssertTrue(zones.allSatisfy { abs($0.speed - 35 * 0.44704) < 0.01 })
    }

    func testNoNetworkMeansNoLimitsNotAnError() async throws {
        let route = try straight()
        let loader = RoadSpeedLimits(userAgent: "AnyWhere-test", timeBudget: 2) { _ in throw URLError(.notConnectedToInternet) }
        let zones = await loader.zones(along: route.passPath.map { GeoPoint($0.latitude, $0.longitude) })
        XCTAssertTrue(zones.isEmpty)
    }

    /// Against the real Overpass API, only with `AW_LIVE_OVERPASS=1`: a real road's own shape gets
    /// that road's limit back.
    func testLiveRoadGetsItsOwnLimit() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AW_LIVE_OVERPASS"] == "1", "live network test")
        let agent = "AnyWhere-tests (+https://github.com/renyifan2009-hash/iOS-GPS-Spoofer-V1.2.3)"
        // Stevens Creek Blvd, Cupertino: find a primary road there and use its geometry as the route.
        let query = "[out:json][timeout:25];way(around:60,37.3236,-122.0322)[highway=primary][maxspeed];out geom;"
        var answered: Data?
        for endpoint in OverpassQuery.endpoints where answered == nil {
            var request = URLRequest(url: endpoint, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = OverpassQuery.body(query)
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 { answered = data }
        }
        let data = try XCTUnwrap(answered, "no Overpass server answered")
        let road = try XCTUnwrap(OverpassAnswer.decode(data).ways.max { $0.points.count < $1.points.count })
        let expected = try XCTUnwrap(SpeedLimits.speed(tags: road.tags))
        let zones = await RoadSpeedLimits(userAgent: agent, timeBudget: 40).zones(along: road.points)
        let length = RoutePath(road.points).length
        let matching = zones.filter { abs($0.speed - expected) < 0.01 }.reduce(0) { $0 + $1.end - $1.start }
        print("live: \(road.tags["name"] ?? "?") maxspeed \(road.tags["maxspeed"] ?? "?"), \(Int(length)) m,",
              "\(Int(matching)) m at that limit, zones \(zones.map { Int(($0.speed * 2.23694).rounded()) }) mph")
        XCTAssertGreaterThan(matching, length * 0.6)
    }

    func testAnOverpassRemarkIsAnError() {
        let data = Data(#"{"elements":[],"remark":"runtime error: Query timed out"}"#.utf8)
        XCTAssertThrowsError(try OverpassAnswer.decode(data)) { error in
            XCTAssertEqual((error as? OverpassAnswer.Remark)?.text, "runtime error: Query timed out")
        }
    }
}
