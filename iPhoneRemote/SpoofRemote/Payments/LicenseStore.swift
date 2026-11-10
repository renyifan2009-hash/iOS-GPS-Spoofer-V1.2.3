import CryptoKit
import Foundation
import Observation
@preconcurrency import Security

/// AnyWhere Pro: $2.99 a month, $15 a year, or $20 once. The app is sideloaded, so it is paid for with
/// Stripe Checkout in Safari, not the App Store. The payment server (`payments/` in this repo) gives a
/// license key, and checks it: it answers with the plan, signed with an Ed25519 key whose public half is
/// built into the app, so a saved answer can be trusted offline for a few days.
///
/// Payments are off (everything free) until the server's address and key are set in project.yml
/// (`AW_PAYMENTS_SERVER`, `AW_PAYMENTS_PUBLIC_KEY`).
enum Plan: String, CaseIterable, Codable, Identifiable, Sendable {
    case monthly, yearly, lifetime

    var id: String { rawValue }
    var title: String {
        switch self {
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        case .lifetime: "Lifetime"
        }
    }
    var price: String {
        switch self {
        case .monthly: "$2.99"
        case .yearly: "$15"
        case .lifetime: "$20"
        }
    }
    var period: String {
        switch self {
        case .monthly: "a month"
        case .yearly: "a year"
        case .lifetime: "once"
        }
    }
    /// 12 × $2.99 is $35.88: a year at $15 saves 58%.
    var badge: String? {
        switch self {
        case .monthly: nil
        case .yearly: "Save 58%"
        case .lifetime: "Pay once"
        }
    }
    var detail: String {
        switch self {
        case .monthly: "Cancel any time."
        case .yearly: "Just $1.25 a month."
        case .lifetime: "Yours for good, with every update."
        }
    }
}

enum PaymentsConfig {
    /// The payment server, from Info.plist (`AW_PAYMENTS_SERVER` in project.yml). Empty: payments off.
    static let server: URL? = {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "AWPaymentsServer") as? String,
              !text.isEmpty, !text.hasPrefix("$("), let url = URL(string: text), url.scheme == "https" else { return nil }
        return url
    }()

    /// The Ed25519 public key (32 bytes, base64) the server signs answers with.
    static let publicKey: Curve25519.Signing.PublicKey? = {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "AWPaymentsPublicKey") as? String,
              let data = Data(base64Encoded: text) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }()

    static var isEnabled: Bool { server != nil && publicKey != nil }

    /// Days to try everything before paying, counted from first use on this iPhone.
    static let trialDays = 3
}

/// What the server vouched for, as it signed it.
struct License: Codable, Equatable, Sendable {
    var key: String
    var plan: Plan
    /// "active", "trialing", "past_due", "lifetime", "canceled", …
    var status: String
    /// When the paid time ends (nil for lifetime), Unix seconds.
    var expiresAt: Double?
    /// When the server said this, Unix seconds.
    var issuedAt: Double
    /// Trust this answer offline until then, Unix seconds.
    var validUntil: Double
    /// A subscription cancelled to stop at the end of the paid time.
    var endsAtPeriodEnd: Bool?

    func isValid(at now: Date = Date()) -> Bool {
        let t = now.timeIntervalSince1970
        guard ["active", "trialing", "past_due", "lifetime"].contains(status), t < validUntil else { return false }
        if let expiresAt { return t < expiresAt + 3 * 24 * 3600 }
        return true
    }
}

@MainActor
@Observable
final class LicenseStore {
    private(set) var license: License?
    private(set) var working = false
    private(set) var lastError: String?
    /// When this iPhone first opened AnyWhere: the trial counts from here. Kept in the Keychain, so a
    /// reinstall doesn't start it over.
    let trialStart: Date

    private let session: URLSession
    private let now: () -> Date

    init(session: URLSession = .shared, now: @escaping () -> Date = Date.init) {
        self.session = session
        self.now = now
        if let saved = SecretStore.read("trialStart").flatMap(Double.init) {
            trialStart = Date(timeIntervalSince1970: saved)
        } else {
            trialStart = now()
            SecretStore.write(String(trialStart.timeIntervalSince1970), for: "trialStart")
        }
        if let data = SecretStore.read("license")?.data(using: .utf8),
           let token = try? JSONDecoder().decode(SignedToken.self, from: data),
           let verified = Self.verify(token) {
            license = verified
        }
    }

    // MARK: What the person can do

    var trialEnds: Date { trialStart.addingTimeInterval(Double(PaymentsConfig.trialDays) * 24 * 3600) }
    var inTrial: Bool { now() < trialEnds }
    var hasPro: Bool { license?.isValid(at: now()) == true }

    /// Everything is open: payments are off, Pro is paid for, or the trial is on.
    var canUseEverything: Bool { !PaymentsConfig.isEnabled || hasPro || inTrial }

