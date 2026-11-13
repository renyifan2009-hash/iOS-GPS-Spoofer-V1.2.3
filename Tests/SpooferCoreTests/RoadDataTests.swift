import Foundation
import XCTest
@testable import SpooferCore

final class RoadDataTests: XCTestCase {
    let a = GeoPoint(37, -122)

    func testPassesFindsEachPassAndItsDistance() {
        // Out 1 km north and back: a point 3 m east of the 400 m mark is passed twice.
        let top = a.moved(by: 1000, bearing: 0)
        let path = RoutePath([a, top, a])
        let matcher = RouteMatcher(path: path)
        let near = a.moved(by: 400, bearing: 0).moved(by: 3, bearing: 90)
        let passes = matcher.passes(near: near, radius: 10)
        XCTAssertEqual(passes.count, 2)
        XCTAssertEqual(passes.first?.distance ?? 0, 400, accuracy: 0.5)
        XCTAssertEqual(passes.last?.distance ?? 0, 1600, accuracy: 0.5)
        XCTAssertEqual(passes.first?.offset ?? 0, 3, accuracy: 0.2)
        XCTAssertTrue(matcher.passes(near: near.moved(by: 30, bearing: 90), radius: 10).isEmpty)
    }

    func testWaypointDistances() {
        let b = a.moved(by: 300, bearing: 0), c = b.moved(by: 500, bearing: 90)
        let path = RoutePath([a, a.moved(by: 150, bearing: 0), b, b.moved(by: 250, bearing: 90), c])
        XCTAssertEqual(RouteMatcher(path: path).distances(ofWaypoints: [a, b, c]).map { $0.rounded() }, [0, 300, 800])
    }

