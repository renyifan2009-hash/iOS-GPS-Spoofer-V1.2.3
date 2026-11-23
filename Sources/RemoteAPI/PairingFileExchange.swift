import CryptoKit
import Foundation

// The iPhone asking the Mac for its own pairing file (`POST /pairingfile`), so it can set up the
// iPhone-only mode without AirDrop or Files.
//
// The file is a key to the iPhone, and the link between the two is plain HTTP on the local network,
// where a bearer token can be overheard. So the two compare a code, the way Bluetooth pairing does, and
// the file travels sealed to a key only the iPhone that asked holds:
//
// 1. The iPhone makes a one-time X25519 key pair and a random nonce, and sends only a commitment to
//    them: SHA-256(public key ‖ nonce).
// 2. The Mac answers with its own one-time public key and nonce.
// 3. The iPhone reveals its public key and nonce. The Mac checks them against the commitment, and only
//    then asks the person at the Mac, showing a 6-digit code made from all four values; the iPhone shows
//    the same code. Neither side can steer the code once the other has spoken, so someone in the middle
//    (who would be talking to each side with keys of their own) gets a different code on each screen,
//    except by a one-in-a-million chance per try.
// 4. Once allowed, the file comes back sealed with X25519 → HKDF-SHA256 → ChaCha20-Poly1305 between the
//    two one-time keys.
//
// The iPhone sends step 3's request again every couple of seconds until the answer isn't `waiting`: the
// person at the Mac may take longer than one HTTP connection stays open.

public struct PairingFileRequest: Codable, Sendable, Equatable {
    /// SHA-256 of the iPhone's one-time X25519 public key followed by its nonce (`PairingFileSeal.commitment`).
    public var commitment: Data
    /// Revealed in step 3, once the Mac has answered with its own key: the public key behind `commitment`.
    public var publicKey: Data?
    /// Revealed with `publicKey`: the nonce behind `commitment`.
    public var nonce: Data?

    public init(commitment: Data, publicKey: Data? = nil, nonce: Data? = nil) {
        self.commitment = commitment
        self.publicKey = publicKey
        self.nonce = nonce
    }

    /// Step 3: the key and nonce are here.
    public var reveals: Bool { publicKey != nil }

    public var isValid: Bool {
        guard commitment.count == 32, (publicKey == nil) == (nonce == nil) else { return false }
        guard let publicKey, let nonce else { return true }
        return publicKey.count == 32 && nonce.count == PairingFileSeal.nonceLength
    }
}

public struct PairingFileResponse: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// The Mac is waiting for the reveal, asking its user, or making the file.
        case waiting
        /// `sealed` holds the file.
        case ready
        /// The person at the Mac said no.
        case denied
        /// It couldn't be made: `message` says why.
        case failed
    }

    public var state: State
    /// What to show: why it failed, or what the Mac is doing.
    public var message: String?
    /// The Mac's one-time X25519 public key for this request (from step 2 on).
    public var serverPublicKey: Data?
    /// The Mac's nonce for this request (from step 2 on).
    public var serverNonce: Data?
    /// The pairing file, sealed to the iPhone's key (ChaCha20-Poly1305: nonce + ciphertext + tag).
    public var sealed: Data?
    /// The file has no Remote Pairing identity, only the lockdown record: why. It then works only on
    /// iOS versions that still answer lockdown through LocalDevVPN.
    public var olderIOSOnly: String?

    public init(state: State, message: String? = nil, serverPublicKey: Data? = nil, serverNonce: Data? = nil,
                sealed: Data? = nil, olderIOSOnly: String? = nil) {
        self.state = state
        self.message = message
        self.serverPublicKey = serverPublicKey
        self.serverNonce = serverNonce
        self.sealed = sealed
        self.olderIOSOnly = olderIOSOnly
    }
}

public enum PairingFileSeal {
    public struct Failure: Error, Sendable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    public static let nonceLength = 16
    private static let salt = Data("AnyWhere pairing file".utf8)

    /// A fresh random nonce (the system's cryptographically secure generator).
    public static func makeNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<nonceLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// What the iPhone sends first: SHA-256(public key ‖ nonce).
    public static func commitment(publicKey: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: publicKey + nonce))
    }

    /// The code both screens show: 6 digits from both one-time keys and both nonces, "482 913".
    public static func code(clientPublicKey: Data, clientNonce: Data, serverPublicKey: Data, serverNonce: Data) -> String {
        let digest = Array(SHA256.hash(data: Data("AnyWhere code".utf8) + clientPublicKey + serverPublicKey
                                                 + clientNonce + serverNonce))
        let number = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3]))
            % 1_000_000
        let digits = String(format: "%06u", number)
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }

    /// The Mac's side: `file` sealed to the iPhone's public key with the Mac's one-time key for this request.
    public static func seal(_ file: Data, to clientPublicKey: Data,
                            with serverKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        let client: Curve25519.KeyAgreement.PublicKey
        do {
            client = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPublicKey)
        } catch {
            throw Failure("The iPhone's key isn't valid.")
        }
        let key = symmetricKey(try serverKey.sharedSecretFromKeyAgreement(with: client),
                               clientPublicKey: clientPublicKey, serverPublicKey: serverKey.publicKey.rawRepresentation)
        return try ChaChaPoly.seal(file, using: key).combined
    }

    /// The iPhone's side: open what the Mac sent with the private key made for this request.
    public static func open(_ sealed: Data, serverPublicKey: Data,
                            with privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        do {
            let server = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPublicKey)
            let key = symmetricKey(try privateKey.sharedSecretFromKeyAgreement(with: server),
                                   clientPublicKey: privateKey.publicKey.rawRepresentation,
                                   serverPublicKey: serverPublicKey)
            return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key)
        } catch {
            throw Failure("The pairing file from the Mac couldn't be opened. Try again.")
        }
    }

    private static func symmetricKey(_ secret: SharedSecret, clientPublicKey: Data,
                                     serverPublicKey: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                       sharedInfo: clientPublicKey + serverPublicKey, outputByteCount: 32)
    }
}
