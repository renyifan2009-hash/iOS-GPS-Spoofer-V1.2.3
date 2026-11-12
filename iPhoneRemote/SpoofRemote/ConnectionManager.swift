import Foundation
@preconcurrency import Network
import Observation
import os
import PhoneOnlyCore
import RemoteAPI
import UIKit

/// Finds the Mac over Bonjour, pairs with it, and sends it commands.
///
/// iOS has no public API that lets an app change the location the whole
/// system reports. The Mac does that through Apple's developer location
/// service (the same one Xcode uses); this app is the remote control.
@MainActor
@Observable
final class ConnectionManager {
    struct DiscoveredMac: Identifiable, Hashable, Sendable {
        let serviceName: String
        let type: String
        let domain: String
        let serverID: String?
        let displayName: String
        let addresses: [String]
        let port: UInt16?

        nonisolated var id: String { "\(serviceName).\(domain)" }
    }

    struct Server: Codable, Equatable, Sendable {
        var serverID: String
        var name: String
        var host: String
        var port: UInt16
    }

    enum Link: Equatable {
        case unpaired
        case connecting
        case online
        case offline(String)
    }

    enum ClientError: LocalizedError {
        case notPaired
        case http(Int, String)
        case message(String)

        nonisolated var errorDescription: String? {
            switch self {
            case .notPaired: return "Pair with your Mac first."
            case .http(_, let message): return message
            case .message(let message): return message
            }
        }
    }

    private(set) var discovered: [DiscoveredMac] = []
    private(set) var server: Server?
    private(set) var link: Link = .unpaired
    private(set) var status: RemoteStatus?
    private(set) var isWorking = false
    /// Asking Apple Maps for a route's roads before sending it to the Mac.
    private(set) var findingRoads = false
    var lastError: String?
    /// iOS is not letting this app look for Macs: the person said no to Local
    /// Network, or never answered. Nothing else tells them, because the
    /// search just sits there looking.
    private(set) var localNetworkBlocked = false
    /// Why the Mac dropped this iPhone's pairing (a 401), for the screens that
    /// ask to pair again. Kept until the next successful pairing, so it
    /// survives the screen's own reset of `lastError`.
    private(set) var unpairedNotice: String?

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let clientID: String
    @ObservationIgnored private var outage = OutageCounter()

