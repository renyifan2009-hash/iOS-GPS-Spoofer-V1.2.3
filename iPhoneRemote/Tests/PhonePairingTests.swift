import Darwin
import Foundation
import XCTest
@testable import AnyWhere

/// Pairing without a computer: the pieces that don't need an iPhone's Settings on the other end.
final class PhonePairingTests: XCTestCase {
    func testTXTRecordsBecomeBonjourBytes() throws {
        let plist: [String: Any] = ["name": "AnyWhere", "ver": 26, "authTag": Data([1, 2, 3])]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let records = PairableHostIdentity.txtRecord(fromPlist: data)
        XCTAssertEqual(records["name"], Data("AnyWhere".utf8))
        XCTAssertEqual(records["ver"], Data("26".utf8))
        XCTAssertEqual(records["authTag"], Data([1, 2, 3]))
        XCTAssertTrue(PairableHostIdentity.txtRecord(fromPlist: Data("not a plist".utf8)).isEmpty)
    }

    /// The real idevice call: a host identity, and what Settings needs to find it.
    func testIdeviceMakesAPairableHostIdentity() throws {
        let host = try PairableHostIdentity(name: "AnyWhere")
        XCTAssertFalse(host.serviceID.isEmpty)
        XCTAssertEqual(host.txtRecord["name"], Data("AnyWhere".utf8))
        XCTAssertEqual(host.txtRecord["identifier"], Data(host.serviceID.utf8))
        XCTAssertNotNil(host.txtRecord["authTag"])
    }

    func testAConnectionThatSendsJunkFailsWithAPlainMessage() throws {
        let host = try PairableHostIdentity(name: "AnyWhere")
        let socket = PairingSocket()
        let port = try socket.listen()
        XCTAssertGreaterThan(port, 0)
        // Something that isn't the iPhone's Settings connects and hangs up.
        let client = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let connection = try socket.acceptOne()
        _ = "hello".withCString { Darwin.write(client, $0, 5) }
        Darwin.close(client)
        XCTAssertThrowsError(try host.pair(onConnection: connection, context: PinContext { _ in })) { error in
            let message = PhonePairing.explain(error)
            XCTAssertTrue(message.hasPrefix("The connection closed before pairing finished"), message)
        }
        socket.close()
    }

    func testClosingStopsAWaitingAccept() throws {
        let socket = PairingSocket()
        _ = try socket.listen()
        let ended = expectation(description: "accept ends")
        DispatchQueue.global().async {
            let accepted = try? socket.acceptOne()
            XCTAssertNil(accepted, "accept ends with an error once the socket is closed")
            ended.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        socket.close()
        wait(for: [ended], timeout: 5)
        XCTAssertEqual(PhonePairing.explain(PairableHostIdentity.Failure(message: "Pairing was cancelled.")),
                       "Pairing was cancelled.")
    }
}
