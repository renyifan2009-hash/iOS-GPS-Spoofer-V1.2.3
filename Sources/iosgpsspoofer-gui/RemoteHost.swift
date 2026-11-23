import AppKit
import Foundation
import Observation
import RemoteAPI
import SpooferCore
import SpooferRemote

/// Settings ▸ iPhone Remote: runs the remote server inside the app, so the
/// SpoofRemote iPhone app drives this window's session and you see on the
/// Mac whatever the iPhone does. (`iosgpsspoof serve` is the headless
/// alternative; run one or the other, they share the port.)
@MainActor
@Observable
final class RemoteHost {
    static let shared = RemoteHost()
    private static let enabledKey = "remoteControlEnabled"

    enum ServerState: Equatable {
        case off
        case starting
        case running
        case failed(String)
    }

    var isEnabled: Bool = UserDefaults.standard.bool(forKey: RemoteHost.enabledKey) {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start() } else { stop() }
        }
    }

    private(set) var state: ServerState = .off
    private(set) var pairingCode = ""
    private(set) var clients: [PairingManager.PairedClient] = []
    private(set) var addresses: [BonjourService.LocalAddress] = []
    let serverName = BonjourService.computerName
    let port = RemoteAPI.defaultPort

    @ObservationIgnored private var server: MacRemoteServer?
    @ObservationIgnored private var pairing: PairingManager?
    @ObservationIgnored private let bridge = AppRemoteBridge()

    /// At launch: start the server if the setting is on.
    func bootstrap() {
        if isEnabled { start() }
    }

    func start() {
        guard self.server == nil else { return }
        let pairing = PairingManager()
        let server = MacRemoteServer(name: serverName, port: port, controller: bridge, pairing: pairing)
        pairing.onChange = {
            Task { @MainActor in RemoteHost.shared.refreshPairing() }
        }
        server.onStateChange = { state in
            Task { @MainActor in RemoteHost.shared.serverStateChanged(state) }
        }
        server.onLog = { line in
            Task { @MainActor in AppModel.shared.appendLog("iPhone Remote: \(line)", level: .debug) }
        }
        server.onCommand = { what, client in
            Task { @MainActor in RemoteHost.shared.commandReceived(what, from: client.name) }
        }
        self.pairing = pairing
        self.server = server
        refreshPairing()
        addresses = BonjourService.localIPv4Addresses()
        state = .starting
        do {
            try server.start()
        } catch {
            self.server = nil
            state = .failed("\(error)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        pairing = nil
        state = .off
    }

    func newCode() {
        pairing?.regenerateCode()
    }

    func unpair(_ client: PairingManager.PairedClient) {
        pairing?.revoke(clientID: client.id)
    }

    func refreshAddresses() {
        addresses = BonjourService.localIPv4Addresses()
    }

    private func refreshPairing() {
        guard let pairing else { return }
        pairingCode = pairing.formattedCode
        clients = pairing.pairedClients.sorted { $0.pairedAt > $1.pairedAt }
    }

    private func serverStateChanged(_ newState: MacRemoteServer.State) {
        guard server != nil else { return }
        switch newState {
        case .starting:
            state = .starting
        case .ready:
            state = .running
            AppModel.shared.appendLog("iPhone Remote is on: pair with code \(pairingCode).", level: .info)
            #if DEBUG
            // For automated tests of the real app: SPOOFER_PRINT_PAIRING=1 prints the code to stdout.
            if ProcessInfo.processInfo.environment["SPOOFER_PRINT_PAIRING"] == "1" {
                print("PAIRING-CODE \(pairingCode.filter(\.isNumber))")
                fflush(stdout)
            }
            #endif
        case .failed(let message):
            state = .failed(message)
            server = nil
            AppModel.shared.appendLog("iPhone Remote couldn't start: \(message)", level: .error)
        case .stopped:
            break
        }
    }

    private func commandReceived(_ what: String, from name: String) {
        refreshPairing()
        AppModel.shared.showToast(Toast(symbol: "iphone.radiowaves.left.and.right", title: "From \(name)",
                                        subtitle: what.prefix(1).uppercased() + what.dropFirst(), style: .info))
    }
}

/// Lets the remote server drive the app's own model, so the window shows what the iPhone does. Start and
/// move call `AppModel.teleport(to:name:)`, exactly like the Teleport button (which creates the
/// `SpoofSession` or moves it); a route and the joystick go through `AppModel+RemoteControl.swift`; stop
/// calls `AppModel.stop()`.
@MainActor
final class AppRemoteBridge: RemoteController {
    func status() async -> RemoteStatus {
        Self.makeStatus(AppModel.shared)
    }

    func setLocation(_ request: LocationRequest) async throws -> RemoteStatus {
        let model = AppModel.shared
        let point = GeoPoint(request.latitude, request.longitude)
        guard point.isValid else { throw RemoteControlError("That isn't a valid coordinate.", status: 400) }
        model.setTarget(point, name: request.name, focus: true)
        if model.session != nil {
            model.mode = .teleport
            model.teleport(to: point, name: request.name)
        }
        return Self.makeStatus(model)
    }

    func start(_ request: LocationRequest?) async throws -> RemoteStatus {
        let model = AppModel.shared
        if let request {
            let point = GeoPoint(request.latitude, request.longitude)
            guard point.isValid else { throw RemoteControlError("That isn't a valid coordinate.", status: 400) }
            model.setTarget(point, name: request.name, focus: true)
        }
        guard let point = model.target else {
            throw RemoteControlError("Pick a location first.", status: 400)
        }
        try Self.requireReadyToStart(model)
        model.mode = .teleport
        model.teleport(to: point, name: request?.name ?? model.targetName)
        return Self.makeStatus(model)
    }

    func driveRoute(_ request: RouteRequest) async throws -> RemoteStatus {
        let model = AppModel.shared
        guard request.isValid else { throw RemoteControlError("That route isn't valid.", status: 400) }
        try Self.requireReadyToStart(model)
        model.startRemoteRoute(request)
        return Self.makeStatus(model)
    }

    func joystick(_ request: JoystickRequest) async throws -> RemoteStatus {
        let model = AppModel.shared
        guard request.isValid else {
            throw RemoteControlError("The heading must be 0 up to 360 degrees and the speed 0 to 70 m/s.", status: 400)
        }
        guard let session = model.session, model.sessionState == .active else {
            throw RemoteControlError("Start a location first, then steer with the joystick.")
        }
        guard session.canStream else {
            throw RemoteControlError("The joystick needs the live engine. This iPhone is using the classic one, "
                                     + "where every move takes a second or more.")
        }
        model.steerFromPhone(request)
        return Self.makeStatus(model)
    }

    func setPaused(_ request: PauseRequest) async throws -> RemoteStatus {
        let model = AppModel.shared
        guard model.activity == .routing else { throw RemoteControlError("No route is running.") }
        guard model.canPauseRoute else {
            throw RemoteControlError("This route is being replayed as a recorded track, which can't be paused.")
        }
        if model.isPaused != request.paused { model.togglePause() }
        return Self.makeStatus(model)
    }

    func setAutoStop(_ request: AutoStopRequest) async throws -> RemoteStatus {
        let model = AppModel.shared
        guard model.session != nil || model.isStarting || request.minutes == 0 else {
            throw RemoteControlError("Start a location first. Auto-stop counts from now.")
        }
        model.armAutoStopFromPhone(minutes: request.minutes)
        return Self.makeStatus(model)
    }

    func stop() async -> RemoteStatus {
        AppModel.shared.stop()
        return Self.makeStatus(AppModel.shared)
    }

    /// The iPhone's own pairing file, so it needn't be AirDropped: asked about first, then made for the
    /// iPhone plugged in, exactly as File ▸ Pairing File for the iPhone App… makes it.
    func pairingFile(forClientNamed clientName: String, code: String) async throws -> PairingFilePayload {
        let model = AppModel.shared
        let readiness = model.pairingReadiness
        guard readiness.isReady, let pmd = model.pmd, let device = model.selectedDevice else {
            throw RemoteControlError("\(readiness.title). \(readiness.instruction)")
        }
        guard Self.askToSend(clientName: clientName, deviceName: device.deviceName, code: code) else {
            model.appendLog("Didn't send \(clientName) a pairing file.", level: .info)
            throw RemoteControlError("The Mac didn't allow it.", status: 403)
        }
        model.appendLog("Making the pairing file for \(device.deviceName), for \(clientName)…", level: .info)
        let udid = device.udid
        do {
            let made = try await Task.detached(priority: .userInitiated) { try pmd.pairingFileData(udid: udid) }.value
            model.appendLog("Sent \(clientName) its pairing file.", level: .success)
            return PairingFilePayload(data: made.data, olderIOSOnly: made.remotePairingProblem)
        } catch {
            let reason = SpoofSession.firstLine(of: error)
            model.appendLog("Couldn't make the pairing file: \(reason)", level: .error)
            throw RemoteControlError("The Mac couldn't make the pairing file: \(reason)")
        }
    }

    /// How long the question waits for an answer before it counts as a no (the iPhone gives up a little later).
    static let questionTimeout: TimeInterval = 100

    /// Don't Allow or Allow. The person is usually in another app when the iPhone asks, and macOS no longer
    /// lets an app push itself in front: so the Dock icon bounces until they look, and the alert floats over
    /// other apps' windows instead of waiting behind them. Don't Allow is the default, so a Return typed
    /// just as it appears says no; Allow takes a click. Left unanswered, it closes by itself as a no.
    private static func askToSend(clientName: String, deviceName: String, code: String) -> Bool {
        NSApp.requestUserAttention(.criticalRequest)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Send “\(clientName)” its pairing file?"
        alert.informativeText = "AnyWhere will make the pairing file for \(deviceName), plugged into this Mac, and send it "
            + "to that iPhone so it can change its location on its own.\n\nAllow only if the iPhone shows the code \(code)."
        alert.addButton(withTitle: "Don’t Allow")
        let allow = alert.addButton(withTitle: "Allow")
        allow.keyEquivalent = ""
        alert.window.level = .floating
        let window = alert.window
        let timer = Timer(timeInterval: questionTimeout, repeats: false) { _ in
            MainActor.assumeIsolated {
                if NSApp.modalWindow === window { NSApp.stopModal(withCode: .alertFirstButtonReturn) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// The checks every start has in common, with the messages the iPhone shows.
    private static func requireReadyToStart(_ model: AppModel) throws {
        guard model.pmd != nil else {
            throw RemoteControlError("The Mac app can't find pymobiledevice3. Finish its setup on the Mac.")
        }
        guard model.session != nil || model.selectedDevice != nil else {
            throw RemoteControlError("No iPhone is connected to the Mac. Connect it with a cable and tap Trust.")
        }
        guard model.sessionState != .stopping else {
            throw RemoteControlError("Still restoring the real location. Try again in a moment.")
        }
    }

    static func makeStatus(_ model: AppModel) -> RemoteStatus {
        let spoofing = model.session != nil || model.isStarting
        let position = model.devicePosition ?? (spoofing ? model.target : nil)
        let device = model.activeDevice
        let connected = device.map { d in model.devices.contains { $0.udid == d.udid } } ?? false
        var phase = SessionRemoteController.phase(for: model.sessionState)
        if model.isStarting && model.session == nil { phase = .starting }
        // What the Mac is doing, so the iPhone can show the right controls.
        var activity: String?
        if model.remoteRoutePlanning {
            activity = "planning"
        } else if spoofing {
            switch model.activity {
            case .joystick: activity = "joystick"
            case .routing: activity = "route"
            default: activity = "hold"
            }
        }
        let moving = activity == "joystick" || activity == "route"
        return RemoteStatus(
            connected: connected,
            spoofing: spoofing,
            latitude: position?.latitude,
            longitude: position?.longitude,
            placeName: spoofing ? (model.devicePlaceName ?? model.targetName) : nil,
            phase: phase,
            detail: SessionRemoteController.detail(for: model.sessionState),
            device: device.map {
                DeviceSummary(name: $0.deviceName, model: $0.modelName, iosVersion: $0.productVersion,
                              connection: $0.isUSB ? "usb" : "network")
            },
            engine: model.sessionEngine?.label,
            serverName: RemoteHost.shared.serverName,
            activity: activity,
            speed: moving ? model.deviceSpeed : nil,
            heading: moving ? model.deviceHeading : nil,
            routeProgress: model.activity == .routing ? model.routeProgress?.fraction : nil,
            routePaused: model.activity == .routing ? model.isPaused : nil,
            autoStopAt: model.killswitchDeadline?.timeIntervalSince1970,
            routeWait: routeWait(model))
    }

    /// Why a running route is standing still, in the protocol's words.
    static func routeWait(_ model: AppModel) -> RouteWait? {
        guard model.activity == .routing, case let .stopped(reason, remaining) = model.tripStatus else { return nil }
        let left = remaining.flatMap { $0.isFinite ? max(0, $0) : nil }
        switch reason {
        case .waypoint(let index): return RouteWait(reason: "stop", stop: index, remaining: left)
        case .redLight: return RouteWait(reason: "light", remaining: left)
        case .stopSign: return RouteWait(reason: "sign", remaining: left)
        case .giveWay: return RouteWait(reason: "yield", remaining: left)
        case .crossing: return RouteWait(reason: "crossing", remaining: left)
        case .rest, .pause: return RouteWait(reason: "break", remaining: left)
        case .turnaround: return RouteWait(reason: "turnaround", remaining: left)
        case .destination: return RouteWait(reason: "arrived")
        }
    }
}
