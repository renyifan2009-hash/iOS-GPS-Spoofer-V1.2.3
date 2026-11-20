import Darwin
import Foundation
import IDevice
import Observation
import UIKit
import UserNotifications

/// Makes a pairing file on this iPhone, with no computer, on iOS 27 and later.
///
/// iOS 27 can pair with a host it finds on the network: Settings ▸ Privacy & Security ▸ Developer Mode
/// lists hosts that advertise `_remotepairing-pairable-host._tcp`, and "Pair with AnyWhere" connects to
/// one, then asks for the code the host shows. AnyWhere is that host here: it makes a fresh Remote
/// Pairing identity with idevice (`pairable_host_prepare`), listens on a port, advertises it with
/// Bonjour, and runs pair-setup on the connection the iPhone opens (`pairable_host_accept_fd`). The
/// result is an identity the iPhone trusts, kept as this app's pairing file. StikDebug added the same
/// flow in October 2026.
///
/// A fresh identity each time, under its own name, so nothing else pairing with the iPhone can replace
/// it, which is what made pairing files saved from a Mac go stale.
@MainActor
@Observable
final class PhonePairing {
    enum State: Equatable {
        case idle
        /// Advertising; waiting for Settings to connect.
        case waiting
        /// The code to type in Settings.
        case code(String)
        case finishing
        case done
        case failed(String)
    }

    private(set) var state: State = .idle

    /// The name Settings shows: "Pair with AnyWhere".
    nonisolated static let hostName = "AnyWhere"

    /// iOS 27 brought pairing with a host from Settings.
    static var isAvailable: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }

    @ObservationIgnored private var onPaired: (URL) -> Bool = { _ in false }
    @ObservationIgnored private var service: NetService?
    @ObservationIgnored private let keepAlive = KeepAlive()
    @ObservationIgnored private let socket = PairingSocket()
    /// Which run the callbacks belong to: a cancelled run's late answers are ignored.
    @ObservationIgnored private var run = 0

    var isRunning: Bool {
        switch state {
        case .waiting, .code, .finishing: true
        case .idle, .done, .failed: false
        }
    }

    /// `onPaired` stores the new pairing file (the same path as opening one from Files) and says whether
    /// it took it.
    func start(onPaired: @escaping (URL) -> Bool) {
        guard !isRunning else { return }
        self.onPaired = onPaired
        run += 1
        let thisRun = run
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let host: PairableHostIdentity
        do {
            host = try PairableHostIdentity(name: Self.hostName)
        } catch {
            state = .failed("Couldn't make a pairing identity: \(error.localizedDescription)")
            return
        }
        let port: UInt16
        do {
            port = try socket.listen()
        } catch {
            state = .failed("Couldn't open a port to pair on: \(error.localizedDescription)")
            return
        }
        let service = NetService(domain: "", type: "_remotepairing-pairable-host._tcp.", name: host.serviceID,
                                 port: Int32(port))
        service.setTXTRecord(NetService.data(fromTXTRecord: host.txtRecord))
        service.publish()
        self.service = service
        // Settings is in front while pairing runs: stay awake (the same way a held location does).
        keepAlive.start()
        state = .waiting

        let socket = self.socket
        let context = PinContext { [weak self] pin in
            Task { @MainActor in self?.show(pin: pin, run: thisRun) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> Data in
                let connection = try socket.acceptOne()
                Task { @MainActor [weak self] in
                    guard let self, self.run == thisRun, self.state == .waiting else { return }
                    self.state = .finishing
                }
                return try host.pair(onConnection: connection, context: context)
            }
            Task { @MainActor [weak self] in self?.finish(result, run: thisRun) }
        }
    }

    func cancel() {
        guard isRunning else { return }
        run += 1
        tearDown()
        state = .idle
    }

    func reset() {
        if !isRunning { state = .idle }
    }

    private func show(pin: String, run thisRun: Int) {
        guard run == thisRun, isRunning else { return }
        state = .code(pin)
        let content = UNMutableNotificationContent()
        content.title = "AnyWhere pairing code"
        content.body = "Enter \(pin) in Settings to finish pairing."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pairing-code", content: content,
                                                                     trigger: nil))
    }

    private func finish(_ result: Result<Data, Error>, run thisRun: Int) {
        guard run == thisRun else { return }
        tearDown()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["pairing-code"])
        switch result {
        case .success(let data):
            let file = FileManager.default.temporaryDirectory.appending(path: "Paired on this iPhone.plist")
            do {
                try data.write(to: file, options: .completeFileProtection)
            } catch {
                state = .failed("Couldn't keep the pairing file: \(error.localizedDescription)")
                return
            }
            defer { try? FileManager.default.removeItem(at: file) }
            state = onPaired(file) ? .done : .failed("The pairing worked, but AnyWhere couldn't keep the file. Try again.")
        case .failure(let error):
            state = .failed(Self.explain(error))
        }
    }

    private func tearDown() {
        service?.stop()
        service = nil
        socket.close()
        keepAlive.stop()
    }

    /// Plain words first; idevice's own after, for a bug report.
    nonisolated static func explain(_ error: Error) -> String {
        let raw = (error as? PairableHostIdentity.Failure)?.message ?? error.localizedDescription
        let text = raw.lowercased()
        if text.contains("cancelled") { return "Pairing was cancelled." }
        if ["eof", "reset", "broken pipe", "brokenpipe"].contains(where: text.contains) {
            return "The connection closed before pairing finished. Tap Try Again, then tap Pair with \(hostName) "
                + "in Settings again and type the new code. (\(raw))"
        }
        return raw
    }
}

