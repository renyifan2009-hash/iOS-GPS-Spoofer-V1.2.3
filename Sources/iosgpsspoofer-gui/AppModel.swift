import AppKit
import CoreLocation
import Foundation
import Observation
import SpooferCore
import SpooferRemote

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let text: String
}

struct Waypoint: Identifiable, Equatable, Codable {
    var id = UUID()
    var point: GeoPoint
    /// Seconds to wait here before carrying on (realistic trips).
    var wait: TimeInterval = 0

    init(point: GeoPoint, wait: TimeInterval = 0) {
        self.point = point
        self.wait = wait
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        point = try c.decode(GeoPoint.self, forKey: .point)
        wait = (try? c.decodeIfPresent(TimeInterval.self, forKey: .wait)) ?? 0
    }
}

/// A one-shot request for the map to move its camera.
struct MapFocusRequest: Equatable {
    enum Kind: Equatable {
        case point(GeoPoint, zoomIn: Bool)
        case fit([GeoPoint])
    }
    let id = UUID()
    let kind: Kind
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Mode: String, CaseIterable, Identifiable {
        case teleport, route, joystick
        var id: String { rawValue }
        var label: String {
            switch self {
            case .teleport: return "Teleport"
            case .route: return "Route"
            case .joystick: return "Joystick"
            }
        }
        var symbolName: String {
            switch self {
            case .teleport: return "mappin.and.ellipse"
            case .route: return "point.topleft.down.to.point.bottomright.curvepath"
            case .joystick: return "gamecontroller"
            }
        }
    }

    /// What the device is doing in the current session.
    enum Activity: Equatable { case none, holding, routing, joystick }

    enum EngineStatus: Equatable {
        case checking
        case live(version: String)
        case classicOnly(reason: String)
    }

    enum DirectionsState: Equatable {
        case idle, computing
        case partial(failedLegs: Int, reason: DirectionsService.Failure)
    }

    enum RoutePacing: String, CaseIterable, Identifiable {
        case speed, time
        var id: String { rawValue }
        var label: String { self == .speed ? "Speed" : "Duration" }
    }

    // MARK: Tooling
    var pmd: Pymobiledevice3?
    var setupError: String?
    var pymobiledevice3Version: String?
    var engineStatus: EngineStatus = .checking
    @ObservationIgnored var probeTask: Task<LiveHelper.Availability, Never>?

    // MARK: Devices
    var devices: [Device] = []
    var selectedUDID: String?
    var isRefreshing = false
    var hasRefreshedOnce = false
    /// Set when the helper has failed to list iPhones several scans in a row (first line of the error).
    var deviceListError: String?
    @ObservationIgnored var deviceListHealth = DeviceListHealth()

