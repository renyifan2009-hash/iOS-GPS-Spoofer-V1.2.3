import Foundation
import PhoneOnlyCore

/// A paired iOS device as reported by `pymobiledevice3 usbmux list`.
public struct Device: Codable, Identifiable, Hashable, Sendable {
    public let deviceName: String
    public let identifier: String
    public let connectionType: String
    public let productType: String
    public let productVersion: String

    enum CodingKeys: String, CodingKey {
        case deviceName = "DeviceName"
        case identifier = "Identifier"
        case connectionType = "ConnectionType"
        case productType = "ProductType"
        case productVersion = "ProductVersion"
    }

    public init(deviceName: String, identifier: String, connectionType: String,
                productType: String, productVersion: String) {
        self.deviceName = deviceName
        self.identifier = identifier
        self.connectionType = connectionType
        self.productType = productType
        self.productVersion = productVersion
    }

    /// Tolerates missing fields: a device that hasn't been trusted yet reports
    /// little more than its UDID.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try c.decode(String.self, forKey: .identifier)
        deviceName = (try? c.decodeIfPresent(String.self, forKey: .deviceName)) ?? "iOS device"
        connectionType = (try? c.decodeIfPresent(String.self, forKey: .connectionType)) ?? "USB"
        productType = (try? c.decodeIfPresent(String.self, forKey: .productType)) ?? "unknown"
        productVersion = (try? c.decodeIfPresent(String.self, forKey: .productVersion)) ?? "0"
    }

    public var id: String { identifier }
    public var udid: String { identifier }

    /// Major iOS version, e.g. `18` for `"18.5"` (0 when unknown).
    public var majorVersion: Int {
        Int(productVersion.split(separator: ".").first ?? "") ?? 0
    }

    /// iOS 16 and older: location simulation goes through the lockdown
    /// `com.apple.dt.simulatelocation` service instead of the CoreDevice tunnel.
    public var isLegacy: Bool { majorVersion > 0 && majorVersion < 17 }

    /// An iPhone that hasn't been trusted yet reports little more than its UDID, so its model and
    /// version are unknown (`"unknown"` and `"0"`). Nothing works until the person taps Trust.
    public var isTrusted: Bool { majorVersion > 0 && productType != "unknown" }

    /// What to print under the iPhone's name: the model and iOS, or, until it is trusted (when it would say
    /// "unknown · iOS 0"), what to do about it.
    public var versionLine: String {
        isTrusted ? "\(modelName) · iOS \(productVersion)" : "Waiting for Trust on the iPhone"
    }

    /// Minor iOS version, e.g. `4` for `"17.4.1"` (0 when unknown).
    public var minorVersion: Int {
        let parts = productVersion.split(separator: ".")
        return parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    }

    /// iOS 17.4 and later can open pymobiledevice3's own (userspace) tunnel.
    public var supportsUserspaceTunnel: Bool {
        majorVersion > 17 || (majorVersion == 17 && minorVersion >= 4)
    }

    public var connectionLabel: String { connectionType.lowercased() }
    public var isUSB: Bool { connectionLabel == "usb" }

    public var summary: String {
        "\(deviceName) — iOS \(productVersion) (\(modelName), \(connectionLabel))"
    }

    /// Marketing name when known ("iPhone 15 Pro"), else the identifier.
    public var modelName: String { DeviceModels.marketingName(for: productType) ?? productType }

    /// SF Symbol for the device family.
    public var symbolName: String {
        if productType.hasPrefix("iPad") { return "ipad" }
        if productType.hasPrefix("iPod") { return "ipodtouch" }
        return "iphone"
    }
}

public enum ConnectionFilter: String, CaseIterable, Sendable {
    case any, usb, network

    public func matches(_ device: Device) -> Bool {
        switch self {
        case .any: return true
        case .usb: return device.connectionType.lowercased() == "usb"
        case .network: return device.connectionType.lowercased() == "network"
        }
    }
}

extension Pymobiledevice3 {
    /// All currently reachable paired devices, de-duplicated by UDID (a device
    /// paired over both USB and Wi-Fi is listed once, preferring the USB link).
    ///
    /// `usbmux list` opens a connection to every device usbmuxd knows, and one
    /// that can't be reached (a Wi-Fi iPhone that is asleep, say) makes the
    /// whole command fail. When that happens the list is read again for
    /// cable-connected devices only, which are the ones that can be spoofed
    /// reliably anyway. The first error is kept if that fails too.
    public func listDevices() throws -> [Device] {
        try readDevices().devices
    }

