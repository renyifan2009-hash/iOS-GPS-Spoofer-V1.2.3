import Foundation
import RemoteAPI
import SpooferCore

/// Runs the location for the remote server with no UI: what
/// `iosgpsspoof serve` uses. It reuses SpooferCore's session unchanged:
///
/// - start → `Pymobiledevice3.selectDevice(udid:connection:)`, then
///   `SpoofSession(pmd:device:transport:engine:python:callbackQueue:)` and
///   `SpoofSession.start(at:)`
/// - move  → `SpoofSession.move(to:)` (a single message with the live engine)
/// - stop  → `SpoofSession.stop()` (restores the real location)
///
/// `SpoofSession` already waits for an iPhone that went away and re-opens the
/// channel when it returns. On top of that, this restarts a session that gave
/// up (`.failed`) for as long as the iPhone still wants the location held,
/// and keeps the Mac from idle-sleeping meanwhile.
public final class SessionRemoteController: RemoteController, @unchecked Sendable {
    public struct Options: Sendable {
        public var udid: String?
        public var connection: ConnectionFilter
        public var transport: Transport
        public var engine: EngineKind
        public var retryAfterFailure: TimeInterval
        public var serverName: String
        /// Where a route on roads gets its traffic lights, signs and speed limits (OpenStreetMap). nil: none,
        /// so sharp turns stand in for junctions and only Apple Maps' speeds count.
        public var roadData: OverpassLoader?

        public init(udid: String? = nil, connection: ConnectionFilter = .any, transport: Transport = .automatic,
                    engine: EngineKind = .classic, retryAfterFailure: TimeInterval = 15,
                    serverName: String = BonjourService.computerName,
                    roadData: OverpassLoader? = nil) {
            self.udid = udid
            self.connection = connection
            self.transport = transport
            self.engine = engine
            self.retryAfterFailure = retryAfterFailure
            self.serverName = serverName
            self.roadData = roadData
        }

        /// The public Overpass servers, with the Mac app's cache: what `iosgpsspoof serve` uses. A route
        /// waits this long at most for them before it sets off; a busy server (they answer 502 when full)
        /// costs it no more than that.
        public static var defaultRoadData: OverpassLoader { OverpassLoader(
            userAgent: "AnyWhere-serve (+https://github.com/renyifan2009-hash/iOS-GPS-Spoofer-V1.2.3)",
            cacheDirectory: AppSupport.directory.appendingPathComponent("osm-cache", isDirectory: true),
            timeBudget: 20) }
    }

    public var onLog: (@Sendable (LogLevel, String) -> Void)?

    private let pmd: Pymobiledevice3
    private let options: Options
    private let queue = DispatchQueue(label: "SessionRemoteController", qos: .userInitiated)
    private let monitorQueue = DispatchQueue(label: "SessionRemoteController.monitor", qos: .utility)

    // Confined to `queue`.
    private var session: SpoofSession?
    private var state: SessionState = .idle
    private var engine: EngineKind?
    private var device: Device?
    private var deviceConnected = false
    private var target: LocationRequest?
    private var route: RouteRunner?
    private var routeStartedAt: Date?
    private var routeTimer: DispatchSourceTimer?
    private var routePausedAt: Date?
    /// A route on roads waiting for its OpenStreetMap data, which a newer route or a stop cancels.
    private var routePlanning: Task<Void, Never>?
    private var routeGeneration = 0
    private var joystick: JoystickMotion?
    private var joystickPoint: GeoPoint?
    private var joystickTimer: DispatchSourceTimer?
    private var lastJoystickTick: Date?
    private var position: GeoPoint?
    private var wantsLocation = false
    private var retryScheduled = false
    private var keepAwake: NSObjectProtocol?
    private var monitor: DispatchSourceTimer?

    public init(pmd: Pymobiledevice3, options: Options) {
        self.pmd = pmd
        self.options = options
    }

