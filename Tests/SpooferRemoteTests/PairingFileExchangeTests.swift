import CryptoKit
import Foundation
import RemoteAPI
import XCTest
@testable import SpooferRemote

/// Answers a pairing-file question the way it is told to, and remembers the codes it was shown.
private final class PairingFileFake: RemoteController, @unchecked Sendable {
    enum Answer { case allow(Data, String?), deny, fail(String), waitForever }
    private let lock = NSLock()
    private var shown: [String] = []
    private var names: [String] = []
    let answer: Answer

    init(_ answer: Answer) { self.answer = answer }

    var codes: [String] { lock.withLock { shown } }
    var askedNames: [String] { lock.withLock { names } }

    private func makeStatus() -> RemoteStatus { RemoteStatus(connected: true, spoofing: false, phase: .idle, serverName: "Test Mac") }
    func status() async -> RemoteStatus { makeStatus() }
    func setLocation(_ request: LocationRequest) async throws -> RemoteStatus { makeStatus() }
    func start(_ request: LocationRequest?) async throws -> RemoteStatus { makeStatus() }
    func stop() async -> RemoteStatus { makeStatus() }

    func pairingFile(forClientNamed clientName: String, code: String) async throws -> PairingFilePayload {
        lock.withLock { shown.append(code); names.append(clientName) }
        switch answer {
        case .allow(let data, let problem): return PairingFilePayload(data: data, olderIOSOnly: problem)
        case .deny: throw RemoteControlError("The Mac didn't allow it.", status: 403)
        case .fail(let message): throw RemoteControlError(message)
        case .waitForever:
            try await Task.sleep(for: .seconds(600))
            throw CancellationError()
        }
    }
}

/// Does only what every controller must: the pairing file falls back to 501.
private final class PlainController: RemoteController, @unchecked Sendable {
    private func makeStatus() -> RemoteStatus { RemoteStatus(connected: true, spoofing: false, phase: .idle, serverName: "Plain") }
    func status() async -> RemoteStatus { makeStatus() }
    func setLocation(_ request: LocationRequest) async throws -> RemoteStatus { makeStatus() }
    func start(_ request: LocationRequest?) async throws -> RemoteStatus { makeStatus() }
    func stop() async -> RemoteStatus { makeStatus() }
}

/// One iPhone's side of a request: its key and nonce, and the code it would show.
private struct Phone {
    let key = Curve25519.KeyAgreement.PrivateKey()
    let nonce = PairingFileSeal.makeNonce()
    var publicKey: Data { key.publicKey.rawRepresentation }
    var commitment: Data { PairingFileSeal.commitment(publicKey: publicKey, nonce: nonce) }
    var commit: PairingFileRequest { PairingFileRequest(commitment: commitment) }
    var reveal: PairingFileRequest { PairingFileRequest(commitment: commitment, publicKey: publicKey, nonce: nonce) }

    func code(_ answer: PairingFileResponse) -> String? {
        guard let serverKey = answer.serverPublicKey, let serverNonce = answer.serverNonce else { return nil }
        return PairingFileSeal.code(clientPublicKey: publicKey, clientNonce: nonce, serverPublicKey: serverKey,
                                    serverNonce: serverNonce)
    }
}

