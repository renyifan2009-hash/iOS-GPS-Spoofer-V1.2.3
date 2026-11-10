import CoreLocation
import Foundation
import PhoneOnlyCore
import RemoteAPI
import XCTest
@testable import AnyWhere

private final class FakeDevice: OnDeviceOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [(Double, Double)] = []
    var confirmsClear = true
    var failSet = false
    var transportFailures = 0
    var attempts = 0
    var clearDelay: Duration?
    /// How many times the real location was put back.
    var clears = 0
    var route: TunnelRoute? { .lockdown }
    var count: Int { lock.withLock { writes.count } }
    func onAbandonedCallEnded(_ handler: @escaping @Sendable () -> Void) {}
    func takeRenewedPairing() -> PairingRecord? { nil }
    func set(latitude: Double, longitude: Double, pairing: PairingRecord, routes: [TunnelRoute], developerImage: URL?) async throws {
        attempts += 1
        if transportFailures > 0 {
            transportFailures -= 1
            throw TunnelFailure(step: .reach, code: 1, message: "Connection refused")
        }
        if failSet { throw TunnelFailure(step: .setLocation, message: "Fake disconnected device") }
        lock.withLock { writes.append((latitude, longitude)) }
    }
    func clear() async -> Bool {
        clears += 1
        if let clearDelay { try? await Task.sleep(for: clearDelay) }
        return confirmsClear
    }
}

@MainActor
private final class FakeBackground: BackgroundHolding {
    func start() {}
    func stop() {}
}

private actor ProbeGate {
    private var continuation: CheckedContinuation<DeveloperPorts, Never>?
    private var started = false
    func wait() async -> DeveloperPorts {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func hasStarted() -> Bool { started }
    func finish() { continuation?.resume(returning: DeveloperPorts(remotePairing: [49152], lockdown: true)); continuation = nil }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: Double) { lock.withLock { date.addTimeInterval(seconds) } }
}

