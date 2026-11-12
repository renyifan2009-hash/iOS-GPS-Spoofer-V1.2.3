import Foundation
@preconcurrency import Network
import RemoteAPI

/// What the server drives. `SessionRemoteController` runs a `SpoofSession`
/// headlessly (`iosgpsspoof serve`); the Mac app adapts its own model so the
/// window shows what the iPhone does.
public protocol RemoteController: AnyObject, Sendable {
    func status() async -> RemoteStatus
    /// Remember where to go; if a location is being held, move there now.
    func setLocation(_ request: LocationRequest) async throws -> RemoteStatus
    /// Start holding `request` (or the last location set), or move there if
    /// already running.
    func start(_ request: LocationRequest?) async throws -> RemoteStatus
    /// Stop and restore the iPhone's real location.
    func stop() async -> RemoteStatus
    /// Plan `request` and move the location along it until stopped.
    func driveRoute(_ request: RouteRequest) async throws -> RemoteStatus
    /// Move the held location in a direction at a speed, until the next request or until none arrives for
    /// `RemoteAPI.joystickTimeout` seconds.
    func joystick(_ request: JoystickRequest) async throws -> RemoteStatus
    /// Pause or resume the route that is being driven.
    func setPaused(_ request: PauseRequest) async throws -> RemoteStatus
    /// Put the real location back by itself after N minutes (0 turns it off).
    func setAutoStop(_ request: AutoStopRequest) async throws -> RemoteStatus
}

public extension RemoteController {
    /// Controllers that don't do these answer 501; each one overrides what it supports.
    func driveRoute(_ request: RouteRequest) async throws -> RemoteStatus {
        throw RemoteControlError("Driving a route isn't supported here yet.", status: 501)
    }

    func joystick(_ request: JoystickRequest) async throws -> RemoteStatus {
        throw RemoteControlError("The joystick isn't supported here.", status: 501)
    }

    func setPaused(_ request: PauseRequest) async throws -> RemoteStatus {
        throw RemoteControlError("Pausing isn't supported here.", status: 501)
    }

    func setAutoStop(_ request: AutoStopRequest) async throws -> RemoteStatus {
        throw RemoteControlError("Stopping by itself isn't supported here.", status: 501)
    }
}

/// A failure the iPhone shows as a message, with the HTTP status to send.
public struct RemoteControlError: Error, Sendable, CustomStringConvertible {
    public let status: Int
    public let message: String

    public init(_ message: String, status: Int = 409) {
        self.message = message
        self.status = status
    }

    public var description: String { message }
}