final class PairingFileExchangeTests: XCTestCase {
    private var fileURL: URL!
    private var pairing: PairingManager!
    private let file = Data("<?xml version=\"1.0\"?><plist><dict><key>HostID</key><string>X</string></dict></plist>".utf8)

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("pairingfile-\(UUID().uuidString).json")
        pairing = PairingManager(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    // MARK: - The seal and the code

    func testOnlyTheKeyThatAskedOpensTheFile() throws {
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let sealed = try PairingFileSeal.seal(file, to: phone.publicKey.rawRepresentation, with: mac)
        XCTAssertNil(sealed.range(of: Data("HostID".utf8)), "nothing of the file shows in what is sent")
        let macKey = mac.publicKey.rawRepresentation
        XCTAssertEqual(try PairingFileSeal.open(sealed, serverPublicKey: macKey, with: phone), file)

        XCTAssertThrowsError(try PairingFileSeal.open(sealed, serverPublicKey: macKey, with: .init()))
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0xFF
        XCTAssertThrowsError(try PairingFileSeal.open(tampered, serverPublicKey: macKey, with: phone))
        XCTAssertThrowsError(try PairingFileSeal.seal(file, to: Data([1, 2, 3]), with: mac))
    }

    func testTheCodeDependsOnBothSides() {
        let a = Phone(), b = Phone()
        let macKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let macNonce = PairingFileSeal.makeNonce()
        let code = PairingFileSeal.code(clientPublicKey: a.publicKey, clientNonce: a.nonce, serverPublicKey: macKey,
                                        serverNonce: macNonce)
        XCTAssertNotNil(code.range(of: #"^\d{3} \d{3}$"#, options: .regularExpression), code)
        XCTAssertEqual(code, PairingFileSeal.code(clientPublicKey: a.publicKey, clientNonce: a.nonce,
                                                  serverPublicKey: macKey, serverNonce: macNonce))
        XCTAssertNotEqual(code, PairingFileSeal.code(clientPublicKey: b.publicKey, clientNonce: a.nonce,
                                                     serverPublicKey: macKey, serverNonce: macNonce))
        XCTAssertNotEqual(code, PairingFileSeal.code(clientPublicKey: a.publicKey, clientNonce: a.nonce,
                                                     serverPublicKey: macKey, serverNonce: PairingFileSeal.makeNonce()))
        XCTAssertEqual(PairingFileSeal.makeNonce().count, 16)
        XCTAssertNotEqual(PairingFileSeal.makeNonce(), PairingFileSeal.makeNonce())
    }

    // MARK: - The server

    private func request(_ method: String, _ path: String, token: String? = nil, body: Data = Data()) -> HTTPRequest {
        var headers = ["content-length": String(body.count)]
        if let token { headers["authorization"] = "Bearer \(token)" }
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func token(for server: MacRemoteServer, id: String = "phone", name: String = "Sam's iPhone") async throws -> String {
        let body = try RemoteAPI.makeEncoder().encode(PairRequest(code: pairing.currentCode, clientName: name, clientID: id))
        let response = await server.handle(request("POST", RemoteAPI.Path.pair, body: body))
        XCTAssertEqual(response.status, 200)
        return try RemoteAPI.makeDecoder().decode(PairResponse.self, from: response.body).token
    }

    private func send(_ server: MacRemoteServer, token: String?, _ ask: PairingFileRequest) async throws
        -> (status: Int, answer: PairingFileResponse?) {
        let body = try RemoteAPI.makeEncoder().encode(ask)
        let response = await server.handle(request("POST", RemoteAPI.Path.pairingFile, token: token, body: body))
        return (response.status, try? RemoteAPI.makeDecoder().decode(PairingFileResponse.self, from: response.body))
    }

    /// Sends the reveal again every 20 ms, as the iPhone does every couple of seconds, until it isn't waiting.
    private func settle(_ server: MacRemoteServer, token: String, _ phone: Phone) async throws -> PairingFileResponse {
        for _ in 0..<200 {
            let (_, answer) = try await send(server, token: token, phone.reveal)
            if let answer, answer.state != .waiting { return answer }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("still waiting")
        return PairingFileResponse(state: .waiting)
    }

    private func make(_ controller: RemoteController) -> MacRemoteServer {
        MacRemoteServer(name: "Test Mac", port: 0, controller: controller, pairing: pairing)
    }

    func testTheMacAsksOnlyAfterTheRevealAndBothShowTheSameCode() async throws {
        let fake = PairingFileFake(.allow(file, nil))
        let server = make(fake)
        let token = try await token(for: server)
        let phone = Phone()

        let opened = try await send(server, token: token, phone.commit)
        XCTAssertEqual(opened.status, 200)
        XCTAssertEqual(opened.answer?.state, .waiting)
        XCTAssertNotNil(opened.answer?.serverPublicKey)
        XCTAssertNotNil(opened.answer?.serverNonce)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(fake.codes.isEmpty, "nothing is asked on the Mac before the reveal")

        let answer = try await settle(server, token: token, phone)
        XCTAssertEqual(answer.state, .ready)
        let sealed = try XCTUnwrap(answer.sealed)
        let macKey = try XCTUnwrap(opened.answer?.serverPublicKey)
        XCTAssertEqual(answer.serverPublicKey, macKey, "the same Mac key from start to end")
        XCTAssertEqual(try PairingFileSeal.open(sealed, serverPublicKey: macKey, with: phone.key), file)
        XCTAssertEqual(fake.codes, [try XCTUnwrap(phone.code(try XCTUnwrap(opened.answer)))])
        XCTAssertEqual(fake.askedNames, ["Sam's iPhone"])
    }

    func testARevealThatDoesntMatchTheCommitmentIsRefused() async throws {
        let fake = PairingFileFake(.allow(file, nil))
        let server = make(fake)
        let token = try await token(for: server)
        let phone = Phone(), other = Phone()
        _ = try await send(server, token: token, phone.commit)
        // Someone in the middle swaps in a key of their own after seeing the Mac's.
        let swapped = PairingFileRequest(commitment: phone.commitment, publicKey: other.publicKey, nonce: other.nonce)
        let answer = try await send(server, token: token, swapped)
        XCTAssertEqual(answer.answer?.state, .failed)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(fake.codes.isEmpty)
        // And the request is gone: the real reveal doesn't revive it.
        let late = try await send(server, token: token, phone.reveal)
        XCTAssertEqual(late.answer?.state, .failed)
    }

    func testAFileWithoutTheNewerPartSaysSo() async throws {
        let server = make(PairingFileFake(.allow(file, "no USB")))
        let token = try await token(for: server)
        let phone = Phone()
        _ = try await send(server, token: token, phone.commit)
        let answer = try await settle(server, token: token, phone)
        XCTAssertEqual(answer.state, .ready)
        XCTAssertEqual(answer.olderIOSOnly, "no USB")
    }

    func testANoComesBackAsOneAndTheIPhoneWaitsBeforeAskingAgain() async throws {
        let fake = PairingFileFake(.deny)
        let server = make(fake)
        let token = try await token(for: server)
        let phone = Phone()
        _ = try await send(server, token: token, phone.commit)
        let no = try await settle(server, token: token, phone)
        XCTAssertEqual(no.state, .denied)
        XCTAssertNil(no.sealed)
        // Straight away again: turned down, so no new question pops up on the Mac.
        let again = try await send(server, token: token, Phone().commit)
        XCTAssertEqual(again.answer?.state, .failed)
        XCTAssertEqual(fake.codes.count, 1)
    }

    func testFailuresSayWhy() async throws {
        let server = make(PairingFileFake(.fail("No iPhone is plugged in.")))
        let token = try await token(for: server)
        let phone = Phone()
        _ = try await send(server, token: token, phone.commit)
        let failed = try await settle(server, token: token, phone)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.message, "No iPhone is plugged in.")
        // A failure isn't a no: trying again right away is fine.
        let again = try await send(server, token: token, Phone().commit)
        XCTAssertEqual(again.answer?.state, .waiting)
    }

    func testAMacThatCantSendFilesSaysHow() async throws {
        let server = make(PlainController())
        let token = try await token(for: server)
        let phone = Phone()
        _ = try await send(server, token: token, phone.commit)
        let answer = try await settle(server, token: token, phone)
        XCTAssertEqual(answer.state, .failed)
        XCTAssertTrue(answer.message?.contains("Pairing File for the iPhone App") == true, answer.message ?? "")
    }

    func testOnlyAPairedIPhoneMayAskAndOnlyProperly() async throws {
        let fake = PairingFileFake(.allow(file, nil))
        let server = make(fake)
        let phone = Phone()
        let noToken = try await send(server, token: nil, phone.commit)
        let madeUp = try await send(server, token: "made-up", phone.commit)
        XCTAssertEqual([noToken.status, madeUp.status], [401, 401])

        let token = try await token(for: server)
        for bad in [PairingFileRequest(commitment: Data([1, 2, 3])),
                    PairingFileRequest(commitment: phone.commitment, publicKey: phone.publicKey, nonce: nil),
                    PairingFileRequest(commitment: phone.commitment, publicKey: Data([1]), nonce: phone.nonce)] {
            let response = try await send(server, token: token, bad)
            XCTAssertEqual(response.status, 400)
        }
        // A reveal with no commitment before it is a request that has expired.
        let early = try await send(server, token: token, phone.reveal)
        XCTAssertEqual(early.answer?.state, .failed)
        XCTAssertTrue(fake.codes.isEmpty, "nothing was asked on the Mac")
    }

    func testOneQuestionIsOnTheMacAtATime() async throws {
        let fake = PairingFileFake(.waitForever)
        let server = make(fake)
        let mine = try await token(for: server, id: "phone")
        let theirs = try await token(for: server, id: "other-phone", name: "Other")
        let first = Phone(), second = Phone()
        _ = try await send(server, token: mine, first.commit)
        let asking = try await send(server, token: mine, first.reveal)
        XCTAssertEqual(asking.answer?.state, .waiting)
        _ = try await send(server, token: theirs, second.commit)
        let blocked = try await send(server, token: theirs, second.reveal)
        XCTAssertEqual(blocked.answer?.state, .failed)
        let still = try await send(server, token: mine, first.reveal)
        XCTAssertEqual(still.answer?.state, .waiting)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.codes.count, 1)
    }

    func testAnotherIPhoneCantCollectTheAnswer() async throws {
        let server = make(PairingFileFake(.allow(file, nil)))
        let mine = try await token(for: server, id: "phone")
        let theirs = try await token(for: server, id: "other-phone", name: "Other")
        let phone = Phone()
        _ = try await send(server, token: mine, phone.commit)
        _ = try await settle(server, token: mine, phone)
        let stolen = try await send(server, token: theirs, phone.reveal)
        XCTAssertEqual(stolen.answer?.state, .failed)
        XCTAssertNil(stolen.answer?.sealed)
    }

    func testNamesAreShownOnOneCleanLine() {
        XCTAssertEqual(PairingFileDesk.printable("Sam's\u{1B}[2K iPhone\nAllow"), "Sam's [2K iPhone Allow")
        XCTAssertEqual(PairingFileDesk.printable("  \n "), "An iPhone")
        XCTAssertEqual(PairingFileDesk.printable(String(repeating: "x", count: 80)).count, 40)
    }
}