    // MARK: Mode & teleport target
    var mode: Mode = .teleport {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: StateKey.mode)
            fitMap()
        }
    }
    var latitudeText = "37.334900" { didSet { if latitudeText != oldValue { targetTextChanged() } } }
    var longitudeText = "-122.009000" { didSet { if longitudeText != oldValue { targetTextChanged() } } }
    /// Reverse-geocoded name of the target.
    var placeName: String?
    /// Name supplied by a search / favorite (wins over `placeName`).
    var targetName: String?

    // MARK: Session
    var session: SpoofSession?
    var sessionState: SessionState = .idle
    var sessionEngine: EngineKind?
    var activity: Activity = .none
    var isStarting = false
    @ObservationIgnored var startCancelled = false
    var devicePosition: GeoPoint?
    var deviceHeading: Double?
    /// Current movement speed, m/s.
    var deviceSpeed: Double = 0
    var devicePlaceName: String?
    var sessionStartedAt: Date?
    /// When Auto-stop will put the real location back; nil when it is off.
    var killswitchDeadline: Date?
    @ObservationIgnored var killswitchTask: Task<Void, Never>?

    // MARK: Route
    var waypoints: [Waypoint] = [] {
        didSet {
            guard waypoints != oldValue else { return }
            // Only the waits changed: the roads stay the same.
            if waypoints.map(\.point) == oldValue.map(\.point) { waitsChanged() } else { routeInputsChanged() }
        }
    }
    var followRoads = false { didSet { if followRoads != oldValue { routeInputsChanged() } } }
    var travelMode: TravelMode = .walking { didSet { if travelMode != oldValue { routeInputsChanged() } } }
    var loopMode: LoopMode = .once {
        didSet {
            guard loopMode != oldValue else { return }
            // A loop on roads also needs the road back to the start.
            if followRoads { routeInputsChanged() } else { saveRouteDraft() }
        }
    }
    var pacing: RoutePacing = .speed { didSet { saveRouteDraft() } }
    /// m/s, when pacing by speed.
    var routeSpeed: Double = 1.4 { didSet { saveRouteDraft() } }
    /// Seconds for one pass, when pacing by duration.
    var routeDuration: TimeInterval = 600 { didSet { saveRouteDraft() } }
    /// Name of the route being edited (from the library or an imported file).
    var routeName: String?
    /// Library entry the route was loaded from, so "Save" updates it.
    var savedRouteID: UUID?
    /// The polyline actually followed: straight lines or road-following legs.
    var routeGeometry: [GeoPoint] = []
    /// For a loop with Follow roads on: the roads from the last stop back to
    /// the start. Without it, a loop closes with a straight line.
    var closingLeg: [GeoPoint]?
    var directionsState: DirectionsState = .idle
    var playback: RoutePlayback? {
        didSet {
            // The route ended (stopped, teleported, joystick): so did its trip.
            if playback == nil, trip != nil || replayTrack != nil || tripStatus != .moving {
                trip = nil
                replayTrack = nil
                tripStatus = .moving
            }
        }
    }
    var isPaused = false
    @ObservationIgnored var playbackSignature: String?
    @ObservationIgnored var replayStartedAt: Date?
    @ObservationIgnored var replaySpeed: Double = 1.4
    /// The classic engine's realistic track: where it is at each moment.
    @ObservationIgnored var replayTrack: [RoutePoint]?
    @ObservationIgnored var announcedArrival = false

    // MARK: Realistic trips
    /// Traffic lights, signs and speed limits along the route (OpenStreetMap).
    var roadFeatures: RoadFeatures = .none
    var roadDataState: RoadDataState = .off
    /// The path `roadFeatures` belongs to: its distances only fit that path.
    @ObservationIgnored var roadDataPathKey: String?
    /// Whether the loaded map data includes the roads (speed limits, for driving).
    @ObservationIgnored var roadDataHasRoads = false
    @ObservationIgnored var roadDataTask: Task<Void, Never>?
    @ObservationIgnored var pendingRoadDataKey: String?
    /// Automatic retries left for the current route's map data.
    @ObservationIgnored var roadDataRetries = 0
    /// Moves a playing route when realistic trips are on.
    @ObservationIgnored var trip: TripController?
    @ObservationIgnored var tripPaceKey: String?
    var tripStatus: TripStatus = .moving
    /// The trip's arrival time, worked out once a tick (views read it often).
    @ObservationIgnored var tripETA: TimeInterval?
    @ObservationIgnored var drift = GPSDrift(size: 0)
    @ObservationIgnored var joystickSpeedNow = 0.0
    @ObservationIgnored var joystickHeadingNow = 0.0
    /// Where the joystick really is, before GPS drift is added.
    @ObservationIgnored var joystickPosition: GeoPoint?
    @ObservationIgnored var lapTimeCache: (key: String, value: TimeInterval)?

    // MARK: Driven from the iPhone (Settings ▸ iPhone Remote). See AppModel+RemoteControl.swift.
    /// "Slower in rush hour" as the iPhone asked for this route; nil = the Mac's own setting.
    @ObservationIgnored var remoteTrafficOverride: Bool?
    /// How the iPhone wants the route it sent driven: at each road's limit, with Apple Maps' speed for each
    /// leg where none is known. Only while the window's stops are still that route's (`activeRemoteRoadPlan`).
    @ObservationIgnored var remoteRoadPlan: RemoteRoadPlan?
    /// What the iPhone's joystick last asked for. Expires by itself.
    @ObservationIgnored var remoteJoystickMotion: JoystickMotion?
    /// Waiting for the roads of a route the iPhone sent, then starting it.
    @ObservationIgnored var remoteRouteTask: Task<Void, Never>?
    /// The minutes the running Auto-stop was armed with (the Mac's setting, or the iPhone's for this session).
    @ObservationIgnored var killswitchArmedMinutes = 0

    // MARK: Joystick
    /// On-screen pad deflection, x right / y up, magnitude ≤ 1.
    var padVector: CGVector = .zero
    var pressedKeys: Set<UInt16> = []
    var sprinting = false

    // MARK: Map & UI
    var mapFocus: MapFocusRequest?
    /// The map camera's heading (degrees), so the joystick's "up" is screen-up.
    var mapHeading: Double = 0
    var searchFocusRequest = 0
    var showInspector = true
    /// The map keeps the simulated position centred, like Maps' tracking
    /// mode. Dragging the map turns it off; Re-center turns it back on.
    var isFollowingDevice = true

    // MARK: Experience
    /// The transient confirmation shown over the map.
    var toast: Toast?
    @ObservationIgnored var toastTask: Task<Void, Never>?
    /// Shown once on first launch, then from Help ▸ Welcome.
    var showWelcome = false
    var showConnectionHelp = false
    /// The pairing-file assistant (File ▸ Pairing File for the iPhone App…).
    var showPairingFile = false
    var pairingFileState: PairingFileState = .idle
    /// The "connect your iPhone" card was dismissed to plan without a device.
    var connectCardDismissed = false
    /// `amfi developer-mode-status` for the selected device (nil = unknown).
    var developerModeEnabled: Bool?
    @ObservationIgnored var developerModeCheckedUDID: String?
    @ObservationIgnored var developerModeCheckedAt = Date.distantPast
    /// iPhones we've asked to show the Developer Mode switch this launch.
    @ObservationIgnored var developerModeRevealed: Set<String> = []
    /// iPhones where a session got going during this run, so Apple's developer support is loaded.
    var developerSupportReady: Set<String> = []
    /// Set when a connected iPhone runs an older SpoofRemote than this code
    /// expects. A banner then offers the releases page. Nil when it's current,
    /// not installed, or the check couldn't run (see docs/PHONE-ONLY.md).
    var oldSpoofRemote: OldSpoofRemote?
    /// The iPhone whose SpoofRemote we've already checked, so we check once per
    /// device rather than on every refresh.
    @ObservationIgnored var spoofRemoteCheckedUDID: String?
    /// Toast to show once the device confirms the next position.
    @ObservationIgnored var pendingToast: Toast?

    // MARK: Log
    var log: [LogEntry] = []

    // MARK: Internals
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored var motionTask: Task<Void, Never>?
    @ObservationIgnored var geocodeTask: Task<Void, Never>?
    @ObservationIgnored var directionsTask: Task<Void, Never>?
    @ObservationIgnored var lastTick: ContinuousClock.Instant?
    @ObservationIgnored var speedNoise = 0.0
    @ObservationIgnored var keyMonitor: Any?
    @ObservationIgnored var resignObserver: NSObjectProtocol?
    @ObservationIgnored let geocoder = CLGeocoder()
    @ObservationIgnored let deviceGeocoder = CLGeocoder()
    @ObservationIgnored var lastDeviceGeocode: (point: GeoPoint, date: Date)?
    @ObservationIgnored var didBootstrap = false
    /// Keeps the Mac from napping or idle-sleeping while a location is simulated.
    @ObservationIgnored var sessionActivity: NSObjectProtocol?
    @ObservationIgnored var restoring = false
    @ObservationIgnored var autoStart: GeoPoint?
    @ObservationIgnored var didAutoStart = false
    @ObservationIgnored var startupSweepDone = false

    enum StateKey {
        static let mode = "lastMode"
        static let target = "lastTarget"
        static let routeDraft = "routeDraft"
        static let welcomed = "hasSeenWelcome"
    }

    var prefs: Preferences { Preferences.shared }
    var library: LibraryStore { LibraryStore.shared }

    private init() {
        // Keep this trivial: it runs during the first SwiftUI body evaluation.
        // Everything else happens in `bootstrap()`.
        let env = ProcessInfo.processInfo.environment
        if let s = env["SPOOF_START"], let p = Coordinate.parsePoint(s), p.isValid { autoStart = p }
        if let udid = env["SPOOF_UDID"] { selectedUDID = udid }
        resolveTool()
    }

    /// Restore state, probe the engine, start watching devices. Idempotent.
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        restoreState()
        if let autoStart { setTarget(autoStart) }
        routeInputsChanged()
        startEngineProbe()
        startAutoRefresh()
        installKeyboardMonitor()
        scheduleGeocode()
        fitMap()
        if !UserDefaults.standard.bool(forKey: StateKey.welcomed) { showWelcome = true }
        Updater.shared.checkIfDue()
        library.reportLoadProblems()
        observeWake()
        // After the window is up: an old-named copy of the app may be left in Applications.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            AppModel.shared.offerToRemoveOldApp()
        }
    }

    /// Called from `applicationDidFinishLaunching` once stray children are reaped.
    func completeStartupSweep(reaped: Int) {
        startupSweepDone = true
        // What was holding a fake location (a classic hold, not the live helper,
        // which clears by itself) was stopped, not asked to put the real location
        // back. Say so, and put it back now.
        let holds = ChildProcessRegistry.lastSweep.holds
        if reaped > 0 {
            appendLog("Cleaned up \(reaped) leftover pymobiledevice3 process(es) from a previous run.",
                      level: holds.isEmpty ? .info : .warning)
        }
        guard !holds.isEmpty else { return }
        let toldToRestart = "Your iPhone may still show a fake location. Restart it to be sure. That always clears it."
        guard let pmd, session == nil else {
            ChildProcessRegistry.finishRestoring()
            appendLog(toldToRestart, level: .warning)
            return
        }
        appendLog("The last run ended without putting your real location back. Putting it back now…", level: .warning)
        // The detached task hops back through the shared model (as the rest of the app does) rather
        // than capturing `self`: Swift 6.1 rejects sending it into a detached closure.
        Task.detached(priority: .utility) {
            let outcome = ChildProcessRegistry.restoreLocations(of: holds, using: pmd)
            await MainActor.run {
                let model = AppModel.shared
                if outcome.failed.isEmpty {
                    model.appendLog("Your real location is back.", level: .success)
                } else {
                    for failure in outcome.failed {
                        model.appendLog("Couldn't put the real location back: \(failure.reason)", level: .error)
                    }
                    model.appendLog(toldToRestart, level: .warning)
                    model.showToast(Toast(symbol: "exclamationmark.triangle.fill",
                                         title: "Your iPhone may still be on a fake location",
                                         subtitle: "Restart it to be sure. That always clears it.", style: .warning),
                                   duration: 8)
                }
            }
        }
    }

    // MARK: - Tooling

    func resolveTool() {
        let explicit = Preferences.shared.pymobiledevice3Path
        do {
            pmd = try Pymobiledevice3.resolve(explicit: explicit.isEmpty ? nil : explicit)
            setupError = nil
        } catch {
            pmd = nil
            setupError = "\(error)"
        }
        // A different (or reinstalled) helper starts with a clean record of failed scans.
        deviceListHealth = DeviceListHealth()
        deviceListError = nil
        if didBootstrap { startEngineProbe() }
    }

    func startEngineProbe() {
        guard let pmd else {
            probeTask = nil
            engineStatus = .classicOnly(reason: "pymobiledevice3 not found")
            pymobiledevice3Version = nil
            return
        }
        engineStatus = .checking
        let task = Task.detached(priority: .utility) { () -> LiveHelper.Availability in
            LiveHelper.probe(python: pmd.pythonInterpreter)
        }
        probeTask = task
        Task { [weak self] in
            let result = await task.value
            guard let self, self.probeTask == task else { return }
            if case .checking = self.engineStatus { self.applyProbe(result) }
        }
        Task.detached(priority: .utility) {
            let version = pmd.version()
            await MainActor.run { AppModel.shared.pymobiledevice3Version = version }
        }
    }

    func applyProbe(_ availability: LiveHelper.Availability) {
        switch availability {
        case .supported(let version):
            engineStatus = .live(version: version)
            appendLog("Live engine ready (pymobiledevice3 \(version)).", level: .debug)
        case .unsupported(let reason):
            engineStatus = .classicOnly(reason: reason)
            appendLog("Live engine unavailable — using the classic engine. (\(reason))", level: .warning)
        }
    }

    /// The engine a new session should use, waiting for the probe if needed.
    func resolvedEngine() async -> EngineKind {
        if prefs.enginePreference == .classic { return .classic }
        if case .checking = engineStatus, let probeTask {
            applyProbe(await probeTask.value)
        }
        if case .live = engineStatus { return .live }
        return .classic
    }

    // MARK: - Devices

    var selectedDevice: Device? {
        devices.first { $0.udid == selectedUDID }
            ?? (session?.device.udid == selectedUDID ? session?.device : nil)
    }

    /// The device being spoofed, else the selected one.
    var activeDevice: Device? { session?.device ?? selectedDevice }

    struct SidebarDevice: Identifiable {
        let device: Device
        let connected: Bool
        var id: String { device.udid }
    }

    /// Connected devices, plus the session's device if it's currently missing.
    var sidebarDevices: [SidebarDevice] {
        var rows = devices.map { SidebarDevice(device: $0, connected: true) }
        if let d = session?.device, !devices.contains(where: { $0.udid == d.udid }) {
            rows.append(SidebarDevice(device: d, connected: false))
        }
        return rows
    }

    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = self?.prefs.autoRefreshInterval ?? 3
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func refresh() async {
        guard let pmd, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; hasRefreshedOnce = true }
        do {
            let list = try await pmd.listDevicesAsync()
            deviceListHealth.succeeded()
            if deviceListError != nil { deviceListError = nil }
            if list != devices { devices = list }
            let keepSelection = session?.device.udid == selectedUDID && selectedUDID != nil
            if !keepSelection, selectedUDID == nil || !list.contains(where: { $0.udid == selectedUDID }) {
                selectedUDID = list.first?.udid
            }
            if let udid = selectedUDID {
                if !list.contains(where: { $0.udid == udid }) {
                    // Gone (maybe restarting after turning Developer Mode on):
                    // check again when it's back.
                    developerModeCheckedUDID = nil
                    spoofRemoteCheckedUDID = nil
                    oldSpoofRemote = nil
                } else {
                    if developerModeCheckedUDID != udid
                        || (developerModeEnabled != true && session == nil
                            && Date().timeIntervalSince(developerModeCheckedAt) > 10) {
                        checkDeveloperMode()
                    }
                    // Once per connected iPhone: is its SpoofRemote out of date?
                    if spoofRemoteCheckedUDID != udid { checkSpoofRemoteVersion() }
                }
            }
            if !list.isEmpty { connectCardDismissed = false }
        } catch {
            let message = SpoofSession.firstLine(of: error)
            appendLog("Device refresh failed: \(message)", level: .debug)
            // Once is a hiccup. Twice in a row means the helper is at fault: say so, once.
            if deviceListHealth.failed(message) {
                appendLog("The helper tool can't list iPhones: \(message)", level: .warning)
            }
            if deviceListError != deviceListHealth.error { deviceListError = deviceListHealth.error }
        }

        if let autoStart, startupSweepDone, !didAutoStart, session == nil, selectedDevice != nil {
            didAutoStart = true
            teleport(to: autoStart, name: nil)
        }
    }

    // MARK: - Session lifecycle

    var hasSession: Bool { session != nil || isStarting }
    var isEngaged: Bool { sessionState.isEngaged }
    var canStream: Bool { session?.canStream ?? false }

    /// Return the running session, or create one (deciding the engine first).
    /// `requireStreaming` refuses to create a classic iOS 17+ session, which
    /// can't do real-time movement.
    func obtainSession(requireStreaming: Bool) async -> (session: SpoofSession, isNew: Bool)? {
        if let session {
            if sessionState == .stopping {
                explain(.stillRestoring)
                return nil
            }
            if requireStreaming && !session.canStream { warnStreamingUnavailable(); return nil }
            // A session that gave up has to be started again, not just moved.
            if case .failed = sessionState { return (session, true) }
            return (session, false)
        }
        guard !isStarting else { return nil }
        guard pmd != nil else {
            explain(.helperMissing)
            return nil
        }
        guard let device = selectedDevice else {
            explain(.noIphone)
            return nil
        }
        isStarting = true
        startCancelled = false
        sessionState = .connecting("Checking the live engine…")
        let engine = await resolvedEngine()
        isStarting = false
        if startCancelled {
            sessionState = .idle
            return nil
        }
        if let session { return (session, false) }
        if requireStreaming && engine == .classic && !device.isLegacy {
            sessionState = .idle
            warnStreamingUnavailable()
            return nil
        }
        guard let s = makeSession(device: device, engine: engine) else {
            sessionState = .idle
            return nil
        }
        session = s
        sessionEngine = s.engine
        sessionStartedAt = Date()
        armKillswitch()
        // Long routes run for hours: no App Nap (it would slow the motion
        // timer) and no idle sleep until the session ends. The display may
        // still sleep.
        if sessionActivity == nil {
            sessionActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Simulating the iPhone's location")
        }
        devicePosition = nil
        devicePlaceName = nil
        isFollowingDevice = prefs.followDevice
        startMotionLoop()
        let how = device.isLegacy ? "lockdown service" : prefs.transport.resolved(for: device).label
        appendLog("Starting a \(s.engine.label.lowercased())-engine session on \(device.deviceName) (\(device.modelName), iOS \(device.productVersion), \(how)).", level: .info)
        return (s, true)
    }

    /// Only the joystick moves in real time, so this is the joystick being refused.
    private func warnStreamingUnavailable() {
        explain(.needsLiveEngine)
    }

    private func makeSession(device: Device, engine: EngineKind) -> SpoofSession? {
        guard let pmd else { return nil }
        let s = SpoofSession(pmd: pmd, device: device, transport: prefs.transport, engine: engine,
                             python: engine == .live ? pmd.pythonInterpreter : nil)
        let id = ObjectIdentifier(s)
        s.onStateChange = { [weak self] state in
            MainActor.assumeIsolated { self?.sessionStateChanged(state, id: id) }
        }
        s.onLog = { [weak self] level, line in
            MainActor.assumeIsolated { self?.appendLog(line, level: level) }
        }
        s.onPosition = { [weak self] point in
            MainActor.assumeIsolated { self?.positionApplied(point, id: id) }
        }
        s.onEngineChange = { [weak self] engine in
            MainActor.assumeIsolated { self?.engineChanged(engine, id: id) }
        }
        return s
    }

    private func isCurrentSession(_ id: ObjectIdentifier) -> Bool {
        guard let session else { return false }
        return ObjectIdentifier(session) == id
    }

    private func sessionStateChanged(_ state: SessionState, id: ObjectIdentifier) {
        guard isCurrentSession(id) else { return }
        let previous = sessionState
        sessionState = state
        // A session that is up proves the iPhone has the developer support it needs.
        if state == .active || state == .replaying, let udid = session?.device.udid {
            developerSupportReady.insert(udid)
        }
        switch state {
        case .idle:
            let restored = session?.restoredOnLastStop ?? false
            endSession()
            if previous == .stopping {
                if restored {
                    showToast(Toast(symbol: "location.slash.fill", title: "Real location restored",
                                    subtitle: "Your iPhone is back to its actual GPS.", style: .info))
                } else {
                    showToast(Toast(symbol: "exclamationmark.triangle.fill", title: "Couldn't confirm the real location is back",
                                    subtitle: "Restart the iPhone to be sure. That always clears it.", style: .warning),
                              duration: 6)
                }
            }
        case .replaying:
            if previous != .replaying { replayStartedAt = Date() }
            if let pending = pendingToast { pendingToast = nil; showToast(pending) }
        case .reconnecting:
            deviceSpeed = 0
        case .failed(let message):
            deviceSpeed = 0
            pendingToast = nil
            showToast(Toast(symbol: "exclamationmark.triangle.fill", title: "Couldn't keep the location",
                            subtitle: message, style: .error), duration: 5)
        default:
            break
        }
    }

    private func positionApplied(_ point: GeoPoint, id: ObjectIdentifier) {
        guard isCurrentSession(id) else { return }
        // While streaming movement, the motion loop already shows where we sent
        // the device; acknowledgements would make the marker lag behind.
        let streaming = (activity == .routing || activity == .joystick) && canStream
        if !streaming || devicePosition == nil {
            devicePosition = point
        }
        if let pending = pendingToast {
            pendingToast = nil
            showToast(pending)
        }
        geocodeDeviceIfNeeded()
    }

    private func engineChanged(_ engine: EngineKind, id: ObjectIdentifier) {
        guard isCurrentSession(id) else { return }
        sessionEngine = engine
        if case .live = engineStatus {
            engineStatus = .classicOnly(reason: "the live helper failed on this device")
        }
        guard let session, !session.canStream else { return }
        switch activity {
        case .routing:
            appendLog("Restarting the route with the classic engine…", level: .info)
            startRoute()
        case .joystick:
            activity = .holding
            warn("The joystick stopped", "It needs the live engine. Holding the current position.",
                 log: "Joystick control needs the live engine; holding the current position.")
        default:
            break
        }
    }

    private func endSession() {
        disarmKillswitch()
        remoteRouteTask?.cancel()
        remoteRouteTask = nil
        remoteJoystickMotion = nil
        remoteTrafficOverride = nil
        remoteRoadPlan = nil
        if let sessionActivity { ProcessInfo.processInfo.endActivity(sessionActivity) }
        sessionActivity = nil
        lastDeviceGeocode = nil
        session = nil
        pendingToast = nil
        sessionEngine = nil
        activity = .none
        playback = nil
        isPaused = false
        devicePosition = nil
        deviceHeading = nil
        deviceSpeed = 0
        devicePlaceName = nil
        sessionStartedAt = nil
        sessionState = .idle
        pressedKeys.removeAll()
        padVector = .zero
        stopMotionLoop()
    }

    /// Stop everything and restore the real location.
    func stop() {
        if isStarting { startCancelled = true }
        guard let session, sessionState != .stopping else { return }
        activity = .none
        playback = nil
        isPaused = false
        deviceSpeed = 0
        padVector = .zero
        pressedKeys.removeAll()
        appendLog("Stopping — restoring the real location…", level: .info)
        session.stop()
    }

    /// The connection failed for good: try the same session again, from where
    /// the device was (a route carries on from the same spot).
    func retryConnection() {
        guard let session, case .failed = sessionState else { return }
        appendLog("Trying again…", level: .info)
        if activity == .routing, !session.canStream {
            startRoute()
        } else if let point = devicePosition ?? target {
            session.start(at: point)
        }
    }

    var canRetryConnection: Bool {
        if case .failed = sessionState, session != nil { return true }
        return false
    }

    /// The big button: start whatever the current mode does, or stop.
    func primaryAction() {
        if hasSession { stop(); return }
        // The menu item and ⌘↩ stay on when the button is grey: say why instead of doing nothing.
        if let issue = startIssue { explain(issue); return }
        switch mode {
        case .teleport: teleportToTarget()
        case .route: startRoute()
        case .joystick: startJoystick()
        }
    }

    /// Whether the Start button is on. When it isn't, `startIssue` says why.
    var canStart: Bool {
        guard !isStarting else { return false }
        return startIssue?.disablesStart != true
    }

    // MARK: - Teleport

    /// The typed/picked teleport destination, if valid.
    var target: GeoPoint? {
        guard let lat = Double(latitudeText.trimmingCharacters(in: .whitespaces)),
              let lon = Double(longitudeText.trimmingCharacters(in: .whitespaces)) else { return nil }
        let p = GeoPoint(lat, lon)
        return p.isValid ? p : nil
    }

    var targetLabel: String? { targetName ?? placeName }

    /// The device is somewhere other than the target (offer "Move here").
    var targetDiffersFromDevice: Bool {
        guard let target, let devicePosition else { return target != nil }
        return Geo.distance(target, devicePosition) > 0.5
    }

    func setTarget(_ point: GeoPoint, name: String? = nil, focus: Bool = false) {
        latitudeText = String(format: "%.6f", point.latitude)
        longitudeText = String(format: "%.6f", point.longitude)
        targetName = name
        if focus { self.focus(on: point) }
    }

    private func targetTextChanged() {
        targetName = nil
        scheduleGeocode()
        if !restoring, let t = target {
            UserDefaults.standard.set("\(t.latitude),\(t.longitude)", forKey: StateKey.target)
        }
    }

    func teleportToTarget() {
        guard let point = target else {
            explain(startIssue(for: .teleport) ?? .noDestination)
            return
        }
        teleport(to: point, name: targetLabel)
    }

    /// Move the device to `point` — starting a session if needed.
    func teleport(to point: GeoPoint, name: String?) {
        guard point.isValid else { return }
        playback = nil
        isPaused = false
        if let session {
            if sessionState == .stopping {
                explain(.stillRestoring)
                return
            }
            if let from = devicePosition {
                let jump = Geo.distance(from, point)
                if jump > 1 { appendLog("Teleporting \(Format.distance(jump, units: prefs.units)) to \(name ?? Format.coordinate(point)).", level: .info) }
            }
            pendingToast = teleportToast(point, name: name)
            // A session that gave up has to be started again, not just moved.
            if case .failed = sessionState { session.start(at: point) } else { session.move(to: point) }
            activity = .holding
            deviceSpeed = 0
            deviceHeading = nil
            if session.canStream { devicePosition = point }
            recordRecent(point, name: name)
            return
        }
        pendingToast = teleportToast(point, name: name)
        Task {
            guard let obtained = await obtainSession(requireStreaming: false) else {
                pendingToast = nil
                return
            }
            if obtained.isNew { obtained.session.start(at: point) } else { obtained.session.move(to: point) }
            activity = .holding
            recordRecent(point, name: name)
        }
    }

    func recordRecent(_ point: GeoPoint, name: String?) {
        guard prefs.recordRecents else { return }
        let isTarget = target.map { $0.isClose(to: point, tolerance: 1e-6) } ?? false
        let label = name ?? (isTarget ? targetLabel : nil)
        library.recordRecent(name: label ?? Format.coordinate(point, precision: 4), point: point)
    }

    // MARK: - Map

    func focus(on point: GeoPoint, zoomIn: Bool = false) {
        mapFocus = MapFocusRequest(kind: .point(point, zoomIn: zoomIn))
    }

    /// Frame whatever matters in the current mode.
    func fitMap() {
        var points: [GeoPoint] = []
        switch mode {
        case .teleport, .joystick:
            if let target { points.append(target) }
        case .route:
            points += waypoints.map(\.point)
        }
        if let devicePosition { points.append(devicePosition) }
        if points.count > 1 {
            mapFocus = MapFocusRequest(kind: .fit(points))
        } else if let p = points.first {
            mapFocus = MapFocusRequest(kind: .point(p, zoomIn: false))
        }
    }

    /// A map click, interpreted for the current mode.
    func mapClicked(_ point: GeoPoint) {
        switch mode {
        case .teleport:
            setTarget(point)
            if prefs.instantTeleport, session != nil, canStream { teleport(to: point, name: nil) }
        case .route:
            addWaypoint(point)
        case .joystick:
            if activity == .joystick, canStream {
                teleport(to: point, name: nil)
                activity = .joystick
            } else {
                setTarget(point)
            }
        }
    }

    // MARK: - Log

    func appendLog(_ text: String, level: LogLevel = .info) {
        log.append(LogEntry(date: Date(), level: level, text: text))
        if log.count > 1000 { log.removeFirst(log.count - 1000) }
    }

    func clearLog() { log.removeAll() }

    var logText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return DiagnosticsRedactor.redact(log.map { "[\(f.string(from: $0.date))] \($0.text)" }.joined(separator: "\n"))
    }

    // MARK: - Geocoding

    /// Reverse-geocode the target into a place name (debounced).
    func scheduleGeocode() {
        geocodeTask?.cancel()
        guard let point = target else { placeName = nil; return }
        geocodeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            self.placeName = await self.reverseGeocode(point, using: self.geocoder)
        }
    }

    /// Name the device's surroundings, at most every 10 s / 150 m.
    func geocodeDeviceIfNeeded() {
        guard let point = devicePosition else { return }
        if let last = lastDeviceGeocode {
            let moved = Geo.distance(last.point, point)
            let elapsed = Date().timeIntervalSince(last.date)
            // A teleport-sized jump renames at once; gradual movement is throttled.
            guard moved >= 2000 || (moved >= 150 && elapsed >= 10) else { return }
        }
        lastDeviceGeocode = (point, Date())
        Task { [weak self] in
            guard let self else { return }
            let name = await self.reverseGeocode(point, using: self.deviceGeocoder)
            if self.session != nil { self.devicePlaceName = name }
        }
    }

    /// Completion-handler form: CLGeocoder isn't Sendable, so it can't be
    /// handed to its nonisolated async variant from the main actor. The
    /// handler runs on the main thread and fires exactly once (also when a
    /// newer request cancels this one).
    private func reverseGeocode(_ point: GeoPoint, using geocoder: CLGeocoder) async -> String? {
        if geocoder.isGeocoding { geocoder.cancelGeocode() }
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                // Nil over water, offline, rate-limited or cancelled.
                guard let p = placemarks?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                var seen = Set<String>()
                let parts = [p.name, p.locality, p.administrativeArea, p.country]
                    .compactMap { $0 }
                    .filter { seen.insert($0).inserted }
                continuation.resume(returning: parts.prefix(3).joined(separator: ", "))
            }
        }
    }

    // MARK: - Persistence

    private func restoreState() {
        restoring = true
        defer { restoring = false }
        let d = UserDefaults.standard
        if let m = d.string(forKey: StateKey.mode).flatMap(Mode.init(rawValue:)) { mode = m }
        if let s = d.string(forKey: StateKey.target), let p = Coordinate.parsePoint(s), p.isValid {
            latitudeText = String(format: "%.6f", p.latitude)
            longitudeText = String(format: "%.6f", p.longitude)
        }
        routeSpeed = prefs.defaultRouteSpeed
        if let data = d.data(forKey: StateKey.routeDraft),
           let draft = try? JSONDecoder().decode(RouteDraft.self, from: data) {
            let waits = draft.waits ?? []
            // (A draft saved by an older build may hold a point that isn't a place: leave it out.)
            waypoints = draft.waypoints.enumerated().compactMap { i, point in
                point.isValid ? Waypoint(point: point, wait: i < waits.count ? RouteWaits.clamp(waits[i]) : 0) : nil
            }
            followRoads = draft.followRoads
            travelMode = draft.travelMode
            loopMode = draft.loopMode
            pacing = draft.pacing.flatMap(RoutePacing.init(rawValue:)) ?? .speed
            if draft.speed > 0 { routeSpeed = draft.speed }
            if draft.duration > 0 { routeDuration = draft.duration }
        }
    }

    struct RouteDraft: Codable {
        var waypoints: [GeoPoint]
        /// Seconds to wait at each waypoint; missing in drafts from older builds.
        var waits: [Double]?
        var followRoads: Bool
        var travelMode: TravelMode
        var loopMode: LoopMode
        var pacing: String?
        var speed: Double
        var duration: Double
    }

    func saveRouteDraft() {
        guard !restoring else { return }
        let draft = RouteDraft(waypoints: waypoints.map(\.point),
                               waits: waypoints.contains { $0.wait > 0 } ? waypoints.map(\.wait) : nil,
                               followRoads: followRoads, travelMode: travelMode,
                               loopMode: loopMode, pacing: pacing.rawValue, speed: routeSpeed, duration: routeDuration)
        if let data = try? JSONEncoder().encode(draft) {
            UserDefaults.standard.set(data, forKey: StateKey.routeDraft)
        }
    }
}

extension Duration {
    var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