@MainActor
final class StandaloneControlTests: XCTestCase {
    private func pairing() throws -> PairingFile {
        var dictionary: [String: Any] = [:]
        for key in ["DeviceCertificate", "HostCertificate", "HostPrivateKey", "RootCertificate", "RootPrivateKey"] {
            dictionary[key] = Data("fake-test-key".utf8)
        }
        for key in ["HostID", "SystemBUID", "WiFiMACAddress"] { dictionary[key] = "test" }
        return try PairingFile(data: PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0))
    }

    private func phone(_ engine: FakeDevice, probe: (@Sendable () async -> DeveloperPorts)? = nil) throws -> OnDeviceController {
        OnDeviceController(engine: engine, pairing: try pairing(), keepAlive: FakeBackground(),
                           developerPortProbe: probe ?? { DeveloperPorts(lockdown: true) })
    }

    func testTransientTransportFailureRecovers() async throws {
        let engine = FakeDevice()
        engine.transportFailures = 1
        let phone = OnDeviceController(engine: engine, pairing: try pairing(), keepAlive: FakeBackground(),
                                       developerPortProbe: { DeveloperPorts(lockdown: true) },
                                       recoveryDelay: .milliseconds(10))
        let started = await phone.set(.init(latitude: 0, longitude: 0), name: "Test")
        XCTAssertTrue(started)
        XCTAssertEqual(engine.attempts, 2)
        XCTAssertNil(phone.lastError)
        await phone.stop()
    }

    func testPersistentTransportFailureHasBoundedRetries() async throws {
        let engine = FakeDevice()
        engine.transportFailures = 10
        let phone = OnDeviceController(engine: engine, pairing: try pairing(), keepAlive: FakeBackground(),
                                       developerPortProbe: { DeveloperPorts(lockdown: true) },
                                       recoveryDelay: .milliseconds(10))
        let started = await phone.set(.init(latitude: 0, longitude: 0), name: "Test")
        XCTAssertFalse(started)
        XCTAssertEqual(engine.attempts, 3)
        XCTAssertFalse(phone.isSpoofing)
    }

    func testStopDuringRecoveryPreventsRestart() async throws {
        let engine = FakeDevice()
        engine.transportFailures = 1
        let phone = OnDeviceController(engine: engine, pairing: try pairing(), keepAlive: FakeBackground(),
                                       developerPortProbe: { DeveloperPorts(lockdown: true) },
                                       recoveryDelay: .milliseconds(200))
        let start = Task { await phone.set(.init(latitude: 0, longitude: 0), name: "Test") }
        while phone.lastError == nil { await Task.yield() }
        await phone.stop()
        let started = await start.value
        XCTAssertFalse(started)
        XCTAssertEqual(engine.count, 0)
        XCTAssertEqual(engine.attempts, 1)
    }

    func testStopDuringVPNProbePreventsAnyLocationCommand() async throws {
        let engine = FakeDevice(), gate = ProbeGate()
        let phone = try phone(engine, probe: { await gate.wait() })
        let start = Task { await phone.set(.init(latitude: 0, longitude: 0), name: "Test") }
        while !(await gate.hasStarted()) { await Task.yield() }
        let stopped = await phone.stop()
        XCTAssertTrue(stopped)
        await gate.finish()
        let started = await start.value
        XCTAssertFalse(started)
        XCTAssertEqual(engine.count, 0)
        XCTAssertFalse(phone.isSpoofing)
    }

    func testInvalidCoordinateNeverReachesDevice() async throws {
        let engine = FakeDevice(), phone = try phone(engine)
        let started = await phone.set(.init(latitude: .nan, longitude: 0), name: nil)
        XCTAssertFalse(started)
        XCTAssertEqual(engine.count, 0)
    }

    func testFailedStopDoesNotClaimConfirmation() async throws {
        let engine = FakeDevice(), phone = try phone(engine)
        let started = await phone.set(.init(latitude: 0, longitude: 0), name: "Test")
        XCTAssertTrue(started)
        engine.confirmsClear = false
        let stopped = await phone.stop()
        XCTAssertFalse(stopped)
        XCTAssertTrue(phone.lastError?.contains("didn't confirm Stop") == true)
    }

    func testJoystickWritesLocallyAndStopsOnRelease() async throws {
        let engine = FakeDevice(), phone = try phone(engine)
        let controls = PhoneMotionController(phone: phone)
        let started = await controls.start(at: .init(latitude: 0, longitude: 0), name: "Start", joystick: true)
        XCTAssertTrue(started)
        _ = await controls.steer(heading: 0, speed: 10)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThan(engine.count, 1)
        controls.releaseJoystick()
        let count = engine.count
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(engine.count, count)
        _ = await controls.stop()
    }

    /// "Move Here" while holding a place goes straight there: the real location must never show in between.
    func testMovingWhileHoldingNeverPutsTheRealLocationBack() async throws {
        let engine = FakeDevice(), phone = try phone(engine)
        let controls = PhoneMotionController(phone: phone)
        let first = await controls.start(at: .init(latitude: 1, longitude: 1), name: "A")
        XCTAssertTrue(first)
        let moved = await controls.start(at: .init(latitude: 2, longitude: 2), name: "B")
        XCTAssertTrue(moved)
        XCTAssertEqual(engine.clears, 0, "no clear between the two places")
        XCTAssertEqual(phone.current?.latitude ?? 0, 2, accuracy: 1e-9)
        _ = await controls.stop()
        XCTAssertEqual(engine.clears, 1, "Stop still puts the real location back")
    }

    /// Driving a route from a held place plans first and moves to the start; no clear on the way.
    func testDrivingARouteFromAHoldNeverPutsTheRealLocationBack() async throws {
        let engine = FakeDevice(), phone = try phone(engine)
        let controls = PhoneMotionController(phone: phone)
        _ = await controls.start(at: .init(latitude: 0.5, longitude: 0.5), name: "Home")
        let request = RouteRequest(waypoints: [.init(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 0.001)],
                                   followRoads: false, speed: 10, realistic: false)
        let started = await controls.driveRoute(request)
        XCTAssertTrue(started)
        XCTAssertEqual(engine.clears, 0)
        _ = await controls.stop()
    }

    /// "Leave in …" on this iPhone: the route stands at the start and says so.
    func testAWaitBeforeLeavingIsReportedAsStopZero() async throws {
        let engine = FakeDevice(), phone = try phone(engine)
        let controls = PhoneMotionController(phone: phone)
        let request = RouteRequest(waypoints: [.init(latitude: 0, longitude: 0, wait: 60), .init(latitude: 0, longitude: 0.001)],
                                   followRoads: false, speed: 10, realistic: false)
        let started = await controls.driveRoute(request)
        XCTAssertTrue(started)
        try await Task.sleep(for: .milliseconds(600))
        let wait = controls.status?.routeWait
        XCTAssertEqual(wait?.reason, "stop")
        XCTAssertEqual(wait?.stop, 0)
        XCTAssertGreaterThan(wait?.remaining ?? 0, 55)
        XCTAssertEqual(phone.current?.longitude ?? -1, 0, accuracy: 1e-9, "still at the start")
        _ = await controls.stop()
    }

    func testRoutePauseAndStopPreventFurtherWrites() async throws {
        let engine = FakeDevice(), phone = try phone(engine)
        let controls = PhoneMotionController(phone: phone)
        let request = RouteRequest(waypoints: [.init(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 0.001)],
                                   followRoads: false, speed: 10, realistic: false)
        let started = await controls.driveRoute(request)
        XCTAssertTrue(started)
        try await Task.sleep(for: .milliseconds(350))
        let didPause = await controls.setPaused(true)
        XCTAssertTrue(didPause)
        let progress = controls.progress, count = engine.count
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(controls.progress, progress)
        XCTAssertEqual(engine.count, count)
        _ = await controls.setPaused(false)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThan(engine.count, count)
        _ = await controls.stop()
        let stoppedCount = engine.count
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(engine.count, stoppedCount)
    }

    func testHeldLocationReconnectsInsteadOfQuittingWhenTheLinkDrops() async throws {
        let engine = FakeDevice()
        let phone = OnDeviceController(engine: engine, pairing: try pairing(), keepAlive: FakeBackground(),
                                       developerPortProbe: { DeveloperPorts(lockdown: true) },
                                       heartbeatInterval: .milliseconds(30), recoveryDelay: .milliseconds(10))
        var lost = 0
        phone.onConnectionLost = { lost += 1 }
        let started = await phone.set(.init(latitude: 0, longitude: 0), name: "Hold")
        XCTAssertTrue(started)
        engine.failSet = true
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(phone.isSpoofing, "the session is kept while the link is down")
        XCTAssertTrue(phone.isReconnecting)
        XCTAssertEqual(lost, 1, "told once per outage")
        engine.failSet = false
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(phone.isSpoofing)
        XCTAssertFalse(phone.isReconnecting)
        XCTAssertNil(phone.lastError)
        await phone.stop()
    }

    func testReconnectingGivesUpAfterItsWindow() async throws {
        let engine = FakeDevice()
        let phone = OnDeviceController(engine: engine, pairing: try pairing(), keepAlive: FakeBackground(),
                                       developerPortProbe: { DeveloperPorts(lockdown: true) },
                                       heartbeatInterval: .milliseconds(30), recoveryDelay: .milliseconds(10),
                                       reconnectWindow: .milliseconds(120))
        let started = await phone.set(.init(latitude: 0, longitude: 0), name: "Hold")
        XCTAssertTrue(started)
        engine.failSet = true
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(phone.isSpoofing)
        XCTAssertFalse(phone.isReconnecting)
        XCTAssertTrue(phone.lastErrorDetail?.contains("Fake disconnected device") == true)
    }

    func testStopWhileReconnectingEndsIt() async throws {
        let engine = FakeDevice()
        let phone = OnDeviceController(engine: engine, pairing: try pairing(), keepAlive: FakeBackground(),
                                       developerPortProbe: { DeveloperPorts(lockdown: true) },
                                       heartbeatInterval: .milliseconds(30), recoveryDelay: .milliseconds(10))
        _ = await phone.set(.init(latitude: 0, longitude: 0), name: "Hold")
        engine.failSet = true
        while !phone.isReconnecting { try await Task.sleep(for: .milliseconds(10)) }
        await phone.stop()
        XCTAssertFalse(phone.isSpoofing)
        XCTAssertFalse(phone.isReconnecting)
        engine.failSet = false
        let count = engine.count
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(engine.count, count, "nothing is set again after Stop")
    }

    func testPhoneTimerStopsWithoutAnyMacController() async throws {
        let engine = FakeDevice(), phone = try phone(engine), clock = TestClock()
        let controls = PhoneMotionController(phone: phone, now: { clock.now() })
        let started = await controls.start(at: .init(latitude: 0, longitude: 0), name: "Hold")
        XCTAssertTrue(started)
        _ = await controls.setAutoStop(minutes: 1)
        XCTAssertNotNil(controls.deadline)
        clock.advance(61)
        try await Task.sleep(for: .milliseconds(1250))
        XCTAssertFalse(phone.isSpoofing)
        XCTAssertNil(controls.deadline)
    }

    func testInputsDuringSlowStopCannotRestartMotion() async throws {
        let engine = FakeDevice(), phone = try phone(engine)
        let controls = PhoneMotionController(phone: phone)
        let started = await controls.start(at: .init(latitude: 0, longitude: 0), name: "Hold", joystick: true)
        XCTAssertTrue(started)
        engine.clearDelay = .milliseconds(300)
        let stopping = Task { await controls.stop() }
        while phone.phase != .stopping { await Task.yield() }
        let count = engine.count
        let moved = await phone.set(.init(latitude: 1, longitude: 1), name: "Must not run")
        XCTAssertFalse(moved)
        let steeringError = await controls.steer(heading: 0, speed: 10)
        XCTAssertNotNil(steeringError)
        let stopped = await stopping.value
        XCTAssertTrue(stopped)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(engine.count, count)
        XCTAssertFalse(phone.isSpoofing)
    }
}
