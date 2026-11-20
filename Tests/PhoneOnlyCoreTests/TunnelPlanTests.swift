import Foundation
import XCTest
@testable import PhoneOnlyCore

final class TunnelPlanTests: XCTestCase {
    func testBeforeCoreDeviceProxyOnlyRemotePairingIsAttempted() throws {
        let record = try Sample.record(Sample.both)
        XCTAssertEqual(TunnelPlan.readiness(for: record, ports: DeveloperPorts(remotePairing: [49152], lockdown: true),
                                          allowLockdown: false), .ready([.remotePairing(port: 49152)]))
        XCTAssertEqual(TunnelPlan.routes(for: record, allowLockdown: false), [.remotePairing(port: 49152)])
    }

    func testPre174LockdownOnlyFileRequestsRemotePairingIdentity() throws {
        let record = try Sample.record(Sample.lockdown)
        XCTAssertEqual(TunnelPlan.readiness(for: record, ports: DeveloperPorts(lockdown: true), allowLockdown: false),
                       .fileLacksRemotePairing)
    }
    func testCandidatesPutTheDiscoveredPortFirst() {
        XCTAssertEqual(TunnelPlan.remotePairingCandidates(discovered: nil), [49152])
        XCTAssertEqual(TunnelPlan.remotePairingCandidates(discovered: 49152), [49152])
        XCTAssertEqual(TunnelPlan.remotePairingCandidates(discovered: 49155), [49155, 49152])
        XCTAssertEqual(TunnelPlan.remotePairingCandidates(discovered: 0), [49152])
    }

    func testNothingAnswers() throws {
        let record = try Sample.record(Sample.both)
        XCTAssertEqual(TunnelPlan.readiness(for: record, ports: DeveloperPorts()), .nothingAnswers)
    }

    func testOlderIOSWithTheFullFileTriesRemotePairingThenLockdown() throws {
        let record = try Sample.record(Sample.both)
        let ports = DeveloperPorts(remotePairing: [49152], lockdown: true)
        XCTAssertEqual(TunnelPlan.readiness(for: record, ports: ports),
                       .ready([.remotePairing(port: 49152), .lockdown]))
    }

    func testNewerIOSWithTheFullFileUsesRemotePairing() throws {
        // Lockdown no longer answers through LocalDevVPN.
        let record = try Sample.record(Sample.both)
        let ports = DeveloperPorts(remotePairing: [49152], lockdown: false)
        XCTAssertEqual(TunnelPlan.readiness(for: record, ports: ports), .ready([.remotePairing(port: 49152)]))
    }

    func testNewerIOSWithAnOldFileNeedsANewFile() throws {
        let record = try Sample.record(Sample.lockdown)
        let ports = DeveloperPorts(remotePairing: [49152], lockdown: false)
        XCTAssertEqual(TunnelPlan.readiness(for: record, ports: ports), .fileLacksRemotePairing)
    }

    func testOlderIOSWithAnOldFileUsesLockdown() throws {
        let record = try Sample.record(Sample.lockdown)
        let ports = DeveloperPorts(remotePairing: [49152], lockdown: true)
        XCTAssertEqual(TunnelPlan.readiness(for: record, ports: ports), .ready([.lockdown]))
    }

    func testAMovedRemotePairingPortIsTriedFirst() throws {
        let record = try Sample.record(Sample.both)
        let ports = DeveloperPorts(remotePairing: [49160, 49152], lockdown: false)
        XCTAssertEqual(TunnelPlan.readiness(for: record, ports: ports),
                       .ready([.remotePairing(port: 49160), .remotePairing(port: 49152)]))
    }

    func testARemotePairingOnlyFileNeedsRemotePairingToAnswer() throws {
        let record = try Sample.record(Sample.remotePairing())
        XCTAssertEqual(TunnelPlan.readiness(for: record, ports: DeveloperPorts(lockdown: true)),
                       .remotePairingDoesNotAnswer)
    }

    func testRoutesWithoutAPortCheck() throws {
        XCTAssertEqual(TunnelPlan.routes(for: try Sample.record(Sample.both), discoveredPort: 49170),
                       [.remotePairing(port: 49170), .remotePairing(port: 49152), .lockdown])
        XCTAssertEqual(TunnelPlan.routes(for: try Sample.record(Sample.lockdown)), [.lockdown])
        XCTAssertEqual(TunnelPlan.routes(for: try Sample.record(Sample.remotePairing())),
                       [.remotePairing(port: 49152)])
    }

    func testLockdownOnlyBetweenIOS17Point4And26Point3() {
        func v(_ major: Int, _ minor: Int) -> OperatingSystemVersion {
            OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
        }
        XCTAssertFalse(TunnelPlan.allowsLockdown(onIOS: v(17, 3)))
        XCTAssertTrue(TunnelPlan.allowsLockdown(onIOS: v(17, 4)))
        XCTAssertTrue(TunnelPlan.allowsLockdown(onIOS: v(18, 6)))
        XCTAssertTrue(TunnelPlan.allowsLockdown(onIOS: v(26, 3)))
        // iOS 26.4 closes lockdown through LocalDevVPN at once.
        XCTAssertFalse(TunnelPlan.allowsLockdown(onIOS: v(26, 4)))
        XCTAssertFalse(TunnelPlan.allowsLockdown(onIOS: v(26, 6)))
        XCTAssertFalse(TunnelPlan.allowsLockdown(onIOS: v(27, 2)))
    }
}