    private static let serverKey = "pairedServer"
    private static let clientIDKey = "clientID"

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)

        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: Self.clientIDKey) {
            clientID = id
        } else {
            let id = UUID().uuidString
            defaults.set(id, forKey: Self.clientIDKey)
            clientID = id
        }
        if let data = defaults.data(forKey: Self.serverKey),
           let saved = try? JSONDecoder().decode(Server.self, from: data),
           KeychainStore.token(for: saved.serverID) != nil {
            server = saved
            link = .connecting
        }
    }

    var isPaired: Bool { server != nil }
    var isOnline: Bool { link == .online }
    /// A location is being held (or re-established) on the iPhone.
    var isSpoofing: Bool { status?.spoofing ?? false }

    // MARK: - Discovery

    func startBrowsing() {
        if browser != nil {
            // Stuck on Local Network: start over, since the person may have
            // just turned it on in Settings.
            guard localNetworkBlocked else { return }
            stopBrowsing()
        }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteAPI.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            // Started on the main queue below.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.discovered = results.compactMap { Self.mac(from: $0) }
                    .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                if !self.discovered.isEmpty { self.localNetworkBlocked = false }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.localNetworkBlocked = false
                case .waiting(let error):
                    // With Local Network off, iOS doesn't fail the search. It waits.
                    if Self.isLocalNetworkDenied(error) { self.localNetworkBlocked = true }
                case .failed(let error):
                    if Self.isLocalNetworkDenied(error) {
                        self.localNetworkBlocked = true
                    } else {
                        self.lastError = "Couldn't look for Macs: \(error.localizedDescription)"
                    }
                    self.browser?.cancel()
                    self.browser = nil
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        localNetworkBlocked = false
    }

    nonisolated private static func isLocalNetworkDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return MacConnectionText.isLocalNetworkDenied(dnsErrorCode: code) }
        return false
    }

    private static func mac(from result: NWBrowser.Result) -> DiscoveredMac? {
        guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case let .bonjour(record) = result.metadata { txt = record.dictionary }
        let addresses = (txt[RemoteAPI.TXTKey.addresses] ?? "")
            .split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
        return DiscoveredMac(serviceName: name, type: type, domain: domain,
                             serverID: txt[RemoteAPI.TXTKey.serverID],
                             displayName: txt[RemoteAPI.TXTKey.name] ?? name,
                             addresses: addresses,
                             port: txt[RemoteAPI.TXTKey.port].flatMap { UInt16($0) })
    }

    func isPaired(with mac: DiscoveredMac) -> Bool {
        guard let server, let id = mac.serverID else { return false }
        return server.serverID == id
    }

    /// A Bonjour service → an IPv4 address and port (falling back to the
    /// addresses the Mac lists in its TXT record).
    private func resolve(_ mac: DiscoveredMac) async -> (host: String, port: UInt16)? {
        let endpoint = NWEndpoint.service(name: mac.serviceName, type: mac.type, domain: mac.domain, interface: nil)
        if let resolved = await Self.resolveIPv4(endpoint) {
            return (resolved.0, resolved.1)
        }
        if let port = mac.port, let host = mac.addresses.first {
            return (host, port)
        }
        return nil
    }

    nonisolated private static func resolveIPv4(_ endpoint: NWEndpoint) async -> (String, UInt16)? {
        await withCheckedContinuation { (continuation: CheckedContinuation<(String, UInt16)?, Never>) in
            let parameters = NWParameters.tcp
            if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let connection = NWConnection(to: endpoint, using: parameters)
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable ((String, UInt16)?) -> Void = { result in
                let first = resumed.withLock { (done: inout Bool) -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                        finish((hostString(host), port.rawValue))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { finish(nil) }
        }
    }

    nonisolated private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return address.rawValue.map { String($0) }.joined(separator: ".")
        case .ipv6(let address):
            return "[\("\(address)".replacingOccurrences(of: "%", with: "%25"))]"
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }

    // MARK: - Pairing

    func pair(with mac: DiscoveredMac, code: String) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        lastError = nil
        guard let target = await resolve(mac) else {
            lastError = "Couldn't reach \(mac.displayName). Make sure the iPhone and the Mac are on the same network. "
                + MacConnectionText.localNetworkHint
            return false
        }
        return await pair(host: target.host, port: target.port, code: code)
    }

    func pair(host: String, port: UInt16, code: String) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        lastError = nil
        do {
            let request = PairRequest(code: code, clientName: UIDevice.current.name, clientID: clientID)
            let body = try RemoteAPI.makeEncoder().encode(request)
            let data = try await send("POST", RemoteAPI.Path.pair, body: body, host: host, port: port, authorized: false)
            let response = try RemoteAPI.makeDecoder().decode(PairResponse.self, from: data)
            guard KeychainStore.save(token: response.token, for: response.server.serverID) else {
                lastError = "Couldn't save the pairing to the Keychain."
                return false
            }
            let paired = Server(serverID: response.server.serverID, name: response.server.name, host: host, port: port)
            server = paired
            persist(paired)
            link = .connecting
            outage.reset()
            unpairedNotice = nil
            startPolling()
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    /// Tell the Mac to forget this iPhone, then forget the Mac here. Returns
    /// whether the Mac was told. When it wasn't (asleep, off the network), the
    /// pairing is gone from this iPhone all the same, and `lastError` says
    /// the Mac may still list it.
    @discardableResult
    func unpair() async -> Bool {
        var told = true
        // No more status checks meanwhile: once the Mac has forgotten this
        // iPhone, one would come back 401 and look like the Mac's doing.
        stopPolling()
        if let id = server?.serverID {
            do {
                // The Mac asleep would otherwise hold the button for the full 8 seconds.
                _ = try await send("POST", RemoteAPI.Path.unpair, timeout: 3)
            } catch {
                told = false
            }
            // Gone, or replaced, while waiting: that has already been dealt with.
            guard server?.serverID == id else { return told }
        }
        unpairedNotice = nil          // the person's own choice, nothing to explain
        forget()
        lastError = told ? nil : "Removed from this iPhone. The Mac may still list it. Remove it in Settings ▸ iPhone Remote on the Mac."
        return told
    }

    private func forget() {
        if let server { KeychainStore.delete(for: server.serverID) }
        server = nil
        status = nil
        link = .unpaired
        outage.reset()
        UserDefaults.standard.removeObject(forKey: Self.serverKey)
        stopPolling()
    }

    private func persist(_ server: Server) {
        if let data = try? JSONEncoder().encode(server) {
            UserDefaults.standard.set(data, forKey: Self.serverKey)
        }
    }

    // MARK: - Status

    func startPolling() {
        guard server != nil else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                // Faster while something is moving, so its progress and the marker stay smooth.
                let moving = ["planning", "route", "joystick"].contains(self.status?.activity ?? "")
                let delay: Duration = self.link == .online ? (moving ? .seconds(1) : .seconds(2)) : .seconds(4)
                try? await Task.sleep(for: delay)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        guard let id = server?.serverID else { return }
        do {
            let data = try await send("GET", RemoteAPI.Path.status)
            let fresh = try RemoteAPI.makeDecoder().decode(RemoteStatus.self, from: data)
            // The answer may arrive after Unpair: it is about a Mac that is gone.
            guard server?.serverID == id else { return }
            if fresh != status { status = fresh }
            if link != .online {
                link = .online
                lastError = nil
            }
            outage.reset()
        } catch ClientError.http(401, let message) {
            guard server?.serverID == id else { return }
            dropPairing(because: message)
        } catch {
            // Stopped on purpose (backgrounded, unpaired): not an outage.
            guard outage.record(OutageCounter.Outcome(error: error)) else { return }
            // Unpaired meanwhile: the Mac is no longer this app's business.
            guard server?.serverID == id else { return }
            if outage.isOffline { link = .offline(Self.describe(error)) }
            if outage.shouldLookAgain { await rediscover() }
        }
    }

    /// The Mac says it doesn't know this iPhone: forget it here, and keep
    /// the Mac's words for the screen that asks to pair again.
    private func dropPairing(because serverMessage: String) {
        unpairedNotice = MacConnectionText.unpairedNotice(fromServerMessage: serverMessage)
        lastError = nil
        forget()
    }

    /// The Mac's address changed (new DHCP lease, hotspot): find it again by
    /// its server ID.
    private func rediscover() async {
        guard let current = server,
              let mac = discovered.first(where: { $0.serverID == current.serverID }),
              let target = await resolve(mac),
              target.host != current.host || target.port != current.port,
              // Forgotten while looking: don't bring it back.
              var updated = server, updated.serverID == current.serverID else { return }
        updated.host = target.host
        updated.port = target.port
        server = updated
        persist(updated)
    }

    // MARK: - Commands

    @discardableResult
    func start(at location: LocationRequest) async -> Bool {
        await command(RemoteAPI.Path.start, location)
    }

    @discardableResult
    func move(to location: LocationRequest) async -> Bool {
        await command(RemoteAPI.Path.location, location)
    }

    @discardableResult
    func stop() async -> Bool {
        await command(RemoteAPI.Path.stop, nil)
    }

    /// The Mac speaks protocol version 3 or later: it takes a route's roads (`RouteRequest.legs`) and can
    /// drive them at their speed limits. An older one turns a request that big away, so it gets none.
    var takesRoads: Bool { (status?.apiVersion ?? 1) >= 3 }

    @discardableResult
    func driveRoute(_ request: RouteRequest) async -> Bool {
        var request = request
        if request.followRoads, request.legs == nil, takesRoads {
            // The roads this iPhone's Apple Maps finds go with the route, so the Mac drives them (and looks up
            // their limits) without finding its own; it finds any leg left out itself.
            isWorking = true
            findingRoads = true
            request.legs = await roadLegs(for: request)
            findingRoads = false
            isWorking = false
        }
        let body: Data?
        do {
            body = try RemoteAPI.makeEncoder().encode(request)
        } catch {
            lastError = Self.describe(error)
            return false
        }
        return await post(RemoteAPI.Path.route, body: body)
    }

    /// Apple Maps' roads between the stops. A leg it can't find (no road, offline, too many requests) is left
    /// nil; after two misses the rest aren't asked for, so a phone with no signal doesn't wait on each one.
    private func roadLegs(for request: RouteRequest) async -> [RoadLeg?]? {
        let stops = MacRouteLegs.stops(of: request)
        let driving = request.travelMode == "driving"
        var legs: [AppleMapsLeg?] = []
        var misses = 0
        for (a, b) in zip(stops, stops.dropFirst()) {
            guard !Task.isCancelled else { return nil }
            guard misses < 2, StandaloneRoute.distance(a, b) >= MacRouteLegs.shortLeg else {
                legs.append(nil)
                continue
            }
            do {
                legs.append(try await AppleMapsLeg.calculate(AppleMapsLeg.directions(from: a, to: b, driving: driving),
                                                             from: a, to: b))
            } catch {
                misses += 1
                legs.append(nil)
            }
        }
        return MacRouteLegs.wire(legs)
    }

    @discardableResult
    func setPaused(_ paused: Bool) async -> Bool {
        await post(RemoteAPI.Path.pause, body: try? RemoteAPI.makeEncoder().encode(PauseRequest(paused: paused)))
    }

    /// Put the real location back by itself after this many minutes; 0 turns it off.
    @discardableResult
    func setAutoStop(minutes: Int) async -> Bool {
        await post(RemoteAPI.Path.autoStop, body: try? RemoteAPI.makeEncoder().encode(AutoStopRequest(minutes: minutes)))
    }

    /// One steering message from the joystick. It goes out several times a second, so it doesn't use
    /// `isWorking` (that greys the buttons) and it leaves `lastError` alone: the joystick shows its own
    /// problem. Returns the Mac's reason when it refused or couldn't be reached, nil when it took it.
    func steer(heading: Double, speed: Double) async -> String? {
        let id = server?.serverID
        do {
            let body = try RemoteAPI.makeEncoder().encode(JoystickRequest(heading: heading, speed: speed))
            let data = try await send("POST", RemoteAPI.Path.joystick, body: body, timeout: 3)
            let fresh = try RemoteAPI.makeDecoder().decode(RemoteStatus.self, from: data)
            guard server?.serverID == id else { return nil }
            if fresh != status { status = fresh }
            return nil
        } catch ClientError.http(401, let message) {
            guard server?.serverID == id else { return nil }
            dropPairing(because: message)
            return message
        } catch ClientError.http(404, _) {
            return Self.macTooOld
        } catch ClientError.http(_, let message) {
            return message
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return nil }
            return Self.describe(error)
        }
    }

    private func command(_ path: String, _ location: LocationRequest?) async -> Bool {
        let body: Data?
        do {
            body = try location.map { try RemoteAPI.makeEncoder().encode($0) }
        } catch {
            lastError = Self.describe(error)
            return false
        }
        return await post(path, body: body)
    }

    private func post(_ path: String, body: Data?) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        let id = server?.serverID
        do {
            let data = try await send("POST", path, body: body)
            let fresh = try RemoteAPI.makeDecoder().decode(RemoteStatus.self, from: data)
            // Unpaired while waiting: the answer is about a Mac that is gone.
            // (The Mac did what was asked, so this still counts as done.)
            guard server?.serverID == id else { return true }
            status = fresh
            link = .online
            outage.reset()
            lastError = nil
            return true
        } catch ClientError.http(401, let message) {
            guard server?.serverID == id else { return false }
            dropPairing(because: message)
            return false
        } catch ClientError.http(404, _) {
            // A Mac whose AnyWhere is older than this iPhone app doesn't have the call at all.
            guard server?.serverID == id else { return false }
            lastError = Self.macTooOld
            return false
        } catch {
            // Cancelled with the screen that asked: nothing went wrong.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return false }
            guard server?.serverID == id else { return false }
            lastError = Self.describe(error)
            return false
        }
    }

    // MARK: - HTTP

    private func send(_ method: String, _ path: String, body: Data? = nil,
                      host: String? = nil, port: UInt16? = nil, authorized: Bool = true,
                      timeout: TimeInterval? = nil) async throws -> Data {
        guard let host = host ?? server?.host, let port = port ?? server?.port else {
            throw ClientError.notPaired
        }
        guard let url = URL(string: "http://\(host):\(port)\(path)") else {
            throw ClientError.message("“\(host)” isn't a valid address.")
        }
        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorized {
            guard let server, let token = KeychainStore.token(for: server.serverID) else {
                throw ClientError.notPaired
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.message("The Mac didn't answer.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? RemoteAPI.makeDecoder().decode(APIError.self, from: data))?.error
                ?? "The Mac answered with error \(http.statusCode)."
            throw ClientError.http(http.statusCode, message)
        }
        return data
    }

    /// The Mac answered "no such endpoint": its AnyWhere is older than this app.
    static let macTooOld = "This Mac's AnyWhere is too old for that. Update AnyWhere on the Mac, then try again."

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            // Local Network being off looks like a Mac that can't be reached, so say so.
            return MacConnectionText.message(forURLError: urlError.code) ?? urlError.localizedDescription
        }
        if let clientError = error as? ClientError {
            return clientError.errorDescription ?? "Something went wrong."
        }
        return error.localizedDescription
    }
}
