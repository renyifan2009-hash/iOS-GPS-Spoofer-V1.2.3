import Foundation
import RemoteAPI
import SpooferCore
import XCTest
@testable import SpooferRemote

/// The headless controller, against the pretend pymobiledevice3 (an iPhone on iOS 16, which can be moved
/// with one quick command per step). What the app sends to the phone is read back from the fake's log.
final class SessionRemoteControllerTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    private var logURL: URL!
    private var controller: SessionRemoteController?

    override func setUpWithError() throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["python3", "--version"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try XCTSkipIf((try? probe.run()) == nil || { probe.waitUntilExit(); return probe.terminationStatus != 0 }(),
                      "needs python3 to run the pretend pymobiledevice3")
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("fake-pmd-\(UUID().uuidString).log")
        setenv("FAKE_PMD_LOG", logURL.path, 1)
    }

    override func tearDown() {
        controller?.shutdown()
        controller = nil
        unsetenv("FAKE_PMD_LOG")
        if let logURL { try? FileManager.default.removeItem(at: logURL) }
        super.tearDown()
    }

    private func makeController(roadData: OverpassLoader? = nil) -> SessionRemoteController {
        let pmd = Pymobiledevice3(executableURL: Self.fixtures.appendingPathComponent("fake-pymobiledevice3"))
        let made = SessionRemoteController(pmd: pmd, options: .init(serverName: "Test Mac", roadData: roadData))
        controller = made
        return made
    }

    /// Everything sent to the phone, in order.
    private var commands: [String] {
        ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// The coordinates of each `set`, in order.
    private var placesSet: [(lat: Double, lon: Double)] {
        commands.compactMap { line in
            guard line.contains("simulate-location set"), let tail = line.components(separatedBy: " -- ").last else { return nil }
            let parts = tail.split(separator: " ").compactMap { Double($0) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    private func waitUntil(timeout: TimeInterval = 15, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func startAtApplePark(_ controller: SessionRemoteController) async throws {
        _ = try await controller.start(LocationRequest(latitude: 37.3349, longitude: -122.0090))
        let active = await waitUntil { await controller.status().phase == .active }
        XCTAssertTrue(active, "the session should come up against the pretend iPhone")
    }

    func testSteeringNeedsALocationHeldFirst() async throws {
        let controller = makeController()
        do {
            _ = try await controller.joystick(JoystickRequest(heading: 90, speed: 5))
            XCTFail("steering with nothing held should be refused")
        } catch let error as RemoteControlError {
            XCTAssertEqual(error.status, 409)
        }
        XCTAssertTrue(placesSet.isEmpty)
    }

    func testSteeringMovesTheLocationAndStopsWhenTheIPhoneGoesQuiet() async throws {
        let controller = makeController()
        try await startAtApplePark(controller)
        let before = placesSet.count

        // Steer east at 10 m/s for about 2.5 seconds, resending every 0.4 s like the iPhone does.
        for _ in 0..<6 {
            let status = try await controller.joystick(JoystickRequest(heading: 90, speed: 10))
            XCTAssertEqual(status.activity, "joystick")
            try await Task.sleep(for: .milliseconds(400))
        }
        let moved = Array(placesSet.dropFirst(before))
        XCTAssertGreaterThanOrEqual(moved.count, 3, "it should keep sending new places while steered")
        let first = try XCTUnwrap(moved.first), last = try XCTUnwrap(moved.last)
        XCTAssertGreaterThan(last.lon, first.lon, "east means the longitude grows")
        XCTAssertEqual(last.lat, first.lat, accuracy: 1e-6, "and the latitude stays")
        XCTAssertGreaterThan(last.lon - first.lon, 0.00008, "about 20 m east is about 0.00022 degrees here")

        // Now the iPhone says nothing. After the timeout the Mac stops moving by itself.
        try await Task.sleep(for: .seconds(RemoteAPI.joystickTimeout + 1.2))
        let settled = placesSet.count
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertEqual(placesSet.count, settled, "no more moves once nobody is steering")
        let status = await controller.status()
        XCTAssertNotEqual(status.activity, "joystick")
        XCTAssertTrue(status.spoofing, "it holds the last place; only Stop gives the real location back")

        _ = await controller.stop()
        let restored = await waitUntil { self.commands.contains { $0.contains("simulate-location clear") } }
        XCTAssertTrue(restored, "Stop must put the real location back")
    }

    func testAStopWhileSteeringEndsTheSteering() async throws {
        let controller = makeController()
        try await startAtApplePark(controller)
        _ = try await controller.joystick(JoystickRequest(heading: 0, speed: 20))
        try await Task.sleep(for: .milliseconds(600))
        _ = await controller.stop()
        let restored = await waitUntil { self.commands.contains { $0.contains("simulate-location clear") } }
        XCTAssertTrue(restored)
        let settled = placesSet.count
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertEqual(placesSet.count, settled, "nothing is sent after Stop")
    }

    func testPausingFreezesTheRouteAndResumingCarriesOn() async throws {
        let controller = makeController()
        let request = RouteRequest(waypoints: [.init(latitude: 37.3349, longitude: -122.0090),
                                               .init(latitude: 37.3349, longitude: -122.0050)],
                                   travelMode: "walking", speed: 5, realistic: false)
        _ = try await controller.driveRoute(request)
        let active = await waitUntil { await controller.status().phase == .active }
        XCTAssertTrue(active)
        try await Task.sleep(for: .seconds(1.6))

        var status = await controller.status()
        XCTAssertEqual(status.activity, "route")
        XCTAssertEqual(status.routePaused, false)
        let running = try XCTUnwrap(status.routeProgress)
        XCTAssertGreaterThan(running, 0)

        status = try await controller.setPaused(PauseRequest(paused: true))
        XCTAssertEqual(status.routePaused, true)
        let atPause = try XCTUnwrap(status.routeProgress)
        try await Task.sleep(for: .seconds(1.6))
        status = await controller.status()
        let stillPaused = try XCTUnwrap(status.routeProgress)
        XCTAssertEqual(stillPaused, atPause, accuracy: 1e-9, "paused means the progress does not move")

        status = try await controller.setPaused(PauseRequest(paused: false))
        XCTAssertEqual(status.routePaused, false)
        try await Task.sleep(for: .seconds(1.6))
        status = await controller.status()
        let resumed = try XCTUnwrap(status.routeProgress)
        XCTAssertGreaterThan(resumed, stillPaused, "and it carries on from where it was")
        XCTAssertLessThan(resumed, stillPaused + 0.2, "without jumping ahead by the time it was paused")
    }

    /// A route on roads looks up their lights and limits first ("planning"), holding the start. When the
    /// public map servers are busy (502, as they were on 2026-11-12) it sets off anyway, without them.
    func testARouteOnRoadsPlansThenSetsOffEvenWhenTheMapServersAreBusy() async throws {
        let asked = Counter()
        let busy = OverpassLoader(userAgent: "test", cacheDirectory: nil, timeBudget: 3) { request in
            asked.add()
            try await Task.sleep(for: .milliseconds(300))
            return (Data("busy".utf8), HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!)
        }
        let controller = makeController(roadData: busy)
        let leg = RoadLeg(points: [(37.3349, -122.0090), (37.3370, -122.0090), (37.3370, -122.0050), (37.3349, -122.0050)],
                          meters: 820, expectedSeconds: 60)
        let request = RouteRequest(waypoints: [.init(latitude: 37.3349, longitude: -122.0090),
                                               .init(latitude: 37.3349, longitude: -122.0050)],
                                   followRoads: true, travelMode: "driving", speed: 10, realistic: true,
                                   legs: [leg], followSpeedLimits: true)
        let first = try await controller.driveRoute(request)
        XCTAssertEqual(first.activity, "planning")
        let driving = await waitUntil(timeout: 20) { await controller.status().activity == "route" }
        XCTAssertTrue(driving, "it sets off once the servers have had their chance")
        XCTAssertGreaterThan(asked.value, 0, "it did ask")
    }

    /// An older iPhone's route (no roads) sets off at once, as before.
    func testARouteWithoutRoadsDoesNotWaitForMapData() async throws {
        let controller = makeController(roadData: OverpassLoader(userAgent: "test", cacheDirectory: nil, timeBudget: 3) { _ in
            XCTFail("a route without roads has nothing to look up")
            throw URLError(.notConnectedToInternet)
        })
        let request = RouteRequest(waypoints: [.init(latitude: 37.3349, longitude: -122.0090),
                                               .init(latitude: 37.3349, longitude: -122.0050)],
                                   followRoads: true, travelMode: "driving", speed: 10, realistic: true)
        let status = try await controller.driveRoute(request)
        XCTAssertNotEqual(status.activity, "planning")
    }

    func testPausingWithoutARouteIsRefused() async throws {
        let controller = makeController()
        try await startAtApplePark(controller)
        do {
            _ = try await controller.setPaused(PauseRequest(paused: true))
            XCTFail("there is no route to pause")
        } catch let error as RemoteControlError {
            XCTAssertEqual(error.status, 409)
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