    /// The devices, and whether only cable-connected ones could be read (the
    /// full list failed). A phone that is on Wi-Fi only can be missing then.
    private func readDevices() throws -> (devices: [Device], cableOnly: Bool) {
        let raw: [Device]
        var cableOnly = false
        do {
            raw = try Self.decodeDevices(run(["usbmux", "list"], timeout: 20))
        } catch {
            guard let usbOnly = try? Self.decodeDevices(run(["usbmux", "list", "--usb"], timeout: 15)) else { throw error }
            raw = usbOnly
            cableOnly = true
        }

        var byUDID: [String: Device] = [:]
        for device in raw {
            if let existing = byUDID[device.udid] {
                if !existing.isUSB && device.isUSB { byUDID[device.udid] = device }
            } else {
                byUDID[device.udid] = device
            }
        }
        // Preserve first-seen order.
        var seen = Set<String>()
        let devices = raw.compactMap { d -> Device? in
            guard seen.insert(d.udid).inserted else { return nil }
            return byUDID[d.udid]
        }
        return (devices, cableOnly)
    }

    private static func decodeDevices(_ json: String) throws -> [Device] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([Device].self, from: data)
    }

    public func listDevicesAsync() async throws -> [Device] {
        try await Task.detached(priority: .utility) { try self.listDevices() }.value
    }

    /// Pick the target device: the one matching `udid` if given, otherwise the
    /// first that satisfies `connection`.
    public func selectDevice(udid: String?, connection: ConnectionFilter) throws -> Device {
        let devices = try listDevices()
        guard !devices.isEmpty else {
            throw SpoofError("no paired iOS devices found. Connect an iPhone and trust this computer.")
        }
        if let udid {
            guard let match = devices.first(where: { $0.udid == udid }) else {
                let known = devices.map { "  \($0.udid)  \($0.summary)" }.joined(separator: "\n")
                throw SpoofError("no device with UDID \(udid). Known devices:\n\(known)")
            }
            return match
        }
        let filtered = devices.filter { connection.matches($0) }
        guard let chosen = filtered.first else {
            throw SpoofError("no device matches connection filter '\(connection.rawValue)'.")
        }
        return chosen
    }

    /// What `exportPairingFile` saved.
    public struct PairingExport: Sendable {
        public let url: URL
        /// Why the file has no Remote Pairing identity, or nil when it has
        /// one. Without it the file only works where the iPhone still answers
        /// lockdown through LocalDevVPN, which newer iOS versions don't.
        public let remotePairingProblem: String?

        public var worksOnEveryIOSVersion: Bool { remotePairingProblem == nil }
    }

    /// Write the iPhone's pairing file to `url`, for the SpoofRemote app on
    /// the iPhone itself to reach its own developer services (see
    /// docs/PHONE-ONLY.md).
    ///
    /// The file lets whoever holds it act as this Mac towards the iPhone:
    /// give it only to that iPhone. It's saved readable by this user only.
    ///
    /// It holds two identities (`PairingRecord` has the format):
    /// - The lockdown record. Saving it also turns on lockdown's Wi-Fi
    ///   connections, so lockdown listens on the network, which is how the app
    ///   reaches it. Newer iOS versions don't answer lockdown there
    ///   (StikDebug and SideStore moved off it for iOS 26.4).
    /// - A Remote Pairing identity, made over USB, which the app uses to open
    ///   the tunnel through remotepairingd instead. That works on every iOS
    ///   version the iPhone-only mode supports.
    ///
    /// Throws when there's no lockdown record to save. When only the Remote
    /// Pairing identity can't be made, the file is still saved and the result
    /// says why, so the caller can tell the user.
    ///
    /// The file is made in a private folder (only this user can open it) and
    /// moved to `url` once it is complete. It is never written where other
    /// users of this Mac could read it, not even for a moment.
    @discardableResult
    public func exportPairingFile(udid: String, to url: URL) throws -> PairingExport {
        let fm = FileManager.default
        _ = try? run(["lockdown", "wifi-connections", "on", "--udid", udid], timeout: 30)

        let staging = fm.temporaryDirectory.appendingPathComponent("anywhere-pairing-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let draft = staging.appendingPathComponent("pairing.plist")
        // A key to the iPhone: no other user of this Mac should read it.
        let protect = { (file: URL) in _ = try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        let noRecord = SpoofError("this Mac has no pairing record for the iPhone. Unplug it, plug it back in, tap Trust, then try again.")
        do {
            _ = try run(["lockdown", "save-pair-record", draft.path, "--udid", udid], timeout: 30)
        } catch {
            // Current pymobiledevice3 exits with an error and says no record was found.
            if "\(error)".lowercased().contains("no pairing record") { throw noRecord }
            throw error
        }
        protect(draft)
        // Older versions only log "no pairing record was found" and exit 0.
        guard let data = try? Data(contentsOf: draft), !data.isEmpty else { throw noRecord }
        guard let lockdown = try? PairingRecord(data: data), lockdown.hasLockdownRecord else {
            throw SpoofError("the pairing record pymobiledevice3 saved for the iPhone is incomplete. Unplug the iPhone, plug it back in, tap Trust, then try again.")
        }
        var problem: String?
        do {
            let record = try lockdown.settingRemotePairing(try remotePairingIdentity(udid: udid))
            try record.data.write(to: draft, options: .atomic)
            // Written as a new file, with the usual permissions again.
            protect(draft)
        } catch {
            problem = SpoofSession.firstLine(of: error)
        }

        // Only now does it leave the private folder.
        try? fm.removeItem(at: url)
        do {
            try fm.moveItem(at: draft, to: url)
        } catch {
            throw SpoofError("couldn't save the pairing file in \(url.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        protect(url)
        return PairingExport(url: url, remotePairingProblem: problem)
    }

    /// The iPhone's pairing file as data, for sending straight to the iPhone that asked for it
    /// (`POST /pairingfile`). Made by `exportPairingFile` in a folder only this user can open, which
    /// is removed again before this returns. The second value is `PairingExport.remotePairingProblem`.
    public func pairingFileData(udid: String) throws -> (data: Data, remotePairingProblem: String?) {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("anywhere-send-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }
        let file = folder.appendingPathComponent("pairing.\(PairingFileLocation.fileExtension)")
        let export = try exportPairingFile(udid: udid, to: file)
        return (try Data(contentsOf: file), export.remotePairingProblem)
    }

    /// Pairs this Mac with the iPhone's remotepairingd over USB lockdown (no
    /// Trust prompt, since USB is already trusted) and returns the identity.
    /// Re-uses pymobiledevice3's record if this Mac already paired. The work
    /// is `RemotePairingScript`, run by pymobiledevice3's own Python.
    func remotePairingIdentity(udid: String) throws -> PairingRecord.RemotePairingIdentity {
        guard let python = pythonInterpreter else {
            throw SpoofError("can't find the Python that runs pymobiledevice3")
        }
        let result: ProcessResult
        do {
            result = try ProcessRunner.run(python, arguments: ["-c", RemotePairingScript.script, udid],
                                           timeout: 60, environment: Self.childEnvironment)
        } catch {
            // The runner's own message quotes the whole command, script and all.
            throw SpoofError("pymobiledevice3's Python didn't finish (unlock the iPhone and keep it plugged in)")
        }
        switch RemotePairingScript.parse(result.stdout) {
        case .success(let identity):
            return identity
        case .failure(let reason) where result.stdout.contains(RemotePairingScript.prefix):
            throw reason
        case .failure:
            // The script died before it could say why (a crash on import, say).
            let summary = result.errorSummary
            throw SpoofError(summary.isEmpty ? "pymobiledevice3's Python stopped with status \(result.status)" : summary)
        }
    }

    /// Is a device with this UDID currently reachable?
    ///
    /// False also when the list can't be read at all. Callers that want to
    /// tell "not plugged in" from "couldn't look" use `presence`.
    public func isPresent(udid: String, connection: ConnectionFilter = .any) -> Bool {
        (try? presence(udid: udid, connection: connection)) ?? false
    }

    /// Whether a device with this UDID is listed. Throws when the list can't
    /// be read, so a broken tool isn't mistaken for an unplugged iPhone.
    ///
    /// If the full listing fails, the bare list of UDIDs (`usbmux list --simple`,
    /// which never connects to a device) is tried before giving up, so one
    /// stubborn device can't hide the others.
    public func presence(udid: String, connection: ConnectionFilter = .any) throws -> Bool {
        try find(udid: udid, connection: connection) != nil
    }

    /// The listed device with this UDID, with what the list says about it
    /// (its iOS version, for one). Nil when it isn't listed. When only the bare
    /// list of UDIDs can be read, the device is returned with no details.
    public func find(udid: String, connection: ConnectionFilter = .any) throws -> Device? {
        let read: (devices: [Device], cableOnly: Bool)
        do {
            read = try readDevices()
        } catch let original {
            do { return try listedByUDIDOnly(udid, connection: connection) } catch { throw original }
        }
        if let match = read.devices.first(where: { $0.udid == udid && connection.matches($0) }) { return match }
        // The full list failed and the cable-only one doesn't have it. A phone that
        // is only on Wi-Fi would be missing from that, so look at the bare list too.
        if read.cableOnly, connection != .usb, let bare = try? listedByUDIDOnly(udid, connection: connection) {
            return bare
        }
        return nil
    }

    /// Looks for `udid` in `usbmux list --simple`, which never connects to a
    /// device. Nothing but the UDID is known about what it finds.
    private func listedByUDIDOnly(_ udid: String, connection: ConnectionFilter) throws -> Device? {
        var flags: [String] = []
        switch connection {
        case .any: break
        case .usb: flags = ["--usb"]
        case .network: flags = ["--network"]
        }
        let output = try run(["usbmux", "list", "--simple"] + flags, timeout: 15)
        guard let udids = Self.simpleUDIDs(output) else {
            throw SpoofError("couldn't read the list of devices")
        }
        guard udids.contains(udid) else { return nil }
        return Device(deviceName: "iOS device", identifier: udid, connectionType: connection == .network ? "Network" : "USB",
                      productType: "unknown", productVersion: "0")
    }

    /// The UDIDs in `usbmux list --simple`: a JSON array of strings (or of
    /// objects with an `Identifier` or `SerialNumber`).
    static func simpleUDIDs(_ output: String) -> [String]? {
        guard let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        return array.compactMap { item in
            if let udid = item as? String { return udid }
            if let object = item as? [String: Any] {
                return (object["Identifier"] ?? object["SerialNumber"]) as? String
            }
            return nil
        }
    }

    /// The version of SpoofRemote (`com.iosgpsspoof.remote`) installed on the
    /// iPhone, or nil when it isn't installed. The Mac compares it with
    /// `SpoofRemote.expected` to warn when the iPhone app is out of date (see
    /// docs/PHONE-ONLY.md).
    ///
    /// It reads `apps list`, whose JSON is keyed by bundle id and the same on
    /// every pymobiledevice3 version the project supports. That goes through
    /// the lockdown installation-proxy service, so it works whenever the
    /// iPhone is plugged in and trusted, with no developer tunnel.
    ///
    /// Throws when the list can't be read, or an installed SpoofRemote reports
    /// no version: the caller stays quiet and logs it. Not installed is nil,
    /// not an error.
    public func installedSpoofRemoteVersion(udid: String) throws -> SpoofRemoteVersion? {
        let json = try run(["apps", "list", "--udid", udid], timeout: 30)
        guard let data = json.data(using: .utf8),
              let apps = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SpoofError("couldn't read the installed-apps list from the iPhone")
        }
        guard let app = apps[SpoofRemote.bundleID] as? [String: Any] else {
            return nil  // AnyWhere isn't installed: nothing to say.
        }
        let short = Self.appInfoString(app["CFBundleShortVersionString"])
        let build = Self.appInfoString(app["CFBundleVersion"])
        guard !short.isEmpty || !build.isEmpty else {
            throw SpoofError("SpoofRemote is installed but reports no version")
        }
        return SpoofRemoteVersion(marketing: short, build: build)
    }

    /// A value from the apps plist as a string (usually a String, sometimes a
    /// number).
    private static func appInfoString(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
}
