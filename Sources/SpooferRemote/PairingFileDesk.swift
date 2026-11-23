import CryptoKit
import Foundation
import RemoteAPI

/// Keeps track of the iPhones asking for their pairing file (`POST /pairingfile`); see
/// `PairingFileExchange.swift` for the steps.
///
/// A commitment opens a request and gets the Mac's one-time key and nonce back; nothing is asked yet.
/// The reveal that matches it starts the question on the Mac. The iPhone then sends the reveal again
/// every couple of seconds and gets `waiting` until there is an answer. Only one question is on the
/// Mac at a time, an iPhone that was turned down waits a little before it can ask again, and every
/// request is forgotten after a few minutes.
actor PairingFileDesk {
    private struct Entry {
        let id = UUID()
        let clientID: String
        let started: Date
        let serverKey: Curve25519.KeyAgreement.PrivateKey
        let serverNonce: Data
        /// Set by the reveal: the question is on the Mac, or answered.
        var asked = false
        var answer: PairingFileResponse
    }

    /// How long a request and its answer are kept.
    static let lifetime: TimeInterval = 5 * 60
    /// How long an iPhone waits after a no (or a question left unanswered) before it can ask again.
    static let cooldown: TimeInterval = 30

    private var entries: [Data: Entry] = [:]
    private var quietUntil: [String: Date] = [:]

    /// The answer to `request`, and the code when this request just started the question on the Mac.
    func answer(_ request: PairingFileRequest, from client: PairingManager.PairedClient,
                controller: RemoteController, now: Date = Date()) -> (PairingFileResponse, startedCode: String?) {
        entries = entries.filter { now.timeIntervalSince($0.value.started) < Self.lifetime }
        quietUntil = quietUntil.filter { $0.value > now }
        let key = request.commitment

        guard var entry = entries[key] else {
            // A new request: the Mac's key and nonce, nothing asked yet.
            guard !request.reveals else { return (Self.failed("That request has expired. Try again."), nil) }
            if quietUntil[client.id] != nil {
                return (Self.failed("Wait half a minute before asking again."), nil)
            }
            // An iPhone has one request open at most: a newer one replaces any it hasn't revealed.
            entries = entries.filter { $0.value.clientID != client.id || $0.value.asked }
            let entry = Entry(clientID: client.id, started: now, serverKey: Curve25519.KeyAgreement.PrivateKey(),
                              serverNonce: PairingFileSeal.makeNonce(),
                              answer: PairingFileResponse(state: .waiting, message: "Waiting for the iPhone…"))
            entries[key] = entry
            return (withServerKey(entry.answer, entry), nil)
        }

        // Only the iPhone that asked gets the answer.
        guard entry.clientID == client.id else { return (Self.failed("That request is another iPhone's."), nil) }
        guard !entry.asked else { return (withServerKey(entry.answer, entry), nil) }
        guard let publicKey = request.publicKey, let nonce = request.nonce else {
            return (withServerKey(entry.answer, entry), nil)
        }
        guard PairingFileSeal.commitment(publicKey: publicKey, nonce: nonce) == key else {
            entries[key] = nil
            return (Self.failed("The iPhone's key doesn't match what it sent first. Try again."), nil)
        }
        if entries.values.contains(where: { $0.asked && $0.answer.state == .waiting }) {
            return (Self.failed("The Mac is still answering another request. Try again in a minute."), nil)
        }

        let code = PairingFileSeal.code(clientPublicKey: publicKey, clientNonce: nonce,
                                        serverPublicKey: entry.serverKey.publicKey.rawRepresentation,
                                        serverNonce: entry.serverNonce)
        entry.asked = true
        entry.answer = PairingFileResponse(state: .waiting, message: "Waiting for the Mac…")
        entries[key] = entry
        let id = entry.id
        let serverKey = entry.serverKey
        let name = client.name
        Task {
            let answer = await Self.make(for: publicKey, serverKey: serverKey, clientName: name, code: code,
                                         controller: controller)
            self.finish(key, id: id, clientID: client.id, with: answer)
        }
        return (withServerKey(entry.answer, entry), code)
    }

    private func finish(_ key: Data, id: UUID, clientID: String, with answer: PairingFileResponse) {
        // A request forgotten (and maybe asked again) meanwhile doesn't get this answer.
        guard entries[key]?.id == id else { return }
        entries[key]?.answer = answer
        // Turned down, or left unanswered: no new question from this iPhone for a little while, so a
        // stolen token can't keep putting questions up on the Mac.
        if answer.state == .denied { quietUntil[clientID] = Date().addingTimeInterval(Self.cooldown) }
    }

    private func withServerKey(_ answer: PairingFileResponse, _ entry: Entry) -> PairingFileResponse {
        var answer = answer
        answer.serverPublicKey = entry.serverKey.publicKey.rawRepresentation
        answer.serverNonce = entry.serverNonce
        return answer
    }

    private static func failed(_ message: String) -> PairingFileResponse {
        PairingFileResponse(state: .failed, message: message)
    }

    private static func make(for clientPublicKey: Data, serverKey: Curve25519.KeyAgreement.PrivateKey,
                             clientName: String, code: String, controller: RemoteController) async -> PairingFileResponse {
        do {
            let payload = try await controller.pairingFile(forClientNamed: Self.printable(clientName), code: code)
            let sealed = try PairingFileSeal.seal(payload.data, to: clientPublicKey, with: serverKey)
            return PairingFileResponse(state: .ready, sealed: sealed, olderIOSOnly: payload.olderIOSOnly)
        } catch let error as RemoteControlError {
            return PairingFileResponse(state: error.status == 403 ? .denied : .failed, message: error.message)
        } catch {
            return PairingFileResponse(state: .failed, message: "\(error)")
        }
    }

    /// An iPhone's name as it's shown in the question: no control characters (which could move the cursor
    /// or hide the code in a terminal), on one line, not too long.
    static func printable(_ name: String) -> String {
        let scalars = name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : String($0) }
        var cleaned = scalars.joined().trimmingCharacters(in: .whitespaces)
        if cleaned.count > 40 { cleaned = String(cleaned.prefix(39)) + "…" }
        return cleaned.isEmpty ? "An iPhone" : cleaned
    }
}