/// A small HTTP/1.1 + JSON server for the iPhone remote, advertised over
/// Bonjour. One request per connection; local-network peers only; every
/// command needs a token from `PairingManager`.
public final class MacRemoteServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    public let name: String
    public let port: UInt16
    public var onStateChange: (@Sendable (State) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?
    /// After each authorised command: (what happened, which iPhone).
    public var onCommand: (@Sendable (String, PairingManager.PairedClient) -> Void)?

    private let controller: RemoteController
    private let pairing: PairingManager
    private let queue = DispatchQueue(label: "MacRemoteServer", qos: .userInitiated)
    // Confined to `queue`.
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    public init(name: String = BonjourService.computerName, port: UInt16 = RemoteAPI.defaultPort,
                controller: RemoteController, pairing: PairingManager) {
        self.name = name
        self.port = port
        self.controller = controller
        self.pairing = pairing
    }

    public func start() throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw RemoteControlError("invalid port \(port)", status: 500)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters, on: endpointPort)
        listener.service = BonjourService.service(name: name, serverID: pairing.serverID, port: port)
        listener.stateUpdateHandler = { [weak self] state in self?.listenerStateChanged(state) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        queue.sync { self.listener = listener }
        onStateChange?(.starting)
        listener.start(queue: queue)
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    // MARK: - Listener

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            log("listening on port \(port) as “\(name)” (Bonjour \(RemoteAPI.serviceType))")
            onStateChange?(.ready(port: port))
        case .failed(let error):
            let message = Self.describe(error, port: port)
            log("server failed: \(message)")
            listener?.cancel()
            listener = nil
            onStateChange?(.failed(message))
        case .waiting(let error):
            log("server waiting: \(Self.describe(error, port: port))")
        case .cancelled:
            onStateChange?(.stopped)
        default:
            break
        }
    }

    private static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "port \(port) is already in use. Is another copy of the helper, or the Mac app's iPhone Remote setting, already running?"
        }
        return "\(error)"
    }

    private func accept(_ connection: NWConnection) {
        guard BonjourService.isLocalNetwork(connection.endpoint) else {
            log("refused a connection from \(connection.endpoint): not on the local network")
            connection.cancel()
            return
        }
        let client = HTTPConnection(connection: connection, queue: queue) { [weak self] request in
            guard let self else { return .json(status: 503, APIError("The server is shutting down.")) }
            return await self.handle(request)
        }
        let id = ObjectIdentifier(client)
        connections[id] = client
        client.onClose = { [weak self] in self?.connections[id] = nil }
        client.start()
    }

    // MARK: - Routing

    private static let knownPaths: Set<String> = [
        RemoteAPI.Path.info, RemoteAPI.Path.pair, RemoteAPI.Path.unpair, RemoteAPI.Path.status,
        RemoteAPI.Path.location, RemoteAPI.Path.start, RemoteAPI.Path.route, RemoteAPI.Path.stop,
        RemoteAPI.Path.joystick, RemoteAPI.Path.pause, RemoteAPI.Path.autoStop,
    ]

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let info = ServerInfo(serverID: pairing.serverID, name: name)
        switch (request.method, request.path) {
        case ("GET", RemoteAPI.Path.info):
            return .json(info)
        case ("POST", RemoteAPI.Path.pair):
            return pair(request, info: info)
        default:
            break
        }

        guard Self.knownPaths.contains(request.path) else {
            return .json(status: 404, APIError("No such endpoint: \(request.path)"))
        }
        guard let token = request.bearerToken, let client = pairing.authorize(token: token) else {
            return .json(status: 401, APIError("This iPhone isn't paired with \(name). Pair again with the code shown on the Mac."))
        }

        do {
            switch (request.method, request.path) {
            case ("GET", RemoteAPI.Path.status):
                return .json(await controller.status())
            case ("POST", RemoteAPI.Path.location):
                guard let location = try Self.location(from: request.body, required: true) else {
                    return .json(status: 400, APIError("Expected a latitude and longitude."))
                }
                let status = try await controller.setLocation(location)
                command("set the location to \(Self.describe(location))", client)
                return .json(status)
            case ("POST", RemoteAPI.Path.start):
                let location = try Self.location(from: request.body, required: false)
                let status = try await controller.start(location)
                command("started at \(location.map { Self.describe($0) } ?? "the last location")", client)
                return .json(status)
            case ("POST", RemoteAPI.Path.route):
                let route = try Self.route(from: request.body)
                let status = try await controller.driveRoute(route)
                command("started a \(route.waypoints.count)-point route", client)
                return .json(status)
            case ("POST", RemoteAPI.Path.joystick):
                // No log line or toast per request: this arrives several times a second.
                let steer = try Self.body(JoystickRequest.self, from: request.body, hint: "a heading and a speed")
                guard steer.isValid else {
                    throw RemoteControlError("The heading must be 0 up to 360 degrees and the speed 0 to 70 m/s.", status: 400)
                }
                return .json(try await controller.joystick(steer))
            case ("POST", RemoteAPI.Path.pause):
                let pause = try Self.body(PauseRequest.self, from: request.body, hint: "{\"paused\": true}")
                let status = try await controller.setPaused(pause)
                command(pause.paused ? "paused the route" : "resumed the route", client)
                return .json(status)
            case ("POST", RemoteAPI.Path.autoStop):
                let stop = try Self.body(AutoStopRequest.self, from: request.body, hint: "{\"minutes\": 30}")
                guard stop.isValid else {
                    throw RemoteControlError("Minutes must be 0 (off) to \(RemoteAPI.maxAutoStopMinutes).", status: 400)
                }
                let status = try await controller.setAutoStop(stop)
                command(stop.minutes > 0 ? "set Auto-stop to \(stop.minutes) minutes" : "turned Auto-stop off", client)
                return .json(status)
            case ("POST", RemoteAPI.Path.stop):
                let status = await controller.stop()
                command("stopped and restored the real location", client)
                return .json(status)
            case ("POST", RemoteAPI.Path.unpair):
                pairing.revoke(token: token)
                command("unpaired", client)
                return .json(await controller.status())
            default:
                return .json(status: 405, APIError("\(request.method) isn't allowed on \(request.path)."))
            }
        } catch let error as RemoteControlError {
            return .json(status: error.status, APIError(error.message))
        } catch {
            return .json(status: 500, APIError("\(error)"))
        }
    }

    private func pair(_ request: HTTPRequest, info: ServerInfo) -> HTTPResponse {
        guard let body = try? RemoteAPI.makeDecoder().decode(PairRequest.self, from: request.body) else {
            return .json(status: 400, APIError("Expected a pairing code."))
        }
        do {
            let token = try pairing.pair(code: body.code, clientName: body.clientName, clientID: body.clientID)
            log("paired with “\(body.clientName)”")
            return .json(PairResponse(token: token, server: info))
        } catch let error as PairingManager.PairingError {
            switch error {
            case .wrongCode:
                log("rejected a wrong pairing code from “\(body.clientName)”")
                return .json(status: 403, APIError(error.description))
            case .lockedOut:
                return .json(status: 429, APIError(error.description))
            }
        } catch {
            return .json(status: 500, APIError("\(error)"))
        }
    }

    static func location(from body: Data, required: Bool) throws -> LocationRequest? {
        let isBlank = body.allSatisfy { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        if isBlank {
            if required { throw RemoteControlError("Expected a latitude and longitude.", status: 400) }
            return nil
        }
        guard let location = try? RemoteAPI.makeDecoder().decode(LocationRequest.self, from: body) else {
            throw RemoteControlError("Expected {\"latitude\": …, \"longitude\": …}.", status: 400)
        }
        guard location.isValid else {
            throw RemoteControlError("Latitude must be between −90 and 90 and longitude between −180 and 180.", status: 400)
        }
        return location
    }

    /// A JSON body of type `T`, or a 400 that says what was expected.
    static func body<T: Decodable>(_ type: T.Type, from body: Data, hint: String) throws -> T {
        guard let value = try? RemoteAPI.makeDecoder().decode(T.self, from: body) else {
            throw RemoteControlError("Expected \(hint).", status: 400)
        }
        return value
    }

    static func route(from body: Data) throws -> RouteRequest {
        guard let route = try? RemoteAPI.makeDecoder().decode(RouteRequest.self, from: body) else {
            throw RemoteControlError("Expected a route with waypoints.", status: 400)
        }
        guard route.isValid else {
            throw RemoteControlError("A route needs two or more valid points, a known mode, and a positive speed.",
                                     status: 400)
        }
        return route
    }

    static func describe(_ location: LocationRequest) -> String {
        let coordinate = String(format: "%.5f, %.5f", location.latitude, location.longitude)
        if let name = location.name, !name.isEmpty { return "\(name) (\(coordinate))" }
        return coordinate
    }

    private func command(_ what: String, _ client: PairingManager.PairedClient) {
        log("\(client.name): \(what)")
        onCommand?(what, client)
    }

    private func log(_ line: String) {
        onLog?(line)
    }
}