    /// Check for the iPhone every few seconds, so `/status` can say whether
    /// the Mac sees it even when nothing is being simulated.
    public func startMonitoring(interval: TimeInterval = 5) {
        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.pollDevices() }
        queue.sync { monitor = timer }
        timer.resume()
    }

    /// Synchronous teardown for Ctrl-C / `launchctl` stop: restores the real
    /// location before returning.
    public func shutdown() {
        let running = queue.sync { () -> SpoofSession? in
            wantsLocation = false
            cancelRoute()
            cancelJoystick()
            monitor?.cancel()
            monitor = nil
            endKeepAwake()
            return session
        }
        running?.stopBlocking()
    }

    // MARK: - RemoteController

    public func status() async -> RemoteStatus {
        await onQueue { self.makeStatus() }
    }

    public func setLocation(_ request: LocationRequest) async throws -> RemoteStatus {
        try await onQueueThrowing {
            guard request.isValid else { throw RemoteControlError("That isn't a valid coordinate.", status: 400) }
            self.cancelRoute()   // a manual teleport ends any running route
            self.cancelJoystick()
            self.target = request
            if self.wantsLocation, let session = self.session {
                self.log(.info, "moving to \(Self.describe(request))")
                self.apply(request, to: session)
            }
            return self.makeStatus()
        }
    }

    public func start(_ request: LocationRequest?) async throws -> RemoteStatus {
        try await onQueueThrowing {
            self.cancelRoute()   // starting a plain hold ends any running route
            self.cancelJoystick()
            if let request {
                guard request.isValid else { throw RemoteControlError("That isn't a valid coordinate.", status: 400) }
                self.target = request
            }
            guard let target = self.target else {
                throw RemoteControlError("Pick a location first.", status: 400)
            }
            if self.state == .stopping {
                throw RemoteControlError("Still restoring the real location. Try again in a moment.")
            }
            if let session = self.session {
                self.wantsLocation = true
                self.beginKeepAwake()
                self.log(.info, "moving to \(Self.describe(target))")
                self.apply(target, to: session)
                return self.makeStatus()
            }
            let device = try self.chooseDevice()
            self.wantsLocation = true
            self.beginKeepAwake()
            let session = self.makeSession(device: device)
            self.session = session
            self.state = .connecting("Preparing \(device.deviceName)…")
            self.log(.info, "holding \(Self.describe(target)) on \(device.deviceName)")
            session.start(at: GeoPoint(target.latitude, target.longitude))
            return self.makeStatus()
        }
    }

    public func driveRoute(_ request: RouteRequest) async throws -> RemoteStatus {
        // On roads the iPhone sent, driving like a person: first look up their lights, signs and limits.
        let roadData = request.realistic && RoadRoute(request: request) != nil ? options.roadData : nil
        return try await onQueueThrowing {
            let runner: RouteRunner
            let path: RoutePath
            do {
                runner = try RouteRunner.build(from: request)
                path = try RouteRunner.playedPath(for: request)
            } catch {
                throw RemoteControlError((error as? LocalizedError)?.errorDescription ?? "That route isn't valid.",
                                         status: 400)
            }
            if self.state == .stopping {
                throw RemoteControlError("Still restoring the real location. Try again in a moment.")
            }
            self.cancelJoystick()
            self.cancelRoute()
            let first = runner.start
            self.target = LocationRequest(latitude: first.latitude, longitude: first.longitude, name: runner.name)
            self.wantsLocation = true
            self.beginKeepAwake()
            let roads = RoadRoute(request: request).map { " on roads (\($0.roadLegs) of \(request.legs?.count ?? 0) legs)" } ?? ""
            let note = "driving a \(request.waypoints.count)-point route\(roads)"
            if self.session == nil {
                let device = try self.chooseDevice()
                let session = self.makeSession(device: device)
                self.session = session
                self.state = .connecting("Preparing \(device.deviceName)…")
                self.log(.info, "\(note) on \(device.deviceName)")
                session.start(at: first)
            } else {
                self.log(.info, note)
                if case .active = self.state, let session = self.session { session.move(to: first) }
            }
            guard let roadData else {
                self.begin(runner)
                return self.makeStatus()
            }
            // Hold the start while the map data loads (`planning`), then set off with it, or without it if
            // the servers are busy or too slow: the plain plan above is the fallback.
            let generation = self.routeGeneration
            self.routePlanning = Task { [weak self] in
                let driving = request.travelMode == "driving"
                var features = RoadFeatures.none
                var problem: String?
                do {
                    features = try await roadData.features(along: path, roads: driving)
                } catch {
                    problem = String(describing: error)
                }
                self?.queue.async { [weak self] in
                    guard let self, self.routeGeneration == generation, self.wantsLocation else { return }
                    self.routePlanning = nil
                    var planned = runner
                    if problem == nil, let built = try? RouteRunner.build(from: request, features: features) {
                        planned = built
                        self.log(.info, Self.describe(features, length: path.length))
                    } else {
                        self.log(.warning, "couldn't load OpenStreetMap data (\(problem ?? "unreadable")), so this route "
                                 + (RouteRunner.followsLimits(request) ? "uses Apple Maps' speeds and " : "")
                                 + "guesses its traffic lights")
                    }
                    self.target = LocationRequest(latitude: planned.start.latitude, longitude: planned.start.longitude,
                                                  name: planned.name)
                    self.begin(planned)
                }
            }
            return self.makeStatus()
        }
    }

    /// Play `runner` from now. Confined to `queue`.
    private func begin(_ runner: RouteRunner) {
        route = runner
        routeStartedAt = Date()
        routePausedAt = nil
        startRouteTimer()
    }

    /// "OpenStreetMap: 3 traffic lights, 1 stop sign, speed limits for 80% of the route."
    static func describe(_ features: RoadFeatures, length: Double) -> String {
        let lights = features.uniqueCount(of: .trafficSignal)
        let signs = features.uniqueCount(of: .stopSign)
        let coverage = Int((features.speedLimitCoverage(of: length) * 100).rounded())
        var text = "OpenStreetMap: \(lights) traffic light\(lights == 1 ? "" : "s"), \(signs) stop sign\(signs == 1 ? "" : "s")"
        if coverage > 0 { text += ", speed limits for \(coverage)% of the route" }
        if !features.complete { text += " (some of it couldn't be checked)" }
        return text
    }

    public func stop() async -> RemoteStatus {
        await onQueue {
            self.wantsLocation = false
            self.cancelRoute()
            self.cancelJoystick()
            self.endKeepAwake()
            if let session = self.session, self.state != .stopping {
                self.log(.info, "stopping, restoring the real location…")
                self.state = .stopping
                session.stop()
            }
            return self.makeStatus()
        }
    }

    public func joystick(_ request: JoystickRequest) async throws -> RemoteStatus {
        try await onQueueThrowing {
            guard request.isValid else {
                throw RemoteControlError("The heading must be 0 up to 360 degrees and the speed 0 to 70 m/s.", status: 400)
            }
            guard self.wantsLocation, let session = self.session else {
                throw RemoteControlError("Start a location first, then steer with the joystick.")
            }
            guard session.canStream else {
                throw RemoteControlError("The joystick needs the live engine: every move would take a second or more here.")
            }
            let now = Date()
            if self.joystick == nil {
                // Taking over from a route or a held place: steer from where the iPhone is now.
                self.cancelRoute()
                self.joystickPoint = self.position ?? self.target.map { GeoPoint($0.latitude, $0.longitude) }
                self.lastJoystickTick = now
                self.log(.info, "joystick on")
            }
            self.joystick = JoystickMotion(request, receivedAt: now)
            self.startJoystickTimer()
            return self.makeStatus()
        }
    }

    public func setPaused(_ request: PauseRequest) async throws -> RemoteStatus {
        try await onQueueThrowing {
            guard self.route != nil else { throw RemoteControlError("No route is running.") }
            if request.paused {
                if self.routePausedAt == nil {
                    self.routePausedAt = Date()
                    self.log(.info, "route paused")
                }
            } else if let pausedAt = self.routePausedAt {
                // The clock the route plays by carries on from where it stopped.
                self.routeStartedAt = self.routeStartedAt?.addingTimeInterval(Date().timeIntervalSince(pausedAt))
                self.routePausedAt = nil
                self.log(.info, "route resumed")
            }
            return self.makeStatus()
        }
    }

    // MARK: - Session

    private func apply(_ request: LocationRequest, to session: SpoofSession) {
        let point = GeoPoint(request.latitude, request.longitude)
        if case .failed = state {
            session.start(at: point)     // gave up earlier: start over
        } else {
            session.move(to: point)
        }
    }

    // MARK: - Route

    private func startRouteTimer() {
        routeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tickRoute() }
        routeTimer = timer
        timer.resume()
    }

    /// Each second, move to where the route should be now. The point is kept as
    /// `target` too, so a dropped session reconnects to the right place.
    private func tickRoute() {
        guard let route, let startedAt = routeStartedAt, wantsLocation, routePausedAt == nil else { return }
        let (point, finished) = route.position(at: Date().timeIntervalSince(startedAt))
        target = LocationRequest(latitude: point.latitude, longitude: point.longitude, name: route.name)
        if case .active = state, let session { session.move(to: point) }
        if finished, !route.wraps {
            routeTimer?.cancel()
            routeTimer = nil
            log(.success, "route finished; holding the destination")
        }
    }

    private func cancelRoute() {
        routeGeneration += 1
        routePlanning?.cancel()
        routePlanning = nil
        routeTimer?.cancel()
        routeTimer = nil
        route = nil
        routeStartedAt = nil
        routePausedAt = nil
    }

    // MARK: - Joystick

    /// Four times a second: move the way the iPhone is steering, and let go by itself when it goes quiet.
    private func startJoystickTimer() {
        guard joystickTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.tickJoystick() }
        joystickTimer = timer
        timer.resume()
    }

    private func tickJoystick() {
        guard let joystick, wantsLocation, let session, let from = joystickPoint else {
            cancelJoystick()
            return
        }
        let now = Date()
        let dt = now.timeIntervalSince(lastJoystickTick ?? now)
        lastJoystickTick = now
        if joystick.isExpired(at: now) {
            log(.info, "joystick off (no steering for \(RemoteAPI.joystickTimeout) s)")
            cancelJoystick()
            return
        }
        guard case .active = state, joystick.effectiveSpeed(at: now) > 0 else { return }
        let next = joystick.step(from: from, dt: dt, now: now)
        joystickPoint = next
        target = LocationRequest(latitude: next.latitude, longitude: next.longitude, name: nil)
        session.move(to: next)
    }

    private func cancelJoystick() {
        joystickTimer?.cancel()
        joystickTimer = nil
        joystick = nil
        joystickPoint = nil
        lastJoystickTick = nil
    }

    private func chooseDevice() throws -> Device {
        if let found = try? pmd.selectDevice(udid: options.udid, connection: options.connection) {
            device = found
            deviceConnected = true
            return found
        }
        // Known but not connected right now: the session waits for it.
        if let device { return device }
        throw RemoteControlError("No iPhone is connected to the Mac. Connect it with a cable and tap Trust.")
    }

    private func makeSession(device: Device) -> SpoofSession {
        let python = pmd.pythonInterpreter
        let engine: EngineKind = (options.engine == .live && python != nil) ? .live : .classic
        let session = SpoofSession(pmd: pmd, device: device, transport: options.transport, engine: engine,
                                   python: engine == .live ? python : nil, callbackQueue: queue)
        let id = ObjectIdentifier(session)
        session.onStateChange = { [weak self] state in self?.sessionStateChanged(state, id: id) }
        session.onPosition = { [weak self] point in self?.positionApplied(point, id: id) }
        session.onEngineChange = { [weak self] engine in self?.engineChanged(engine, id: id) }
        session.onLog = { [weak self] level, line in self?.log(level, line) }
        self.engine = session.engine
        log(.info, "\(session.engine.label.lowercased()) engine, \(device.modelName), iOS \(device.productVersion)")
        return session
    }

    private func isCurrent(_ id: ObjectIdentifier) -> Bool {
        guard let session else { return false }
        return ObjectIdentifier(session) == id
    }

    // The session's callbacks arrive on `queue`.
    private func sessionStateChanged(_ newState: SessionState, id: ObjectIdentifier) {
        guard isCurrent(id) else { return }
        state = newState
        switch newState {
        case .idle:
            session = nil
            position = nil
            engine = nil
            if !wantsLocation {
                endKeepAwake()
                log(.success, "real location restored")
            }
        case .active:
            retryScheduled = false
        case .failed(let message):
            log(.error, message)
            scheduleRetry(id: id)
        default:
            break
        }
    }

    private func scheduleRetry(id: ObjectIdentifier) {
        guard wantsLocation, !retryScheduled else { return }
        retryScheduled = true
        let delay = options.retryAfterFailure
        log(.warning, "trying again in \(Int(delay)) s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            guard self.wantsLocation, self.isCurrent(id), case .failed = self.state,
                  let session = self.session, let target = self.target else { return }
            session.start(at: GeoPoint(target.latitude, target.longitude))
        }
    }

    private func positionApplied(_ point: GeoPoint, id: ObjectIdentifier) {
        guard isCurrent(id) else { return }
        position = point
    }

    private func engineChanged(_ newEngine: EngineKind, id: ObjectIdentifier) {
        guard isCurrent(id) else { return }
        engine = newEngine
        log(.warning, "switched to the \(newEngine.label.lowercased()) engine")
    }

    private func pollDevices() {
        let devices = (try? pmd.listDevices()) ?? []
        let match = devices.first { candidate in
            if let udid = options.udid { return candidate.udid == udid }
            return options.connection.matches(candidate)
        }
        queue.async { [self] in
            let wasConnected = deviceConnected
            deviceConnected = match != nil
            if let match { device = match }
            if wasConnected != deviceConnected {
                let name = device?.deviceName ?? "iPhone"
                log(.info, deviceConnected ? "\(name) connected" : "\(name) disconnected")
            }
        }
    }

    // MARK: - Status

    private func makeStatus() -> RemoteStatus {
        let held = position.map { LocationRequest(latitude: $0.latitude, longitude: $0.longitude) }
            ?? (wantsLocation ? target : nil)
        var placeName: String?
        if let held, let target, abs(held.latitude - target.latitude) < 1e-6,
           abs(held.longitude - target.longitude) < 1e-6 {
            placeName = target.name
        }
        let summary = device.map {
            DeviceSummary(name: $0.deviceName, model: $0.modelName, iosVersion: $0.productVersion,
                          connection: $0.isUSB ? "usb" : "network")
        }
        let spoofing = wantsLocation && session != nil
        var activity: String? = spoofing ? "hold" : nil
        var speed: Double?
        var heading: Double?
        var progress: Double?
        var paused: Bool?
        let now = Date()
        if routePlanning != nil, wantsLocation {
            activity = "planning"
        } else if spoofing, let route, let started = routeStartedAt {
            activity = "route"
            progress = route.progress(at: (routePausedAt ?? now).timeIntervalSince(started))
            paused = routePausedAt != nil
        } else if spoofing, let joystick {
            activity = "joystick"
            speed = joystick.effectiveSpeed(at: now)
            heading = joystick.heading
        }
        return RemoteStatus(connected: deviceConnected || state.isEngaged,
                            spoofing: spoofing,
                            latitude: held?.latitude, longitude: held?.longitude,
                            placeName: placeName,
                            phase: Self.phase(for: state),
                            detail: Self.detail(for: state),
                            device: summary,
                            engine: engine?.label,
                            serverName: options.serverName,
                            activity: activity, speed: speed, heading: heading,
                            routeProgress: progress, routePaused: paused, apiVersion: RemoteAPI.version)
    }

    public static func phase(for state: SessionState) -> SpoofPhase {
        switch state {
        case .idle: return .idle
        case .connecting: return .starting
        case .active, .replaying: return .active
        case .reconnecting: return .reconnecting
        case .stopping: return .stopping
        case .failed: return .failed
        }
    }

    public static func detail(for state: SessionState) -> String? {
        switch state {
        case .connecting(let text), .reconnecting(let text), .failed(let text): return text
        case .stopping: return "Restoring the real location…"
        case .idle, .active, .replaying: return nil
        }
    }

    static func describe(_ request: LocationRequest) -> String {
        let coordinate = String(format: "%.5f, %.5f", request.latitude, request.longitude)
        if let name = request.name, !name.isEmpty { return "\(name) (\(coordinate))" }
        return coordinate
    }

    // MARK: - Helpers

    private func beginKeepAwake() {
        guard keepAwake == nil else { return }
        keepAwake = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Holding a simulated iPhone location")
    }

    private func endKeepAwake() {
        guard let activity = keepAwake else { return }
        ProcessInfo.processInfo.endActivity(activity)
        keepAwake = nil
    }

    private func log(_ level: LogLevel, _ message: String) {
        onLog?(level, message)
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    private func onQueueThrowing<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