    func testMaxspeedParsing() {
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "50") ?? 0, 50 / 3.6, accuracy: 1e-9)
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "30 mph") ?? 0, 30 * 0.44704, accuracy: 1e-9)
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "DE:urban") ?? 0, 50 / 3.6, accuracy: 1e-9)
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "GB:nsl_dual") ?? 0, 70 * 0.44704, accuracy: 1e-9)
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "none") ?? 0, 130 / 3.6, accuracy: 1e-9)
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "50;30") ?? 0, 50 / 3.6, accuracy: 1e-9)
        XCTAssertNil(SpeedLimits.parse(maxspeed: "signals"))
        XCTAssertNil(SpeedLimits.parse(maxspeed: "fast"))
        XCTAssertEqual(SpeedLimits.speed(tags: ["highway": "residential"]) ?? 0, 40 / 3.6, accuracy: 1e-9)
        XCTAssertNil(SpeedLimits.speed(tags: ["highway": "footway"]))
    }

    func testZonesFollowTheRoadsUnderTheRoute() {
        let mid = a.moved(by: 500, bearing: 0), end = a.moved(by: 1000, bearing: 0)
        let path = RoutePath([a, end])
        let ways = [
            OSMWay(id: 1, points: [a, mid], tags: ["highway": "primary", "maxspeed": "45 mph"]),
            OSMWay(id: 2, points: [mid, end], tags: ["highway": "residential"]),
            // A cross street at 500 m must not win.
            OSMWay(id: 3, points: [mid.moved(by: 100, bearing: 270), mid.moved(by: 100, bearing: 90)],
                   tags: ["highway": "motorway"]),
        ]
        let zones = SpeedLimits.zones(along: path, ways: ways)
        XCTAssertEqual(zones.count, 2)
        XCTAssertEqual(zones.first?.speed ?? 0, 45 * 0.44704, accuracy: 1e-9)
        XCTAssertEqual(zones.last?.speed ?? 0, 40 / 3.6, accuracy: 1e-9)
        XCTAssertEqual(zones.first?.end ?? 0, zones.last?.start ?? 1, accuracy: 1e-9)
        XCTAssertEqual(zones.last?.start ?? 0, 500, accuracy: 25)
    }

    // MARK: Overpass

    /// An Overpass answer for a 1 km route going north from `a`.
    private func answerJSON(path: RoutePath) -> Data {
        func at(_ d: Double, east: Double) -> GeoPoint { path.sample(at: d).point.moved(by: east, bearing: 90) }
        func node(_ id: Int, _ p: GeoPoint, _ tags: [String: String]) -> [String: Any] {
            ["type": "node", "id": id, "lat": p.latitude, "lon": p.longitude, "tags": tags]
        }
        func way(_ id: Int, _ points: [GeoPoint], _ tags: [String: String]) -> [String: Any] {
            ["type": "way", "id": id, "tags": tags,
             "geometry": points.map { ["lat": $0.latitude, "lon": $0.longitude] }]
        }
        let elements: [[String: Any]] = [
            node(1, at(200, east: 0), ["highway": "traffic_signals"]),
            node(2, at(215, east: 3), ["highway": "traffic_signals"]),             // same junction: merged
            node(3, at(500, east: 4), ["highway": "stop"]),
            node(4, at(700, east: 20), ["highway": "stop"]),                        // a side street's: ignored
            node(5, at(850, east: 2), ["highway": "crossing", "crossing": "traffic_signals"]),
            node(6, at(950, east: 0), ["highway": "traffic_signals", "traffic_signals": "emergency"]),
            node(7, at(225, east: 5), ["highway": "crossing", "crossing": "traffic_signals"]),   // part of the 200 m junction
            way(10, [at(0, east: 0), at(600, east: 0)], ["highway": "primary", "maxspeed": "35 mph"]),
            way(11, [at(600, east: 0), at(1000, east: 0)], ["highway": "residential"]),
        ]
        return (try? JSONSerialization.data(withJSONObject: ["version": 0.6, "elements": elements])) ?? Data()
    }

    func testParseAndMatchAnOverpassAnswer() throws {
        let path = RoutePath([a, a.moved(by: 1000, bearing: 0)])
        let answer = try OverpassLoader.parse(answerJSON(path: path))
        XCTAssertEqual(answer.nodes.count, 7)
        XCTAssertEqual(answer.ways.count, 2)
        let features = OverpassLoader.features(from: answer, along: path)
        let lights = features.features.filter { $0.kind == .trafficSignal }
        XCTAssertEqual(lights.filter { $0.facing != .backward }.map { $0.distance.rounded() }, [200])
        // Coming back the other way, the first of the junction's two lights met is the other one.
        XCTAssertEqual(lights.filter { $0.facing != .forward }.map { $0.distance.rounded() }, [215])
        XCTAssertEqual(features.features.filter { $0.kind == .stopSign }.count, 1)
        XCTAssertEqual(features.features.filter { $0.kind == .signalCrossing }.count, 1)
        XCTAssertEqual(features.zones.first?.speed ?? 0, 35 * 0.44704, accuracy: 1e-9)
        XCTAssertGreaterThan(features.speedLimitCoverage(of: path.length), 0.9)
    }

    func testOverpassErrorRemarksThrow() {
        let data = Data(#"{"elements": [], "remark": "runtime error: Query timed out"}"#.utf8)
        XCTAssertThrowsError(try OverpassLoader.parse(data))
    }

    func testQueryLooksRight() {
        let line = [a, a.moved(by: 100, bearing: 0)]
        let q = OverpassLoader.query(for: line, padding: 3, roads: true)
        XCTAssertTrue(q.hasPrefix("[out:json][timeout:25];"))
        XCTAssertTrue(q.contains("node(around:21,37.000000,-122.000000,"))
        XCTAssertTrue(q.contains("[highway=traffic_signals]"))
        XCTAssertTrue(q.contains("way(around:9,"))
        XCTAssertTrue(q.hasSuffix("out geom;"))
        XCTAssertFalse(OverpassLoader.query(for: line, padding: 3, roads: false).contains("way("))
    }

    func testLongRoutesAreSplitIntoPieces() {
        let path = RoutePath((0...40).map { a.moved(by: Double($0) * 1000, bearing: 0) })
        let chunks = OverpassLoader.chunks(of: path)
        XCTAssertEqual(chunks.count, 3)                      // 40 km in pieces of 15 km or less
        XCTAssertTrue(chunks.allSatisfy { $0.points.count <= 150 })
        XCTAssertEqual(chunks.first?.points.first, path.start)
        XCTAssertEqual(chunks.last?.points.last, path.end)
    }

    func testLoaderFallsBackThenUsesItsCache() async throws {
        let path = RoutePath([a, a.moved(by: 1000, bearing: 0)])
        let body = answerJSON(path: path)
        let calls = Counter()
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let loader = OverpassLoader(userAgent: "test", cacheDirectory: cache) { request in
            _ = await calls.increment()
            // The first server can't be reached; the next one answers.
            if request.url?.host == "overpass-api.de" { throw URLError(.cannotConnectToHost) }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
        let first = try await loader.features(along: path, roads: true)
        XCTAssertEqual(first.uniqueCount(of: .trafficSignal), 1)
        XCTAssertTrue(first.complete)
        let before = await calls.value
        XCTAssertEqual(before, 2)
        _ = try await loader.features(along: path, roads: true)       // from the cache
        let after = await calls.value
        XCTAssertEqual(after, before)
    }
}

actor Counter {
    private(set) var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}

extension RoadDataTests {
    func testALightNearALoopsStartCountsOnce() {
        let square = RoutePath([a, a.moved(by: 300, bearing: 0), a.moved(by: 300, bearing: 0).moved(by: 300, bearing: 90),
                                a.moved(by: 300, bearing: 90), a])
        let light = OSMNode(id: 1, point: a.moved(by: 5, bearing: 45), tags: ["highway": "traffic_signals"])
        let features = OverpassLoader.features(from: OverpassAnswer(nodes: [light], ways: []), along: square)
        XCTAssertEqual(features.features.count, 1)
        XCTAssertGreaterThan(features.features.first?.distance ?? 0, square.length - 40)   // met as the lap ends
    }
}

/// Which signs and lights are for the route's own direction.
final class SignDirectionTests: XCTestCase {
    let a = GeoPoint(37, -122)

    /// A crossroads 200 m up a 400 m north–south road (way 1, nodes 101–105),
    /// crossed by an east–west street (way 2, nodes 201–203).
    private func crossroads(_ nodes: [OSMNode]) -> OverpassAnswer {
        let j = a.moved(by: 200, bearing: 0)
        let north = OSMWay(id: 1, points: [a, a.moved(by: 192, bearing: 0), j, a.moved(by: 208, bearing: 0),
                                           a.moved(by: 400, bearing: 0)],
                           tags: ["highway": "residential"], nodeIDs: [101, 102, 103, 104, 105])
        let east = OSMWay(id: 2, points: [j.moved(by: 200, bearing: 270), j.moved(by: 5, bearing: 270), j,
                                          j.moved(by: 200, bearing: 90)],
                          tags: ["highway": "residential"], nodeIDs: [201, 202, 103, 203])
        return OverpassAnswer(nodes: nodes, ways: [north, east])
    }

    private var signs: [OSMNode] {
        let j = a.moved(by: 200, bearing: 0)
        return [
            OSMNode(id: 102, point: a.moved(by: 192, bearing: 0), tags: ["highway": "stop"]),   // before the junction, northbound
            OSMNode(id: 104, point: a.moved(by: 208, bearing: 0), tags: ["highway": "stop", "direction": "backward"]),
            OSMNode(id: 202, point: j.moved(by: 5, bearing: 270), tags: ["highway": "stop"]),   // the cross street's
        ]
    }

    func testStopSignsOnlyCountForTheirDirection() {
        let northbound = RoutePath([a, a.moved(by: 400, bearing: 0)])
        let found = OverpassLoader.features(from: crossroads(signs), along: northbound).features
        XCTAssertEqual(found.map { $0.distance.rounded() }, [192, 208])
        XCTAssertEqual(found.map(\.facing), [.forward, .backward])
        // Southbound, the other sign is the one before the junction.
        let southbound = RoutePath([a.moved(by: 400, bearing: 0), a])
        let back = OverpassLoader.features(from: crossroads(signs), along: southbound).features
        XCTAssertEqual(back.map { $0.distance.rounded() }, [192, 208])
        XCTAssertEqual(back.map(\.facing), [.forward, .backward])
        XCTAssertEqual(back.first?.point, signs[1].point)
    }

    func testEachDirectionStopsAtItsOwnLight() {
        let j = a.moved(by: 200, bearing: 0)
        let lights = [
            OSMNode(id: 102, point: a.moved(by: 192, bearing: 0),
                    tags: ["highway": "traffic_signals", "traffic_signals:direction": "forward"]),
            OSMNode(id: 104, point: a.moved(by: 208, bearing: 0),
                    tags: ["highway": "traffic_signals", "traffic_signals:direction": "backward"]),
            OSMNode(id: 202, point: j.moved(by: 5, bearing: 270), tags: ["highway": "traffic_signals"]),
        ]
        let path = RoutePath([a, a.moved(by: 400, bearing: 0)])
        let features = OverpassLoader.features(from: crossroads(lights), along: path)
        XCTAssertEqual(features.features.map { $0.distance.rounded() }, [192, 208])
        XCTAssertEqual(features.features.map(\.facing), [.forward, .backward])
        XCTAssertEqual(features.uniqueCount(of: .trafficSignal), 1)
        XCTAssertEqual(features.uniqueCount(of: .trafficSignal, wayBack: true), 2)
    }

    func testAnUntaggedYieldSignFacesTheJunctionPastIt() {
        let yield = OSMNode(id: 102, point: a.moved(by: 192, bearing: 0), tags: ["highway": "give_way"])
        let path = RoutePath([a, a.moved(by: 400, bearing: 0)])
        XCTAssertEqual(OverpassLoader.features(from: crossroads([yield]), along: path).features.map(\.facing), [.forward])
    }

    func testASignMidwayBetweenTwoJunctionsCountsBothWays() {
        // Junctions at 185 m and 215 m (side streets both ways); the sign is 15 m from each.
        let j1 = a.moved(by: 185, bearing: 0), j2 = a.moved(by: 215, bearing: 0)
        let road = OSMWay(id: 1, points: [a, j1, a.moved(by: 200, bearing: 0), j2, a.moved(by: 400, bearing: 0)],
                          tags: ["highway": "residential"], nodeIDs: [101, 102, 103, 104, 105])
        let side1 = OSMWay(id: 2, points: [j1, j1.moved(by: 100, bearing: 90)], tags: ["highway": "residential"],
                           nodeIDs: [102, 201])
        let side2 = OSMWay(id: 3, points: [j2, j2.moved(by: 100, bearing: 270)], tags: ["highway": "residential"],
                           nodeIDs: [104, 301])
        let sign = OSMNode(id: 103, point: a.moved(by: 200, bearing: 0), tags: ["highway": "stop"])
        let answer = OverpassAnswer(nodes: [sign], ways: [road, side1, side2])
        let found = OverpassLoader.features(from: answer, along: RoutePath([a, a.moved(by: 400, bearing: 0)])).features
        XCTAssertEqual(found.map(\.facing), [.both])
    }

    /// A divided road running east: the eastbound half (way 1) and, 12 m north, the westbound half (way 2),
    /// both one-way, crossed at 200 m by a two-way street (way 3). Like Stevens Creek Boulevard in Cupertino.
    private func dividedRoad(_ lights: [OSMNode], extraWays: [OSMWay] = []) -> OverpassAnswer {
        let west = a, j = a.moved(by: 200, bearing: 90), farEast = a.moved(by: 400, bearing: 90)
        let north = { (p: GeoPoint) in p.moved(by: 12, bearing: 0) }
        let eastbound = OSMWay(id: 1, points: [west, a.moved(by: 185, bearing: 90), j, farEast],
                               tags: ["highway": "primary", "oneway": "yes"], nodeIDs: [101, 102, 103, 104])
        let westbound = OSMWay(id: 2, points: [north(farEast), north(a.moved(by: 215, bearing: 90)), north(j), north(west)],
                               tags: ["highway": "primary", "oneway": "yes"], nodeIDs: [201, 202, 203, 204])
        let cross = OSMWay(id: 3, points: [j.moved(by: 100, bearing: 180), j.moved(by: 8, bearing: 180), j, north(j),
                                           north(j).moved(by: 100, bearing: 0)],
                           tags: ["highway": "secondary"], nodeIDs: [301, 302, 103, 203, 303])
        return OverpassAnswer(nodes: lights, ways: [eastbound, westbound, cross] + extraWays)
    }

    private var eastbound: RoutePath { RoutePath([a, a.moved(by: 400, bearing: 90)]) }

    func testOnADividedRoadOnlyThisSidesLightCounts() {
        let lights = [
            OSMNode(id: 102, point: a.moved(by: 185, bearing: 90), tags: ["highway": "traffic_signals"]),   // this side's
            OSMNode(id: 202, point: a.moved(by: 215, bearing: 90).moved(by: 12, bearing: 0),
                    tags: ["highway": "traffic_signals"]),   // the westbound half's, past the junction
            OSMNode(id: 302, point: a.moved(by: 200, bearing: 90).moved(by: 8, bearing: 180),
                    tags: ["highway": "traffic_signals"]),   // the cross street's
        ]
        let found = OverpassLoader.features(from: dividedRoad(lights), along: eastbound).features
        let going = found.filter { $0.facing != .backward }
        XCTAssertEqual(going.map { $0.distance.rounded() }, [185], "one stop at the junction, at this side's light")
        XCTAssertEqual(going.first?.facing, .forward)
    }

    func testTheOtherHalfsCrossingLightBetweenJunctionsDoesNotCount() {
        // A crossing light on the westbound half only, 100 m from the junction.
        let westbound = OSMWay(id: 2, points: [a.moved(by: 400, bearing: 90).moved(by: 12, bearing: 0),
                                               a.moved(by: 100, bearing: 90).moved(by: 12, bearing: 0),
                                               a.moved(by: 12, bearing: 0)],
                               tags: ["highway": "primary", "oneway": "yes"], nodeIDs: [201, 205, 204])
        let eastboundHalf = OSMWay(id: 1, points: [a, a.moved(by: 400, bearing: 90)],
                                   tags: ["highway": "primary", "oneway": "yes"], nodeIDs: [101, 104])
        let light = OSMNode(id: 205, point: a.moved(by: 100, bearing: 90).moved(by: 12, bearing: 0),
                            tags: ["highway": "traffic_signals"])
        let answer = OverpassAnswer(nodes: [light], ways: [eastboundHalf, westbound])
        let found = OverpassLoader.features(from: answer, along: eastbound).features
        XCTAssertEqual(found.map(\.facing), [.backward], "only for the way back, which drives the other half")
    }

    func testAJunctionMappedOnlyOnTheOtherHalfStillHasALight() {
        // Only the westbound half's crossing with the cross street is tagged: the junction has lights.
        let light = OSMNode(id: 203, point: a.moved(by: 200, bearing: 90).moved(by: 12, bearing: 0),
                            tags: ["highway": "traffic_signals"])
        let found = OverpassLoader.features(from: dividedRoad([light]), along: eastbound).features
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.distance ?? 0, 200, accuracy: 1)
    }

    func testALightOnNoLoadedRoadNearThisSidesLightDoesNotAddAStop() {
        let lights = [
            OSMNode(id: 102, point: a.moved(by: 185, bearing: 90), tags: ["highway": "traffic_signals"]),
            OSMNode(id: 999, point: a.moved(by: 225, bearing: 90).moved(by: 10, bearing: 0),
                    tags: ["highway": "traffic_signals"]),
        ]
        let found = OverpassLoader.features(from: dividedRoad(lights), along: eastbound).features
        XCTAssertEqual(found.filter { $0.facing != .backward }.map { $0.distance.rounded() }, [185])
    }

    func testOnATwoWayRoadEachDirectionStopsAtTheLightBeforeTheJunction() {
        // Untagged lights on both approaches of the crossroads, 16 m apart, on the north–south road.
        let lights = [
            OSMNode(id: 102, point: a.moved(by: 192, bearing: 0), tags: ["highway": "traffic_signals"]),
            OSMNode(id: 104, point: a.moved(by: 208, bearing: 0), tags: ["highway": "traffic_signals"]),
        ]
        let path = RoutePath([a, a.moved(by: 400, bearing: 0)])
        let found = OverpassLoader.features(from: crossroads(lights), along: path).features
        XCTAssertEqual(found.map { $0.distance.rounded() }, [192, 208])
        XCTAssertEqual(found.map(\.facing), [.forward, .backward])
    }

    func testWithoutTheRoadsEverySignNearbyCounts() {
        let path = RoutePath([a, a.moved(by: 400, bearing: 0)])
        let bare = OverpassAnswer(nodes: signs, ways: [])
        let found = OverpassLoader.features(from: bare, along: path).features
        // The cross street's sign joins the junction's; the other two are 16 m apart.
        XCTAssertEqual(found.map { $0.distance.rounded() }, [192, 208])
        XCTAssertTrue(found.allSatisfy { $0.facing == .both })
    }

    func testParseKeepsEachWaysNodes() throws {
        let json = #"""
        {"elements": [
          {"type": "way", "id": 1, "nodes": [11, 12, 13], "tags": {"highway": "primary"},
           "geometry": [{"lat": 37, "lon": -122}, {"lat": 37.001, "lon": -122}, {"lat": 37.002, "lon": -122}]},
          {"type": "way", "id": 2, "nodes": [21, 22], "tags": {"highway": "primary"},
           "geometry": [{"lat": 37, "lon": -122}, null, {"lat": 37.002, "lon": -122}]},
          {"type": "node", "id": 5, "lat": 37.001, "lon": -122, "tags": {"traffic_calming": "hump"}}
        ]}
        """#
        let answer = try OverpassLoader.parse(Data(json.utf8))
        XCTAssertEqual(answer.ways.first?.nodeIDs, [11, 12, 13])
        XCTAssertEqual(answer.ways.last?.nodeIDs, [])          // the ids don't line up with the points
        let path = RoutePath([a, a.moved(by: 400, bearing: 0)])
        let bump = OverpassLoader.features(from: answer, along: path).features
        XCTAssertEqual(bump.map(\.kind), [.trafficCalming])
        XCTAssertEqual(bump.first?.speed ?? 0, 18 * 0.44704, accuracy: 1e-9)
    }

    func testABusyServerGetsOneMoreTry() async throws {
        let path = RoutePath([a, a.moved(by: 1000, bearing: 0)])
        let calls = Counter()
        let loader = OverpassLoader(userAgent: "test", cacheDirectory: nil) { request in
            let n = await calls.increment()
            XCTAssertEqual(request.url?.host, "overpass-api.de")
            let status = n == 1 ? 504 : 200
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Retry-After": "1"])!
            return (status == 200 ? Data(#"{"elements": []}"#.utf8) : Data(), response)
        }
        let features = try await loader.features(along: path, roads: false)
        XCTAssertTrue(features.complete)
        let total = await calls.value
        XCTAssertEqual(total, 2)
    }

    func testAServerOutOfTurnsIsLeftAlone() async throws {
        let path = RoutePath([a, a.moved(by: 1000, bearing: 0)])
        let calls = Counter()
        let busy = Counter()
        let loader = OverpassLoader(userAgent: "test", cacheDirectory: nil) { request in
            _ = await calls.increment()
            let main = request.url?.host == "overpass-api.de"
            if main { _ = await busy.increment() }
            let status = main ? 429 : 200
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (status == 200 ? Data(#"{"elements": []}"#.utf8) : Data(), response)
        }
        let features = try await loader.features(along: path, roads: false)
        XCTAssertTrue(features.complete)
        let asked = await busy.value
        XCTAssertEqual(asked, 1)                                // not asked again right away
        let total = await calls.value
        XCTAssertEqual(total, 2)
    }
}
