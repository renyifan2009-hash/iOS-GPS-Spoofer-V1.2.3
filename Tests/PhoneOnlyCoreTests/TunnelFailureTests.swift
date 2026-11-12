import Foundation
import Network
import XCTest
@testable import PhoneOnlyCore

/// The messages are in the form idevice 0.1.68 gives them: the debug text of
/// its Rust errors (`ffi_err!` formats them with `{:?}`).
final class TunnelFailureTests: XCTestCase {
    private let remotePairing = TunnelRoute.remotePairing(port: 49152)

    private func tunnel(_ route: TunnelRoute, code: Int32, sub: Int32 = 0, _ message: String) -> TunnelFailure {
        TunnelFailure(step: .tunnel, route: route, code: code, subCode: sub, message: message)
    }

    func testLocalDevVPNOff() {
        // tunnel_create_rppairing reports its first connect this way, refused or not.
        let refused = tunnel(remotePairing, code: 16, #"InternalError("connect: device socket io failed")"#)
        XCTAssertTrue(refused.isUnreachable)
        XCTAssertFalse(refused.isPairingProblem)
        XCTAssertEqual(refused.explanation, TunnelFailure.unreachableExplanation)

        let timedOut = tunnel(remotePairing, code: 16, #"InternalError("connect: Operation Timeout")"#)
        XCTAssertTrue(timedOut.isUnreachable)

        let lockdown = tunnel(.lockdown, code: 1,
                              #"Socket(Os { code: 61, kind: ConnectionRefused, message: "Connection refused" })"#)
        XCTAssertTrue(lockdown.isUnreachable)
        XCTAssertEqual(lockdown.explanation, TunnelFailure.unreachableExplanation)
    }

    func testOnCellularDataAloneTheMessageSaysSoInsteadOfBlamingLocalDevVPN() {
        let refused = tunnel(remotePairing, code: 16, #"InternalError("connect: device socket io failed")"#)
        XCTAssertEqual(refused.explanation(onCellularOnly: true), TunnelFailure.cellularExplanation)
        XCTAssertEqual(refused.explanation(onCellularOnly: false), TunnelFailure.unreachableExplanation)
        // Only not reaching the iPhone is cellular's doing: a pairing the iPhone turns down is still that.
        let denied = tunnel(remotePairing, code: 31, "UserDeniedPairing")
        XCTAssertFalse(denied.isUnreachable)
        XCTAssertEqual(denied.explanation(onCellularOnly: true), denied.explanation)
    }

    func testCellularOnlyMeansNoJoinedWiFiOrWire() {
        XCTAssertTrue(PhoneNetwork.isCellularOnly([.cellular]))
        XCTAssertTrue(PhoneNetwork.isCellularOnly([.other, .cellular]), "LocalDevVPN's own tunnel doesn't count")
        XCTAssertFalse(PhoneNetwork.isCellularOnly([.wifi, .cellular]))
        XCTAssertFalse(PhoneNetwork.isCellularOnly([.wiredEthernet, .cellular]))
        XCTAssertFalse(PhoneNetwork.isCellularOnly([.wifi]))
        XCTAssertFalse(PhoneNetwork.isCellularOnly([]), "Airplane Mode")
    }

    func testTheIPhoneTurnsTheIdentityDown() {
        let rejected = tunnel(remotePairing, code: 103, sub: 3,
                              #"RemotePairing(PairingRejected("The user declined the pairing request"))"#)
        XCTAssertTrue(rejected.isPairingProblem)
        XCTAssertFalse(rejected.pointsAtAnotherPort)
        XCTAssertTrue(rejected.explanation.hasPrefix("The iPhone didn't accept the pairing file."))

        let srp = tunnel(remotePairing, code: 103, sub: 6, "RemotePairing(SrpAuthFailed)")
        XCTAssertTrue(srp.isPairingProblem)

        let lockdown = tunnel(.lockdown, code: 18, "InvalidHostID")
        XCTAssertTrue(lockdown.isPairingProblem)

        let tls = tunnel(.lockdown, code: 3, #"Rustls(InvalidCertificate(BadSignature))"#)
        XCTAssertTrue(tls.isPairingProblem)

        // Pairing again, and the iPhone answers with something other than its keys.
        let consent = tunnel(remotePairing, code: 13,
                             #"UnexpectedResponse("pairing data contained error response during pair consent")"#)
        XCTAssertTrue(consent.isPairingProblem)
        XCTAssertFalse(consent.pointsAtAnotherPort)
    }

    func testTheRemotePairingTunnelPortIsNotAPairingProblem() {
        // "TLS" is in the message, but this is a failed connection, not a refused identity.
        let failure = tunnel(remotePairing, code: 16, #"InternalError("TLS tunnel: Operation Timeout")"#)
        XCTAssertFalse(failure.isPairingProblem)
        XCTAssertTrue(failure.explanation.hasPrefix("Opening the developer tunnel didn't work:"))
    }

    func testTheIPhoneDropsTheConnection() {
        // StikDebug issue 474, on iOS 26.7.
        let reset = tunnel(remotePairing, code: 1,
                           #"Socket(Os { code: 54, kind: ConnectionReset, message: "Connection reset by peer" })"#)
        XCTAssertTrue(reset.wasCutOff)
        XCTAssertFalse(reset.isUnreachable)
        XCTAssertFalse(reset.isPairingProblem)
        XCTAssertTrue(reset.pointsAtAnotherPort)
        XCTAssertTrue(reset.explanation.hasPrefix("This iPhone closed the connection"))
    }

    func testOnlyRemotePairingTunnelFailuresPointAtAnotherPort() {
        XCTAssertTrue(tunnel(remotePairing, code: 16, #"InternalError("connect: device socket io failed")"#)
            .pointsAtAnotherPort)
        // Something else answered on the port: not remotepairingd's handshake.
        XCTAssertTrue(tunnel(remotePairing, code: 13,
                             #"UnexpectedResponse("missing handshake response in attemptPairVerify")"#)
            .pointsAtAnotherPort)
        XCTAssertFalse(tunnel(.lockdown, code: 1, "Socket(ConnectionRefused)").pointsAtAnotherPort)
        XCTAssertFalse(TunnelFailure(step: .instruments, route: remotePairing, code: 21, message: "ServiceNotFound")
            .pointsAtAnotherPort)
    }

    func testDeveloperSupportNotLoaded() {
        let instruments = TunnelFailure(step: .instruments, route: remotePairing, code: 21, message: "ServiceNotFound")
        XCTAssertTrue(instruments.explanation.hasPrefix("This iPhone's location service didn't open."))
        let image = TunnelFailure(step: .services, route: .lockdown, code: 29, message: "ImageNotMounted")
        XCTAssertTrue(image.explanation.hasPrefix("Apple's developer support isn't loaded."))
    }

    func testDeveloperModeOff() {
        let failure = TunnelFailure(step: .instruments, route: remotePairing, code: 24,
                                    message: "DeveloperModeNotEnabled")
        XCTAssertTrue(failure.explanation.hasPrefix("Developer Mode is off."))
    }

    func testAnUnreadablePairingFile() {
        let failure = TunnelFailure(step: .pairingFile, route: remotePairing, code: 5,
                                    message: #"Plist(Error { kind: Serde("missing field `public_key`") })"#)
        XCTAssertTrue(failure.explanation.hasPrefix("This pairing file can't be read."))
    }

    func testAnythingElseSaysWhatIdeviceSaid() {
        let failure = TunnelFailure(step: .setLocation, route: remotePairing, code: 105, message: "Dvt(Disconnected)")
        XCTAssertEqual(failure.explanation, "Setting the location didn't work: Dvt(Disconnected)")
        XCTAssertEqual(failure.errorDescription, "Setting the location failed: Dvt(Disconnected)")
    }

    func testTheSmallPrint() {
        let failure = tunnel(remotePairing, code: 103, sub: 5, "RemotePairing(PairVerifyFailed)")
        XCTAssertEqual(failure.detail,
                       "Opening the developer tunnel · Remote Pairing, port 49152 · code 103.5: RemotePairing(PairVerifyFailed)")
        let ours = TunnelFailure(step: .reach, message: "10.7.0 isn't an IPv4 address")
        XCTAssertEqual(ours.detail, "Reaching the iPhone: 10.7.0 isn't an IPv4 address")
    }

    func testTheMostTellingFailureOfSeveralRoutes() {
        let refused = tunnel(.remotePairing(port: 49160), code: 16,
                             #"InternalError("connect: device socket io failed")"#)
        let reset = tunnel(remotePairing, code: 1, "Socket(ConnectionReset)")
        let rejected = tunnel(remotePairing, code: 103, sub: 3, "RemotePairing(PairingRejected(\"\"))")
        let lockdownRefused = tunnel(.lockdown, code: 1, "Socket(ConnectionRefused)")

        func shown(_ failures: [TunnelFailure]) -> TunnelFailure? {
            var failure = TunnelFailure.mostTelling(failures)
            failure?.others = []
            return failure
        }
        XCTAssertNil(TunnelFailure.mostTelling([]))
        XCTAssertEqual(shown([refused, reset]), reset)
        XCTAssertEqual(shown([refused, rejected, lockdownRefused]), rejected)
        XCTAssertEqual(shown([refused, lockdownRefused]), refused, "the first of equals")

        // A later step beats an earlier one, whatever the kind.
        let services = TunnelFailure(step: .services, route: .lockdown, code: 1, message: "Socket(ConnectionReset)")
        XCTAssertEqual(shown([rejected, services]), services)
    }

    func testTheOtherRoutesFailuresComeAlong() {
        let reset = tunnel(remotePairing, code: 1, "Socket(ConnectionReset)")
        let services = TunnelFailure(step: .services, route: .lockdown, code: 1, message: "Socket(ConnectionReset)")
        let failure = TunnelFailure.mostTelling([reset, services])

        // Lockdown got further, so it's the one shown...
        XCTAssertEqual(failure?.route, .lockdown)
        XCTAssertEqual(failure?.others, [reset])
        // ...but the Remote Pairing failure still says to look for another port,
        XCTAssertFalse(services.pointsAtAnotherPort)
        XCTAssertEqual(failure?.pointsAtAnotherPort, true)
        // and a bug report gets both.
        XCTAssertEqual(failure?.detail, """
            Connecting to the developer services · lockdown · code 1: Socket(ConnectionReset)
            Opening the developer tunnel · Remote Pairing, port 49152 · code 1: Socket(ConnectionReset)
            """)
    }
}