// MARK: - HTTP

/// The parts of an HTTP/1.1 request the API needs.
struct HTTPRequest: Sendable, Equatable {
    var method: String
    var path: String
    /// Lower-cased header names.
    var headers: [String: String]
    var body: Data

    enum ParseResult: Equatable {
        case incomplete
        case complete(HTTPRequest)
        case invalid(status: Int, message: String)
    }

    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 64 * 1024

    /// A route can carry its roads, so it may be bigger than any other call.
    static func maxBodyBytes(for path: String) -> Int {
        path == RemoteAPI.Path.route ? RemoteAPI.maxRouteBodyBytes : maxBodyBytes
    }

    var bearerToken: String? {
        guard let value = headers["authorization"] else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .invalid(status: 431, message: "Headers too large.") : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400, message: "Malformed request.")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .invalid(status: 400, message: "Malformed request line.")
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .invalid(status: 400, message: "Malformed header.")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil {
            return .invalid(status: 501, message: "Chunked request bodies aren't supported.")
        }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else {
            return .invalid(status: 400, message: "Bad Content-Length.")
        }
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? target
        guard length <= maxBodyBytes(for: path) else {
            return .invalid(status: 413, message: "Request too large.")
        }
        let bodyStart = headerEnd.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }
        let body = Data(data[bodyStart..<(bodyStart + length)])
        return .complete(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path,
                                     headers: headers, body: body))
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var body: Data

    static func json<T: Encodable>(status: Int = 200, _ value: T) -> HTTPResponse {
        let body = (try? RemoteAPI.makeEncoder().encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: body)
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status \(status)"
        }
    }
}

/// One accepted connection: read a request, answer it, close. Everything
/// runs on the server's queue except the handler, which is async.
final class HTTPConnection: @unchecked Sendable {
    /// Called on the server's queue once the connection is gone.
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private var buffer = Data()
    private var responded = false
    private var closed = false

    /// Slow or stalled clients are dropped after this long. Generous, since
    /// a first start lists devices (which can take a while) before answering.
    static let timeout: TimeInterval = 45

    init(connection: NWConnection, queue: DispatchQueue,
         handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
        queue.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in self?.close() }
    }

    func cancel() {
        close()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed, !self.responded else { return }
            if let data { self.buffer.append(data) }
            switch HTTPRequest.parse(self.buffer) {
            case .complete(let request):
                self.respond(to: request)
            case .invalid(let status, let message):
                self.send(.json(status: status, APIError(message)))
            case .incomplete:
                if error != nil || isComplete {
                    self.close()
                } else {
                    self.receive()
                }
            }
        }
    }

    private func respond(to request: HTTPRequest) {
        responded = true
        let handler = self.handler
        Task { [weak self] in
            let response = await handler(request)
            self?.queue.async { [weak self] in self?.send(response) }
        }
    }

    private func send(_ response: HTTPResponse) {
        guard !closed else { return }
        responded = true
        connection.send(content: response.serialized(), completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
        onClose = nil
    }
}
