import Foundation

/// A way for SpoofRemote to open the developer tunnel to its own iPhone.
public enum TunnelRoute: Hashable, Sendable {
    /// Pair-verify with remotepairingd on this port, then its own tunnel.
    /// Needs the file's Remote Pairing identity. The only way on newer iOS.
    case remotePairing(port: UInt16)
    /// Lockdown with the file's lockdown record, then CoreDeviceProxy. Older
    /// iOS only: newer versions don't answer lockdown through LocalDevVPN.
    case lockdown

    /// A few words for an error's small print.
    public var name: String {
        switch self {
        case .remotePairing(let port): "Remote Pairing, port \(port)"
        case .lockdown: "lockdown"
        }
    }
}

/// Which of the iPhone's developer ports took a connection through LocalDevVPN.
public struct DeveloperPorts: Equatable, Sendable {
    /// remotepairingd's ports that answered, in the order to try them.
    public var remotePairing: [UInt16]
    /// Whether lockdown (62078) answered.
    public var lockdown: Bool

    public init(remotePairing: [UInt16] = [], lockdown: Bool = false) {
        self.remotePairing = remotePairing
        self.lockdown = lockdown
    }

    /// Something answered, so LocalDevVPN is on and routing.
    public var anyAnswered: Bool { lockdown || !remotePairing.isEmpty }
}

/// Decides how to connect from what the pairing file holds and which ports answer.
public enum TunnelPlan {
    /// Where remotepairingd usually listens: the first port iOS hands out.
    /// StikDebug connects here. It isn't guaranteed, so SpoofRemote also looks
    /// the port up with Bonjour (`_remotepairing._tcp`), as SideStore does.
    public static let usualRemotePairingPort: UInt16 = 49152
    public static let lockdownPort: UInt16 = 62078

    /// remotepairingd's ports worth knocking on: the one Bonjour named, if
    /// any, then the usual one.
    public static func remotePairingCandidates(discovered: UInt16?) -> [UInt16] {
        var ports: [UInt16] = []
        if let discovered, discovered != 0 { ports.append(discovered) }
        if !ports.contains(usualRemotePairingPort) { ports.append(usualRemotePairingPort) }
        return ports
    }

    public enum Readiness: Equatable, Sendable {
        /// Try these, in this order, until one opens the tunnel.
        case ready([TunnelRoute])
        /// Nothing answered: LocalDevVPN is off, or iOS is blocking the app
        /// from the local network.
        case nothingAnswers
        /// The iPhone only answers Remote Pairing now, and the file was saved
        /// without that identity (by an older Mac app, or one that couldn't
        /// make it). A new file from the current Mac app fixes it.
        case fileLacksRemotePairing
        /// The file only has a Remote Pairing identity, and remotepairingd
        /// didn't answer on any port tried.
        case remotePairingDoesNotAnswer
    }

    /// Whether lockdown (CoreDeviceProxy) is worth trying through LocalDevVPN on this iOS version.
    /// It needs iOS 17.4. From iOS 26.4 the iPhone closes lockdown connections through the loopback
    /// at once ("Broken pipe"), so Remote Pairing is the only way (SideStore/SideStore#1656, #1720).
    /// Trying it anyway only put a misleading lockdown error next to the real one.
    public static func allowsLockdown(onIOS version: OperatingSystemVersion) -> Bool {
        let v = (version.majorVersion, version.minorVersion)
        return v >= (17, 4) && v < (26, 4)
    }

    /// Remote Pairing first. Lockdown/CoreDeviceProxy is a second chance on
    /// iOS 17.4 to 26.3 when reachable. Route selection alone does not prove OS compatibility.
    public static func readiness(for record: PairingRecord, ports: DeveloperPorts, allowLockdown: Bool = true) -> Readiness {
        guard ports.anyAnswered else { return .nothingAnswers }
        var routes: [TunnelRoute] = []
        if record.hasRemotePairingIdentity {
            routes += ports.remotePairing.map { .remotePairing(port: $0) }
        }
        if allowLockdown, record.hasLockdownRecord, ports.lockdown {
            routes.append(.lockdown)
        }
        if !routes.isEmpty { return .ready(routes) }
        return record.hasRemotePairingIdentity ? .remotePairingDoesNotAnswer : .fileLacksRemotePairing
    }

    /// Every route the file allows, for when the ports haven't been checked.
    public static func routes(for record: PairingRecord, discoveredPort: UInt16? = nil,
                              allowLockdown: Bool = true) -> [TunnelRoute] {
        var routes: [TunnelRoute] = []
        if record.hasRemotePairingIdentity {
            routes += remotePairingCandidates(discovered: discoveredPort).map { .remotePairing(port: $0) }
        }
        if allowLockdown, record.hasLockdownRecord { routes.append(.lockdown) }
        return routes
    }
}