    /// "Pro · Yearly · renews 12 Nov 2027", "Free trial · 2 days left", "Free".
    var summary: String {
        if !PaymentsConfig.isEnabled { return "All features included" }
        if let license, license.isValid(at: now()) {
            guard let end = license.expiresAt else { return "Pro · Lifetime" }
            let date = Date(timeIntervalSince1970: end).formatted(date: .abbreviated, time: .omitted)
            return "Pro · \(license.plan.title) · \(license.endsAtPeriodEnd == true ? "ends" : "renews") \(date)"
        }
        if inTrial {
            let days = max(0, Calendar.current.dateComponents([.day], from: now(), to: trialEnds).day ?? 0)
            return days <= 0 ? "Free trial · ends today" : "Free trial · \(days) day\(days == 1 ? "" : "s") left"
        }
        return "Trial ended"
    }

    // MARK: Buying

    /// A Stripe Checkout page for `plan`. Paying there ends on a page that opens
    /// `anywhere://activate?key=…`, which comes back to `activate(key:)`.
    func checkoutURL(for plan: Plan) async -> URL? {
        struct Answer: Decodable { var url: URL }
        let answer: Answer? = await post("api/checkout", ["plan": plan.rawValue])
        return answer?.url
    }

    /// Stripe's page for changing the card, switching plan or cancelling.
    func manageURL() async -> URL? {
        guard let key = license?.key else { return nil }
        struct Answer: Decodable { var url: URL }
        let answer: Answer? = await post("api/portal", ["key": key])
        return answer?.url
    }

    /// Check a license key with the server and keep it.
    @discardableResult
    func activate(key raw: String) async -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeKey(key) else {
            lastError = "That doesn't look like an AnyWhere license key. It starts with aw_."
            return false
        }
        guard let token: SignedToken = await post("api/license", ["key": key]) else { return false }
        guard let verified = Self.verify(token), verified.key == key else {
            lastError = "The payment server's answer couldn't be checked. Update AnyWhere and try again."
            return false
        }
        license = verified
        if let data = try? JSONEncoder().encode(token), let text = String(data: data, encoding: .utf8) {
            SecretStore.write(text, for: "license")
        }
        lastError = verified.isValid(at: now()) ? nil : "This license isn't active. Renew it, or choose a plan."
        return verified.isValid(at: now())
    }

    /// Ask again, at most once a day (on launch). No network keeps the saved answer, quietly, until it
    /// runs out; an answer that the license ended replaces it.
    func refreshIfDue() async {
        guard PaymentsConfig.isEnabled, let saved = license, !working,
              now().timeIntervalSince1970 - saved.issuedAt > 20 * 3600 else { return }
        let ok = await activate(key: saved.key)
        if !ok, license == saved { lastError = nil }
    }

    func signOut() {
        license = nil
        SecretStore.delete("license")
    }

    static func looksLikeKey(_ key: String) -> Bool {
        key.range(of: #"^aw_[A-Za-z0-9]{6,40}_[A-Z2-7]{12,40}$"#, options: .regularExpression) != nil
    }

    // MARK: The server

    /// The server's signed answer: the license as JSON (base64) and an Ed25519 signature of those bytes.
    struct SignedToken: Codable, Sendable {
        var payload: String
        var signature: String
    }

    /// The server's `{"error": "…"}` when it turns a request down.
    private struct ServerProblem: Decodable { var error: String }

    static func verify(_ token: SignedToken) -> License? {
        guard let key = PaymentsConfig.publicKey,
              let payload = Data(base64Encoded: token.payload),
              let signature = Data(base64Encoded: token.signature),
              key.isValidSignature(signature, for: payload) else { return nil }
        return try? JSONDecoder().decode(License.self, from: payload)
    }

    private func post<Answer: Decodable>(_ path: String, _ body: [String: String]) async -> Answer? {
        guard let server = PaymentsConfig.server else {
            lastError = "Payments aren't set up in this build."
            return nil
        }
        working = true
        defer { working = false }
        var request = URLRequest(url: server.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                lastError = (try? JSONDecoder().decode(ServerProblem.self, from: data))?.error
                    ?? "The payment server answered \(code). Try again in a minute."
                return nil
            }
            lastError = nil
            return try JSONDecoder().decode(Answer.self, from: data)
        } catch {
            lastError = "Couldn't reach the payment server: \(error.localizedDescription)"
            return nil
        }
    }
}

/// Small strings kept in this iPhone's Keychain (the license and the trial's start). Keychain items
/// stay through a reinstall.
enum SecretStore {
    private static let service = "com.iosgpsspoof.remote.pro"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func write(_ value: String, for account: String) {
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil)
        }
    }

    static func read(_ account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