/// The PIN callback's context: idevice calls it from its own thread while pair-setup runs.
final class PinContext: @unchecked Sendable {
    let show: @Sendable (String) -> Void
    init(_ show: @escaping @Sendable (String) -> Void) { self.show = show }
}

/// A host identity from idevice, and pair-setup with it. Not tied to the main actor: pairing blocks.
final class PairableHostIdentity: @unchecked Sendable {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let serviceID: String
    let txtRecord: [String: Data]
    private let handle: OpaquePointer

    init(name: String) throws {
        var handle: OpaquePointer?
        var serviceID: UnsafeMutablePointer<CChar>?
        var txt: UnsafeMutablePointer<UInt8>?
        var txtLength: UInt = 0
        let error = name.withCString { cName in
            pairable_host_prepare(cName, nil, false, &handle, &serviceID, &txt, &txtLength, nil)
        }
        if let error { throw Failure(message: Self.text(of: error)) }
        guard let handle, let serviceID, let txt else {
            pairable_host_free(handle)
            if let serviceID { idevice_string_free(serviceID) }
            if let txt { idevice_data_free(txt, txtLength) }
            throw Failure(message: "idevice gave no pairing identity.")
        }
        self.handle = handle
        self.serviceID = String(cString: serviceID)
        idevice_string_free(serviceID)
        let txtData = Data(bytes: txt, count: Int(txtLength))
        idevice_data_free(txt, txtLength)
        txtRecord = Self.txtRecord(fromPlist: txtData)
    }

    deinit { pairable_host_free(handle) }

    /// idevice gives the TXT records as an XML plist dictionary; Bonjour wants bytes per key.
    static func txtRecord(fromPlist data: Data) -> [String: Data] {
        guard let dictionary = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return [:]
        }
        var records: [String: Data] = [:]
        for (key, value) in dictionary {
            switch value {
            case let value as String: records[key] = Data(value.utf8)
            case let value as Data: records[key] = value
            case let value as NSNumber: records[key] = Data(value.stringValue.utf8)
            default: break
            }
        }
        return records
    }

    /// Pair-setup on the iPhone's connection. Blocks until it's done; the code goes to `context`.
    /// Returns the new pairing file's bytes. idevice works on its own copy of `fd`; the caller closes it.
    func pair(onConnection fd: Int32, context: PinContext) throws -> Data {
        var peer: UnsafeMutablePointer<RpPairingPeerDeviceC>?
        var file: OpaquePointer?
        let unmanaged = Unmanaged.passRetained(context)
        defer { unmanaged.release() }
        let error = pairable_host_accept_fd(handle, fd, { pin, context in
            guard let pin, let context else { return }
            Unmanaged<PinContext>.fromOpaque(context).takeUnretainedValue().show(String(cString: pin))
        }, unmanaged.toOpaque(), &peer, &file)
        if let peer { rppairing_peer_device_free(peer) }
        if let error { throw Failure(message: Self.text(of: error)) }
        guard let file else { throw Failure(message: "idevice gave no pairing file.") }
        defer { rp_pairing_file_free(file) }
        var bytes: UnsafeMutablePointer<UInt8>?
        var length: UInt = 0
        if let error = rp_pairing_file_to_bytes(file, &bytes, &length) { throw Failure(message: Self.text(of: error)) }
        guard let bytes else { throw Failure(message: "idevice gave an empty pairing file.") }
        defer { idevice_data_free(bytes, length) }
        return Data(bytes: bytes, count: Int(length))
    }

    private static func text(of error: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        defer { idevice_error_free(error) }
        let message = error.pointee.message.map { String(cString: $0) } ?? "unknown error"
        return "Pairing didn't work (\(error.pointee.code)): \(message)"
    }
}

/// The port the iPhone connects to. `close()` from another thread ends a waiting `acceptOne()`.
final class PairingSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var connection: Int32 = -1

    /// Opens a listening socket on a free port and returns the port.
    func listen() throws -> UInt16 {
        close()
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        var bound4 = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound4) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        lock.withLock { listener = fd }
        return UInt16(bigEndian: bound4.sin_port)
    }

    /// Waits for the iPhone to connect. Throws once `close()` is called.
    func acceptOne() throws -> Int32 {
        let fd = lock.withLock { listener }
        guard fd >= 0 else { throw PairableHostIdentity.Failure(message: "Pairing was cancelled.") }
        let connection = Darwin.accept(fd, nil, nil)
        guard connection >= 0 else { throw PairableHostIdentity.Failure(message: "Pairing was cancelled.") }
        lock.withLock { self.connection = connection }
        return connection
    }

    /// Stops listening, and cuts a pairing that's under way (its reads then fail).
    func close() {
        let (listener, connection) = lock.withLock { () -> (Int32, Int32) in
            defer { self.listener = -1; self.connection = -1 }
            return (self.listener, self.connection)
        }
        if listener >= 0 {
            Darwin.shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
        }
        // Shutting the socket down also ends idevice's copy of it, so a pairing under way stops.
        if connection >= 0 {
            Darwin.shutdown(connection, SHUT_RDWR)
            Darwin.close(connection)
        }
    }
}
