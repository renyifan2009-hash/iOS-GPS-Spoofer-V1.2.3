import Foundation

/// Why connecting to the iPhone's developer services failed: the step, the
/// route it was on, and what idevice reported.
public struct TunnelFailure: Error, Equatable, Sendable, LocalizedError {
    /// The steps of a connection, in order. A failure at a later step says
    /// more: the earlier ones worked.
    public enum Step: Int, Comparable, Sendable {
        case pairingFile
        case reach
        case tunnel
        case services
        case developerImage
        case instruments
        case simulation
        case setLocation
        case clearLocation

        public static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }

        public var title: String {
            switch self {
            case .pairingFile: "Reading the pairing file"
            case .reach: "Reaching the iPhone"
            case .tunnel: "Opening the developer tunnel"
            case .services: "Connecting to the developer services"
            case .developerImage: "Loading developer support"
            case .instruments: "Opening Instruments"
            case .simulation: "Opening location simulation"
            case .setLocation: "Setting the location"
            case .clearLocation: "Restoring the real location"
            }
        }
    }

    public var step: Step
    public var route: TunnelRoute?
    /// idevice's error code (`IdeviceError::code`), or -1 for a failure of our own.
    public var code: Int32
    /// idevice's sub-code: which Remote Pairing error, for code 103.
    public var subCode: Int32
    /// idevice's message: the Rust error's debug text.
    public var message: String
    /// When several routes were tried and this is the one shown: how the
    /// other routes failed, in the order they were tried.
    public var others: [TunnelFailure]

    public init(step: Step, route: TunnelRoute? = nil, code: Int32 = -1, subCode: Int32 = 0, message: String,
                others: [TunnelFailure] = []) {
        self.step = step
        self.route = route
        self.code = code
        self.subCode = subCode
        self.message = message
        self.others = others
    }

    public var errorDescription: String? { "\(step.title) failed: \(message)" }

    /// The file allowed no route at all (it shouldn't get this far).
    public static let noRoute = TunnelFailure(step: .reach, message: "the pairing file has no identity to connect with")

    // MARK: - What kind of failure

    /// idevice error codes this file reads (idevice/src/lib.rs, `IdeviceError::code`).
    private enum Code {
        static let socket: Int32 = 1
        static let unexpectedResponse: Int32 = 13
        static let internalError: Int32 = 16
        static let invalidHostID: Int32 = 18
        static let developerModeNotEnabled: Int32 = 24
        static let imageNotMounted: Int32 = 29
        static let pairingDialogResponsePending: Int32 = 30
        static let userDeniedPairing: Int32 = 31
        static let remotePairing: Int32 = 103
        static let timeout: Int32 = 109
    }

    private var text: String { message.lowercased() }

    /// The port didn't take the connection, or nothing came back: LocalDevVPN
    /// is off, or nothing listens there.
    public var isUnreachable: Bool {
        guard step <= .tunnel else { return false }
        if code == Code.timeout { return true }
        // tunnel_create_rppairing wraps its first connect as InternalError("connect: …").
        if code == Code.internalError, text.contains("connect:") { return true }
        guard code == Code.socket else { return false }
        return ["refused", "timed out", "timedout", "unreachable", "no route", "network is down", "notconnected",
                "addrnotavailable"].contains { text.contains($0) }
    }

    /// The iPhone took the connection and then dropped it.
    public var wasCutOff: Bool {
        guard code == Code.socket, step <= .tunnel else { return false }
        return ["reset", "brokenpipe", "broken pipe", "unexpectedeof", "unexpected end", "aborted"]
            .contains { text.contains($0) }
    }

    /// The iPhone doesn't know the identity in the pairing file, or turned it down.
    public var isPairingProblem: Bool {
        guard step <= .tunnel, !isUnreachable else { return false }
        switch code {
        case Code.remotePairing, Code.invalidHostID, Code.pairingDialogResponsePending, Code.userDeniedPairing:
            return true
        default:
            break
        }
        guard route == .lockdown else {
            // Pairing again got an answer it can't use: the iPhone said no in its own way.
            return code == Code.unexpectedResponse
                && ["pair consent", "pairing data", "pair record", "srp"].contains { text.contains($0) }
        }
        // Lockdown's session is TLS with the record's certificates.
        return ["pair", "ssl", "tls", "certificate"].contains { text.contains($0) }
    }

    /// Opening a Remote Pairing tunnel failed before pairing came into it, on
    /// this route or one of the others tried, so remotepairingd may be on
    /// another port: worth asking Bonjour and trying once more.
    public var pointsAtAnotherPort: Bool {
        ([self] + others).contains { failure in
            guard case .remotePairing = failure.route, failure.step == .tunnel else { return false }
            return !failure.isPairingProblem
        }
    }

    // MARK: - Telling the user

    /// Plain words for what went wrong, and what to do.
    public var explanation: String {
        if step == .pairingFile {
            return "This pairing file can't be read. Save a new one from your Mac and open it here."
        }
        if code == Code.developerModeNotEnabled || text.contains("developer mode") {
            return "Developer Mode is off. Turn it on in Settings ▸ Privacy & Security ▸ Developer Mode."
        }
        if step == .developerImage {
            return "Couldn't load Apple's developer support. In This iPhone ▸ Set Up, import a matching developer-image folder. Keep internet available for Apple's signing service."
        }
        if code == Code.imageNotMounted {
            return "Apple's developer support isn't loaded. Import a matching developer-image folder in This iPhone ▸ Set Up, or load it once from your Mac."
        }
        if step == .instruments || step == .simulation {
            return "This iPhone's location service didn't open. Check Developer Mode and developer support, then try again. This iOS build may use a different developer protocol."
        }
        if isUnreachable {
            return Self.unreachableExplanation
        }
        if isPairingProblem {
            return "The iPhone didn't accept the pairing file. A pairing file belongs to one iPhone: if you have more than one, "
                + "make sure it was saved with this one plugged in. Save a new one from your Mac and open it here."
        }
        if wasCutOff, case .remotePairing = route {
            return Self.remotePairingCutOffExplanation
        }
        if wasCutOff {
            return "This iPhone closed the connection while the tunnel was opening. Turn LocalDevVPN off and on, "
                + "then try again. If it keeps happening, save a new pairing file from your Mac."
        }
        return "\(step.title) didn't work: \(message)"
    }

    /// `explanation`, unless the iPhone couldn't be reached while cellular data was its only network:
    /// then the reason is that, not LocalDevVPN (see `PhoneNetwork`).
    public func explanation(onCellularOnly: Bool) -> String {
        onCellularOnly && isUnreachable ? Self.cellularExplanation : explanation
    }

    /// Remote Pairing answered and then cut the connection as the tunnel opened. That is how the iPhone
    /// turns away a pairing key it doesn't know (StikDebug/StikDebug#474: the same reset at
    /// 10.7.0.1:49152, gone with a newly made pairing file). The key goes stale when the Mac pairs with the
    /// iPhone again after the file was saved, or the iPhone forgets its pairings.
    public static let remotePairingCutOffExplanation = "This iPhone answered, then closed the connection: it "
        + "most likely no longer knows the key in this pairing file. On your Mac, plug this iPhone in by cable "
        + "and save a new pairing file (File ▸ Pairing File for the iPhone App…), then open it here. "
        + "If a new file doesn't help, turn LocalDevVPN off and on and try again."

    /// Also the message when nothing answers before a connection is tried.
    public static let unreachableExplanation = "Can't reach this iPhone's developer services at 10.7.0.1. Open LocalDevVPN "
        + "and check that it says Connected, with Device IP 10.7.0.1, or turn it off and on. Then try again. "
        + "If it still fails, allow AnyWhere in Settings ▸ Privacy & Security ▸ Local Network."

    /// The message when nothing answers and cellular data is the iPhone's only network: iOS turns
    /// LocalDevVPN's connection away then, so checking LocalDevVPN would not help.
    public static let cellularExplanation = "This iPhone is on cellular data, and iOS doesn't let LocalDevVPN reach "
        + "the developer services over cellular. Join Wi‑Fi, or keep LocalDevVPN connected and turn on Airplane Mode. "
        + "Then try again."

    /// The small print: enough for a bug report to say exactly what failed,
    /// one line for each route tried.
    public var detail: String {
        ([self] + others).map(\.line).joined(separator: "\n")
    }

    private var line: String {
        var parts = [step.title]
        if let route { parts.append(route.name) }
        if code >= 0 { parts.append(subCode == 0 ? "code \(code)" : "code \(code).\(subCode)") }
        return parts.joined(separator: " · ") + ": " + message
    }

    /// Of the failures of several routes, the one to show: the one that got
    /// furthest, and at the same step a pairing problem over a cut-off over a
    /// port that didn't answer. The rest go in its `others`.
    public static func mostTelling(_ failures: [TunnelFailure]) -> TunnelFailure? {
        func rank(_ failure: TunnelFailure) -> Int {
            let kind = failure.isPairingProblem ? 2 : failure.isUnreachable ? 0 : 1
            return failure.step.rawValue * 3 + kind
        }
        var best: Int?
        for (index, failure) in failures.enumerated() where best.map({ rank(failure) > rank(failures[$0]) }) ?? true {
            best = index
        }
        guard let best else { return nil }
        var shown = failures[best]
        shown.others = failures.enumerated().filter { $0.offset != best }.map(\.element)
        return shown
    }
}
