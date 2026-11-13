import MapKit
import PhoneOnlyCore
import RemoteAPI
import SwiftUI

/// Who holds the simulated location.
enum LocationSource: String {
    /// The Mac, over USB or Wi-Fi; this app tells it where to go.
    case mac
    /// This iPhone by itself (the iPhone-only mode).
    case thisPhone
}

/// What the Mac card is doing: a single teleport, a route, or steering with the joystick.
enum MacMode: Hashable { case teleport, route, joystick }

/// The map, a floating status pill and controls, and a glass card to start,
/// move or stop the simulated location.
struct ContentView: View {
    @Environment(ConnectionManager.self) private var connection
    @Environment(LocationController.self) private var locations
    @Environment(RouteLibrary.self) private var routeLibrary
    @Environment(OnDeviceController.self) private var phone
    @Environment(UpdateChecker.self) private var updates
    @Environment(LicenseStore.self) private var licenses
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("hasSeenIntro") private var hasSeenIntro = false
    @AppStorage("locationSource") private var source: LocationSource = .mac
    @State private var showIntro = false
    @State private var showSearch = false
    @State private var showPairing = false
    @State private var showPhoneSetup = false
    @State private var showSettings = false
    @State private var showPaywall = false
    #if DEBUG
    /// `-SpoofRemoteShow autoStop`: the Stop After sheet, for screenshots.
    @State private var showAutoStopDemo = false
    #endif
    /// A pairing file that came in an `anywhere://pairingfile` link, waiting for the person to say yes.
    /// Any page or app can open such a link, so it never replaces the working file on its own.
    @State private var offeredPairing: Data?
    @State private var pairAfterIntro = false
    @State private var route = RouteDraft()
    @State private var joystick = JoystickModel()
    @State private var phoneMotion: PhoneMotionController?
    @State private var macMode: MacMode = .teleport
    /// How far out the map is, so following the simulated location keeps the zoom.
    @State private var mapDistance: CLLocationDistance = 3500
    /// Where the search bar and buttons at the top, and the card at the bottom, sit on the screen. A tap
    /// there is for them, never the map's, even when a button's glass lets it through.
    @State private var controlFrames: [String: CGRect] = [:]
    nonisolated private static let screenSpace = "screen"

    /// Remembers where `content` sits on the screen, so the map leaves taps there to it.
    private func overMap(_ key: String, _ content: some View) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.screenSpace)) } action: {
            controlFrames[key] = $0
        }
    }

    /// Either source holds a location right now.
    private var isSpoofing: Bool { connection.isSpoofing || phone.isSpoofing }

    /// How much of the screen the card may take. The joystick card is the tallest (a pad and a pace
    /// row); the rest of the time the map matters more.
    private var cardHeightFraction: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 0.7 }
        return macMode == .joystick && isSpoofing ? 0.74 : 0.6
    }

    var body: some View {
        GeometryReader { screen in
            ZStack {
                map
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    // The card may take up to 60% of the screen (70% with very large text,
                    // where the map matters less). Past that it scrolls.
                    overMap("card", bottomCard(maxHeight: screen.size.height * cardHeightFraction))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            .coordinateSpace(.named(Self.screenSpace))
        }
        .sheet(isPresented: $showSearch) {
            MapSearchView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPairing) {
            PairingView()
        }
        .sheet(isPresented: $showPhoneSetup) {
            PhoneOnlySetupView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        #if DEBUG
        .sheet(isPresented: $showAutoStopDemo) { AutoStopSheet(connection: connection) }
        #endif
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .alert(phone.isSetUp ? "Replace the pairing file?" : "Use this pairing file?",
               isPresented: Binding(get: { offeredPairing != nil }, set: { if !$0 { offeredPairing = nil } })) {
            Button(phone.isSetUp ? "Replace" : "Use It", role: phone.isSetUp ? .destructive : nil) {
                if let data = offeredPairing { importOfferedPairing(data) }
                offeredPairing = nil
            }
            Button("Cancel", role: .cancel) { offeredPairing = nil }
        } message: {
            Text(phone.isSetUp
                 ? "A link is offering a new pairing file. Only say yes if you just asked SideStore for it: it replaces the one that works now."
                 : "A link is offering this iPhone's pairing file. Only say yes if you just asked SideStore for it.")
        }
        .onOpenURL { url in
            if url.scheme == "anywhere" {
                handleAppLink(url)
                return
            }
            // A pairing file opened from AirDrop, Files or Mail.
            if phone.importPairingFile(from: url) {
                // Someone who brings a pairing file has no need for the intro.
                hasSeenIntro = true
                if !isSpoofing, !connection.isWorking, !phone.isWorking { source = .thisPhone }
            }
            // Either way the setup screen opens: it says the file was added,
            // or why it wasn't.
            presentPhoneSetup()
        }
        .fullScreenCover(isPresented: $showIntro, onDismiss: {
            if pairAfterIntro {
                pairAfterIntro = false
                showPairing = true
            }
        }) {
            IntroView { pairNow in
                hasSeenIntro = true
                pairAfterIntro = pairNow
                showIntro = false
            }
        }
        .onAppear {
            if phoneMotion == nil { phoneMotion = PhoneMotionController(phone: phone) }
            // Lost while locked: a notification. Lost on screen: LocalDevVPN, which is the usual fix,
            // except on cellular data alone, where iOS turns it away and the message says what to do.
            phone.onConnectionLost = {
                LocalAlerts.connectionLost()
                if !phone.onCellularOnly { LocalDevVPN.turnOnIfNeeded() }
            }
            // LocalDevVPN goes on for Start and off at Stop (each unless Settings says not to).
            phone.turnOnVPN = { LocalDevVPN.turnOnToStart(cellularOnly: phone.onCellularOnly) }
            phone.onStopped = { LocalDevVPN.turnOffAfterStop() }
            LocalAlerts.scheduleSigningReminder(expiry: SigningStatus.expiry)
            Task { await licenses.refreshIfDue() }
            // (A pairing file that was opened first has already shown the setup screen.)
            if !hasSeenIntro, !showPhoneSetup { showIntro = true }
            // Looking for Macs makes iOS ask for Local Network access. Not before
            // the person asked to find a Mac: the first launch would have the
            // question appear over the Welcome page. A Mac already paired is
            // looked for again by its name in case its address changed.
            if connection.isPaired { connection.startBrowsing() }
            connection.startPolling()
            updates.checkIfDue()
            #if DEBUG
            // For screenshots in the Simulator: `-SpoofRemoteShow phoneSetup`
            // opens the setup sheet; `phoneStart` starts at Apple Park.
            // `-SpoofRemotePair host:port:code` pairs with a Mac by itself (for tests against a Mac running
            // on this computer). `-SpoofRemoteMode route|joystick` opens that tab.
            if let pair = UserDefaults.standard.string(forKey: "SpoofRemotePair") {
                let parts = pair.split(separator: ":").map(String.init)
                if parts.count == 3, let port = UInt16(parts[1]) {
                    Task {
                        if await connection.pair(host: parts[0], port: port, code: parts[2]) {
                            hasSeenIntro = true
                            connection.startPolling()
                        }
                    }
                }
            }
            switch UserDefaults.standard.string(forKey: "SpoofRemoteMode") {
            case "route": macMode = .route
            case "joystick": macMode = .joystick
            default: break
            }
            switch UserDefaults.standard.string(forKey: "SpoofRemoteShow") {
            case "phoneSetup":
                showPhoneSetup = true
            case "phoneDemo":
                // The iPhone-only card with a demo pairing file and a pin at Apple Park (nothing starts).
                phone.useDemoPairing()
                source = .thisPhone
                let place = Place(name: "Apple Park", subtitle: "Cupertino, CA", latitude: 37.3349, longitude: -122.0090)
                locations.select(place, moveCamera: false)
                locations.focus(on: place.coordinate, meters: 2200)
                if macMode == .route {
                    route.add(place.coordinate)
                    route.add(CLLocationCoordinate2D(latitude: 37.3318, longitude: -122.0312))
                    route.add(CLLocationCoordinate2D(latitude: 37.3230, longitude: -122.0322))
                }
            case "settings":
                showSettings = true
            case "paywall":
                showPaywall = true
            case "autoStop":
                showAutoStopDemo = true
            case "applePark":
                // Just the map, at Apple Park with a pin (for screenshots): nothing is started.
                let place = Place(name: "Apple Park", subtitle: "Cupertino, CA", latitude: 37.3349, longitude: -122.0090)
                locations.select(place, moveCamera: false)
                locations.focus(on: place.coordinate, meters: 2200)
            case "phoneStart":
                let place = Place(name: "Apple Park", subtitle: "Cupertino", latitude: 37.3349, longitude: -122.0090)
                locations.selection = place
                locations.focus(on: place.coordinate, meters: 2500)
                setPhone(place)
            default:
                break
            }
            #endif
        }
        .task(id: source) {
            // Is LocalDevVPN on? The status pill says so before you tap Start, and if it's off it is
            // opened by itself (it comes straight back here).
            await checkVPN()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { phoneMotion?.releaseJoystick() }
            switch phase {
            case .active:
                // The pairing screen asks for it itself, and starts over when the
                // person comes back from Settings.
                if connection.isPaired || showPairing { connection.startBrowsing() }
                connection.startPolling()
                updates.checkIfDue()
                if source == .thisPhone, phone.isSetUp {
                    // Back on screen while holding: check the connection now rather than at the next beat.
                    if phone.isSpoofing { phone.refreshNow() }
                    Task { await checkVPN() }
                }
            case .background:
                connection.stopPolling()
                connection.stopBrowsing()
                phone.sweepInbox()
            default:
                break
            }
        }
        .task(id: connection.isSpoofing) {
            // Opening the app while a location is held: show where it is.
            if connection.isSpoofing, locations.selection == nil, let spoofed = spoofedCoordinate {
                locations.focus(on: spoofed, meters: 2500)
            }
        }
        .sensoryFeedback(.selection, trigger: locations.selection?.id)
        .sensoryFeedback(trigger: isSpoofing) { _, isSpoofing in
            isSpoofing ? .success : .impact(weight: .light)
        }
        .onChange(of: connection.status?.activity) { _, activity in followMacActivity(activity) }
        .onChange(of: simulatedSpot) { _, _ in keepSimulatedLocationInView() }
    }

    // MARK: - Links, LocalDevVPN and Pro

    /// `anywhere://` links: LocalDevVPN coming back, a license from the payment page, or a pairing file
    /// from SideStore.
    private func handleAppLink(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch url.host?.lowercased() {
        case "activate":
            if let key = value("key") { Task { if await licenses.activate(key: key) { showPaywall = false } } }
        case "pairingfile":
            // SideStore's answer to "sidestore://pairing?urlname=anywhere". Asked about first.
            guard let text = value("data"), let data = Data(base64Encoded: text), data.count < 1_000_000 else { return }
            offeredPairing = data
        default:
            // Back from LocalDevVPN: is the connection there now?
            Task { await checkVPN(openIfOff: false) }
        }
    }

    private func importOfferedPairing(_ data: Data) {
        let file = FileManager.default.temporaryDirectory.appending(path: "SideStore.mobiledevicepairing")
        guard (try? data.write(to: file, options: .completeFileProtection)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: file) }
        if phone.importPairingFile(from: file) {
            hasSeenIntro = true
            if !isSpoofing { source = .thisPhone }
        }
        presentPhoneSetup()
    }

    /// Is LocalDevVPN on? If not, and the setting allows, open it: it turns on and comes back.
    /// On cellular data alone nothing answers even with it on, so there only if AnyWhere hasn't turned it
    /// on yet: it can't connect there, but it has to be on before Airplane Mode for that to work.
    /// While reconnecting on cellular it was on already, so it isn't opened then.
    private func checkVPN(openIfOff: Bool = true) async {
        guard source == .thisPhone, phone.isSetUp else { return }
        if phone.isReconnecting {
            if openIfOff, !phone.onCellularOnly { LocalDevVPN.turnOnIfNeeded() }
            return
        }
        guard !phone.isSpoofing, !phone.isWorking else { return }
        await phone.checkLoopback()
        guard openIfOff, phone.loopbackReachable == false else { return }
        if !phone.onCellularOnly || !LocalDevVPN.turnedOnHere { LocalDevVPN.turnOnIfNeeded() }
    }

    /// Starting a location on this iPhone needs Pro (or the trial) once payments are set up.
    private func requirePro() -> Bool {
        if licenses.canUseEverything { return true }
        showPaywall = true
        return false
    }

    // MARK: - Following the Mac

    /// Where the Mac says the location is, as something that can be compared.
    private struct Spot: Equatable { var latitude: Double; var longitude: Double }

    private var simulatedSpot: Spot? {
        if source == .thisPhone, let current = phone.current {
            return Spot(latitude: current.latitude, longitude: current.longitude)
        }
        guard source == .mac, let status = connection.status, status.spoofing,
              let latitude = status.latitude, let longitude = status.longitude else { return nil }
        return Spot(latitude: latitude, longitude: longitude)
    }

    /// The Mac started something (a route from its own window, say): show the matching controls.
    private func followMacActivity(_ activity: String?) {
        switch activity {
        case "route", "planning": if macMode != .route { macMode = .route }
        case "joystick": if macMode != .joystick { macMode = .joystick }
        default: break
        }
    }

    /// While steering, the map keeps the simulated location in view (and the zoom you chose).
    private func keepSimulatedLocationInView() {
        guard macMode == .joystick, joystick.followsMarker, let spot = simulatedSpot else { return }
        // The card covers the lower part of the screen: aim the camera a little behind the marker so it
        // sits in the free part above the card.
        // (The map shows about half as many metres top to bottom as the camera is away.)
        let shift = mapDistance * 0.54 * 0.26
        let behind = PhoneGeo.moved(latitude: spot.latitude, longitude: spot.longitude, meters: shift,
                                    bearing: joystick.mapHeading + 180)
        let marker = CLLocationCoordinate2D(latitude: behind.latitude, longitude: behind.longitude)
        withAnimation(.linear(duration: 0.4)) {
            locations.camera = .camera(MapCamera(centerCoordinate: marker, distance: mapDistance,
                                                 heading: joystick.mapHeading, pitch: 0))
        }
    }

    /// Show the setup screen for the iPhone-only mode, over whatever else is
    /// up. SwiftUI shows one sheet at a time, and a sheet asked for while the
    /// intro or another sheet is up is lost, so those go first.
    private func presentPhoneSetup() {
        let otherUp = showIntro || showSearch || showPairing
        pairAfterIntro = false      // the intro's "Find My Mac" would open the Mac sheet next
        showIntro = false
        showSearch = false
        showPairing = false
        guard otherUp else {
            showPhoneSetup = true
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            showPhoneSetup = true
        }
    }

    // MARK: - Map

    private var spoofedCoordinate: CLLocationCoordinate2D? {
        if source == .thisPhone { return phone.current }
        guard let status = connection.status, status.spoofing,
              let latitude = status.latitude, let longitude = status.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var markerPhase: SpoofPhase {
        source == .thisPhone ? (phone.phase == .stopping ? .stopping : (phone.isSpoofing ? .active : .starting))
            : (connection.status?.phase ?? .idle)
    }

    /// Building a route on the map (Mac source, Route tab).
    private var routeMode: Bool { macMode == .route }

    private var map: some View {
        @Bindable var locations = locations
        return MapReader { proxy in
            Map(position: $locations.camera) {
                if let spoofed = spoofedCoordinate {
                    Annotation("Simulated location", coordinate: spoofed, anchor: .center) {
                        DeviceMarker(phase: markerPhase)
                    }
                    .annotationTitles(.hidden)
                }
                // (While steering, the pin of the place you started from would sit under the moving marker.)
                if let selection = locations.selection, !routeMode, !(macMode == .joystick && connection.isSpoofing) {
                    Annotation(selection.name, coordinate: selection.coordinate, anchor: .bottom) {
                        SelectionPin().id(selection.id)
                    }
                    .annotationTitles(.hidden)
                }
                if routeMode {
                    ForEach(Array(route.stops.enumerated()), id: \.element.id) { index, stop in
                        Annotation("Stop \(index + 1)", coordinate: stop.coordinate, anchor: .center) {
                            RouteStopPin(number: index + 1, wait: route.effectiveWait(at: index))
                        }
                        .annotationTitles(.hidden)
                    }
                    if route.stops.count >= 2 {
                        MapPolyline(coordinates: route.stops.map(\.coordinate))
                            .stroke(Brand.sky.opacity(0.85),
                                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                }
                if locations.showsReportedLocation {
                    UserAnnotation()
                }
            }
            // Muted: the map's softer colours suit the app's and keep the pins easy to see.
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                // Only a zoom someone could steer by: the whole world (the first reading) and a few metres
                // across would otherwise be copied back onto the map by the follow below.
                let distance = context.camera.distance
                if (300...40_000).contains(distance) { mapDistance = distance }
                joystick.setMapHeading(context.camera.heading)
            }
            .onTapGesture(coordinateSpace: .named(Self.screenSpace)) { point in
                // A tap on the controls over the map (the search bar's empty end, say) is theirs.
                guard !controlFrames.values.contains(where: { $0.contains(point) }),
                      let coordinate = proxy.convert(point, from: .named(Self.screenSpace)) else { return }
                withAnimation(Brand.spring) {
                    if routeMode {
                        route.add(coordinate)
                    } else {
                        locations.drop(at: coordinate)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Top bar

    /// A search bar across the top, like Maps, with Settings beside it. Under it, on the left, what's
    /// happening; on the right, the button that shows where iOS thinks this iPhone is.
    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            overMap("search", HStack(spacing: 10) {
                Button {
                    showSearch = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Search for a place")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    // The whole capsule takes the tap. With the glass's own press effect on, a tap on its
                    // empty end missed the button and went through to the map, which dropped a pin there.
                    .contentShape(Capsule())
                    .glassCapsule()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search for a place")
                CircleButton(symbol: "gearshape", label: "Settings") { showSettings = true }
            })
            HStack(alignment: .top, spacing: 10) {
                overMap("pill", Button {
                    if source == .thisPhone { showPhoneSetup = true } else { showPairing = true }
                } label: {
                    if source == .thisPhone {
                        PhonePill(phone: phone)
                    } else {
                        StatusPill(connection: connection)
                    }
                }
                .buttonStyle(.plain))
                Spacer(minLength: 8)
                overMap("location", CircleButton(symbol: locations.showsReportedLocation ? "location.fill" : "location",
                                                 label: "Show where iOS says this iPhone is",
                                                 isOn: locations.showsReportedLocation,
                                                 tint: locations.showsReportedLocation ? Brand.sky : nil) {
                    withAnimation(Brand.snappy) { locations.toggleReportedLocation() }
                })
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Bottom card

    /// What is under the source picker: the notices, then the card for the chosen source.
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            otherSourceHoldingNotice
            if SigningStatus.isEndingSoon {
                signingNotice.transition(.rise)
            }
            UpdateNoticeView()
            if source == .thisPhone {
                phoneCard
            } else {
                macCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bottomCard(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // The part under the picker is exactly as tall as what is in it, up to the limit, and scrolls
            // past that. (A small iPhone, or large text, would otherwise push the buttons off the
            // bottom. A flexible frame here stretched the card to the limit even when it was nearly
            // empty, over half the map.)
            ScrollView { cardBody }
                .scrollBounceBehavior(.basedOnSize)
                // Capped, then sized to what is in it: `frame(maxHeight:)` before `fixedSize` gives the
                // content's height up to the cap, and the scroll view scrolls only past it.
                .frame(maxHeight: max(160, maxHeight - 50 - (hasPinnedAction ? 70 : 0)))
                .fixedSize(horizontal: false, vertical: true)
            // The main button stays put at the bottom, however much is above it to scroll.
            pinnedAction
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassSurface(cornerRadius: 32)
        .animation(Brand.spring, value: source)
        .animation(Brand.spring, value: macMode)
        .animation(Brand.spring, value: route.stops.count)
        .animation(Brand.spring, value: connection.isPaired)
        .animation(Brand.spring, value: isSpoofing)
        .animation(Brand.spring, value: locations.selection)
        .animation(Brand.spring, value: connection.lastError)
        .animation(Brand.spring, value: connection.unpairedNotice)
        .animation(Brand.spring, value: connection.link)
        .animation(Brand.spring, value: phone.lastError)
        .animation(Brand.spring, value: phone.importError)
        .animation(Brand.spring, value: connection.status?.connected)
        .animation(Brand.spring, value: updates.updateAvailable)
    }

    // MARK: - The pinned action (Mac)

    private var hasPinnedAction: Bool {
        guard source == .mac, connection.isPaired else { return false }
        switch macMode {
        case .teleport, .joystick: return true
        case .route: return !isDrivingRoute
        }
    }

    @ViewBuilder
    private var pinnedAction: some View {
        if hasPinnedAction {
            switch macMode {
            case .teleport: actions
            case .route: driveRouteButton
            case .joystick: joystickButton
            }
        }
    }

    private var driveRouteButton: some View {
        GlassGroup(spacing: 10) {
            Button {
                driveRoute()
            } label: {
                Label(connection.findingRoads ? "Finding roads…" : connection.isWorking ? "Starting…" : "Drive Route",
                      systemImage: route.driving ? "car.fill" : "figure.walk")
                    .frame(maxWidth: .infinity)
                    .contentTransition(.opacity)
            }
            .prominentButton()
            .disabled(!route.canDrive || connection.isWorking || connection.findingRoads || !connection.isOnline)
        }
    }

    private var joystickButton: some View {
        GlassGroup(spacing: 10) {
            if connection.isSpoofing {
                Button {
                    Task { await connection.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .prominentButton(tint: Brand.danger)
            } else {
                Button {
                    startJoystick()
                } label: {
                    Label(connection.isWorking ? "Starting…" : "Start Joystick", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                        .contentTransition(.opacity)
                }
                .prominentButton()
                .disabled(locations.selection == nil || connection.isWorking || !connection.isOnline)
            }
        }
        .disabled(connection.isWorking)
    }

    /// The picker is locked while a location is held. When it is the other
    /// source that holds it (the Mac started one, and the app opened on "This
    /// iPhone"), the Stop for it isn't on this card, so it is offered here.
    @ViewBuilder
    private var otherSourceHoldingNotice: some View {
        if source == .thisPhone, connection.isSpoofing {
            holdingRow("The Mac is holding a location.") { _ = await connection.stop() }
                .transition(.rise)
        } else if source == .mac, phone.isSpoofing {
            holdingRow("This iPhone is holding a location.") { _ = await phoneMotion?.stop() }
                .transition(.rise)
        }
    }

    private func holdingRow(_ text: String, stop: @escaping () async -> Void) -> some View {
        HStack(spacing: 10) {
            Label(text, systemImage: "location.fill")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                Task { await stop() }
            } label: {
                Text("Stop").fixedSize()
            }
            .glassButton()
            .fixedSize()
        }
    }

    @ViewBuilder
    private var macCard: some View {
        if !connection.isPaired {
            connectPrompt
                .transition(.rise)
        } else {
            if connection.isSpoofing, let status = connection.status {
                switch macMode {
                case .teleport:
                    NowSimulatingRow(status: status)
                        .transition(.rise)
                    AutoStopRow(connection: connection)
                        .transition(.rise)
                case .route:
                    // A route that is driving has its own progress card; building one needs the room.
                    if !isDrivingRoute {
                        HeldStrip(status: status, connection: connection)
                            .transition(.rise)
                    }
                case .joystick:
                    // Steering says where it is, and how fast, in its own header.
                    EmptyView()
                }
            }
            if let status = connection.status, !status.connected, connection.isOnline {
                Label("The Mac can't see this iPhone. Connect them with a cable and tap Trust.",
                      systemImage: "cable.connector")
                    .font(.footnote)
                    .foregroundStyle(Brand.warningText)
                    .transition(.rise)
            }
            // Always there, so a place can be held first and then steered or driven from.
            macModePicker
                .transition(.rise)
            switch macMode {
            case .teleport:
                if let place = locations.selection {
                    selectionRow(place)
                        .transition(.rise)
                } else if !connection.isSpoofing {
                    Label("Tap the map or search to pick a place.", systemImage: "hand.tap.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .transition(.rise)
                }
            case .route:
                if isDrivingRoute {
                    RouteProgressCardView(route: route, connection: connection)
                        .transition(.rise)
                } else {
                    RouteCardView(route: route, connection: connection, library: routeLibrary)
                        .transition(.rise)
                }
            case .joystick:
                JoystickCardView(joystick: joystick, connection: connection,
                                 hasPlace: locations.selection != nil || connection.isSpoofing)
                    .transition(.rise)
            }
            if let error = connection.lastError {
                ErrorNotice(message: error)
                    .transition(.rise)
            } else if case .offline(let reason) = connection.link {
                // The pill only says "offline". This says why, and what to try.
                Label(reason, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(Brand.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.rise)
            }
        }
    }

    private var macModePicker: some View {
        Picker("Mode", selection: $macMode) {
            Text("Teleport").tag(MacMode.teleport)
            Text("Route").tag(MacMode.route)
            Text("Joystick").tag(MacMode.joystick)
        }
        .pickerStyle(.segmented)
    }

    private var stopAction: some View {
        GlassGroup(spacing: 10) {
            Button {
                Task { await connection.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .prominentButton(tint: Brand.danger)
        }
        .disabled(connection.isWorking)
    }

    /// The Mac is planning or driving a route.
    private var isDrivingRoute: Bool {
        ["planning", "route"].contains(connection.status?.activity ?? "")
    }

    private func driveRoute() {
        let name = route.name ?? "Drive on \(Date.now.formatted(date: .abbreviated, time: .shortened))"
        guard var request = route.request(name: name) else { return }
        if connection.drivesAtSpeedLimits, route.driving, route.natural, route.followRoads {
            request.followSpeedLimits = route.followSpeedLimits
        }
        let snapshot = route.snapshot(named: name)
        Task {
            if await connection.driveRoute(request) { routeLibrary.recordRecent(snapshot) }
        }
    }

    /// Hold the place that was picked, then the pad takes over.
    private func startJoystick() {
        guard let place = locations.selection else { return }
        Task {
            if await connection.start(at: place.request) { locations.recordRecent(place) }
        }
    }

    // MARK: - This iPhone

    @ViewBuilder
    private var phoneCard: some View {
        if !OnDeviceController.isSupported || !phone.isSetUp {
            phoneSetupPrompt
                .transition(.rise)
        } else {
            macModePicker
            if phone.isSpoofing, let current = phone.current {
                PhoneSimulatingRow(name: phone.currentName, coordinate: current)
                    .transition(.rise)
            }
            if macMode == .teleport, let place = locations.selection {
                selectionRow(place)
                    .transition(.rise)
            } else if macMode == .teleport, !phone.isSpoofing {
                Label("Tap the map or search to pick a place.", systemImage: "hand.tap.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .transition(.rise)
            }
            if let motion = phoneMotion {
                switch macMode {
                case .teleport:
                    if phone.isSpoofing { AutoStopRow(connection: motion) }
                    phoneActions
                case .route:
                    if motion.planning || motion.activity == "route", phone.isSpoofing || motion.planning {
                        RouteProgressCardView(route: route, connection: motion)
                    } else {
                        RouteCardView(route: route, connection: motion, library: routeLibrary)
                        Text(phoneRouteNote)
                            .font(.footnote).foregroundStyle(.secondary)
                        Button {
                            guard requirePro(), let request = route.request() else { return }
                            let snapshot = route.snapshot(named: route.name ?? "iPhone route")
                            let limits = route.driving && route.natural && route.followRoads && route.followSpeedLimits
                            Task {
                                if await motion.driveRoute(request, followSpeedLimits: limits) { routeLibrary.recordRecent(snapshot) }
                            }
                        } label: { Label("Drive Route", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .prominentButton()
                        .disabled(!route.canDrive || motion.isWorking)
                        if phone.isSpoofing {
                            Button("Stop") { Task { _ = await motion.stop() } }.prominentButton(tint: Brand.danger)
                        }
                    }
                case .joystick:
                    JoystickCardView(joystick: joystick, connection: motion, hasPlace: locations.selection != nil)
                    if phone.isSpoofing {
                        Button("Stop") { Task { _ = await motion.stop() } }.prominentButton(tint: Brand.danger)
                    } else {
                        Button {
                            guard requirePro(), let place = locations.selection else { return }
                            Task { _ = await motion.start(at: place.coordinate, name: place.name, joystick: true) }
                        } label: { Label("Start Joystick", systemImage: "gamecontroller.fill").frame(maxWidth: .infinity) }
                        .prominentButton()
                        .disabled(locations.selection == nil || motion.isWorking)
                    }
                }
                if let error = motion.lastError, !phone.isReconnecting, phone.lastError == nil {
                    ErrorNotice(message: error)
                }
            }
            if phone.isReconnecting {
                ReconnectingNotice()
                    .transition(.rise)
            } else if let error = phone.lastError {
                ErrorNotice(message: error, detail: phone.lastErrorDetail,
                            action: updates.updateAvailable ? ("Get the newer version", { openURL(updates.releaseURL) }) : nil)
                    .transition(.rise)
            }
        }
    }

    /// The app's signing (7 days with a free Apple ID) runs out within two days.
    private var signingNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(Brand.warningText)
            VStack(alignment: .leading, spacing: 1) {
                Text("Refresh AnyWhere soon").font(.subheadline.weight(.semibold))
                Text(SigningStatus.summary ?? "").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button("SideStore") { SideStore.open() }
                .font(.subheadline.weight(.semibold))
                .glassButton()
                .fixedSize()
        }
    }

    private var phoneSetupPrompt: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                IconTile(symbol: "iphone.gen3.radiowaves.left.and.right", size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Use this iPhone on its own").font(Brand.rounded(.title3))
                    Text(OnDeviceController.isSupported
                         ? "Needs a one-time file from your Mac. Tap Set Up for the steps."
                         : "Needs iOS 17 or later. Use your Mac instead, or update this iPhone.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = phone.importError {
                // A pairing file that was just turned down: the setup screen says so too.
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Brand.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.rise)
            }
            Button {
                showPhoneSetup = true
            } label: {
                Label("Set Up", systemImage: "checklist")
                    .frame(maxWidth: .infinity)
            }
            .prominentButton()
            .disabled(!OnDeviceController.isSupported)
            Button("Use a Mac instead") { withAnimation(Brand.spring) { source = .mac } }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.accentText)
                .frame(maxWidth: .infinity)
        }
    }

    /// Side by side, or one above the other when the text is too large for two buttons in a row.
    private var buttonRow: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
    }

    private var phoneActions: some View {
        GlassGroup(spacing: 10) {
            buttonRow {
                if phone.isSpoofing {
                    if let place = locations.selection, !phoneIsAt(place) {
                        Button {
                            setPhone(place)
                        } label: {
                            Label("Move Here", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .prominentButton()
                        .transition(.scale.combined(with: .opacity))
                    }
                    Button {
                        Task { _ = await phoneMotion?.stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .prominentButton(tint: Brand.danger)
                } else {
                    Button {
                        if let place = locations.selection { setPhone(place) }
                    } label: {
                        Label(phone.phase == .stopping ? "Stopping…" : (phone.isWorking ? "Starting…" : "Start Here"), systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                            .contentTransition(.opacity)
                    }
                    .prominentButton()
                    .disabled(locations.selection == nil || phone.isWorking)
                }
            }
        }
        .disabled(phone.isWorking)
    }

    /// Under the iPhone's route card: how it will drive.
    private var phoneRouteNote: String {
        guard route.natural else { return "This iPhone follows the route at the selected speed, with waits at your stops." }
        guard route.driving, route.followRoads, route.followSpeedLimits else {
            return "This iPhone drives it like a person: easing off for corners, stopping at some lights, with natural GPS."
        }
        return "This iPhone drives each road at about its speed limit (OpenStreetMap's), easing off for corners and "
            + "stopping at some lights."
    }

    private func setPhone(_ place: Place) {
        guard requirePro() else { return }
        LocalAlerts.requestPermission()
        Task {
            if let motion = phoneMotion, await motion.start(at: place.coordinate, name: place.name) {
                locations.recordRecent(place)
            }
        }
    }

    private func phoneIsAt(_ place: Place) -> Bool {
        // The exact place held: with the natural GPS on, `phone.current` wanders a few metres round it.
        guard let current = phoneMotion?.anchor ?? phone.current else { return false }
        return abs(current.latitude - place.latitude) < 1e-5 && abs(current.longitude - place.longitude) < 1e-5
    }

    private var connectPrompt: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                IconTile(symbol: "laptopcomputer.and.iphone", size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect your Mac").font(Brand.rounded(.title3))
                    Text("Your Mac holds the simulated location; this iPhone tells it where to go.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let notice = connection.unpairedNotice {
                // It was paired, and the Mac dropped it. Without this it just looks lost.
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Brand.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.rise)
            }
            Button {
                showPairing = true
            } label: {
                Label("Find My Mac", systemImage: "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .prominentButton()
            Button("Use this iPhone on its own") { withAnimation(Brand.spring) { source = .thisPhone } }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.accentText)
                .frame(maxWidth: .infinity)
        }
    }

    private func selectionRow(_ place: Place) -> some View {
        let favorite = locations.isFavorite(place)
        return HStack(spacing: 12) {
            IconTile(symbol: "mappin", colors: Brand.pin,
                     size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(Brand.rounded(.title3))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Text(place.subtitle.flatMap { $0.isEmpty ? nil : $0 } ?? place.coordinateText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(Brand.snappy) { locations.toggleFavorite(place) }
            } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(favorite ? Color.yellow : Color.secondary)
                    .symbolEffect(.bounce, value: favorite)
                    .frame(width: 44, height: 44)
                    .glassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(favorite ? "Remove from favorites" : "Add to favorites")
        }
    }

    private var actions: some View {
        GlassGroup(spacing: 10) {
            buttonRow {
                if connection.isSpoofing {
                    if let place = locations.selection, !isCurrent(place) {
                        Button {
                            send(.move, place)
                        } label: {
                            Label("Move Here", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .prominentButton()
                        .transition(.scale.combined(with: .opacity))
                    }
                    Button {
                        Task { await connection.stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .prominentButton(tint: Brand.danger)
                } else {
                    Button {
                        if let place = locations.selection { send(.start, place) }
                    } label: {
                        Label(connection.isWorking ? "Starting…" : "Start Here", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                            .contentTransition(.opacity)
                    }
                    .prominentButton()
                    .disabled(locations.selection == nil || connection.isWorking || !connection.isOnline)
                }
            }
        }
        .disabled(connection.isWorking)
    }

    private enum Command { case start, move }

    private func send(_ command: Command, _ place: Place) {
        Task {
            let ok: Bool
            switch command {
            case .start: ok = await connection.start(at: place.request)
            case .move: ok = await connection.move(to: place.request)
            }
            if ok { locations.recordRecent(place) }
        }
    }

    private func isCurrent(_ place: Place) -> Bool {
        guard let status = connection.status, let latitude = status.latitude, let longitude = status.longitude else {
            return false
        }
        return abs(latitude - place.latitude) < 1e-5 && abs(longitude - place.longitude) < 1e-5
    }
}

// MARK: - Pieces

/// Mac link + iPhone link + what's happening, in one capsule.
private struct StatusPill: View {
    let connection: ConnectionManager

    private var display: (text: String, color: Color, live: Bool) {
        switch connection.link {
        case .unpaired:
            return ("Not connected · Tap to pair", .gray, false)
        case .connecting:
            return ("Connecting to \(connection.server?.name ?? "Mac")…", Brand.sky, false)
        case .offline:
            return ("\(connection.server?.name ?? "Mac") is offline", Brand.warning, false)
        case .online:
            let name = connection.server?.name ?? "Mac"
            guard let status = connection.status else { return (name, Brand.sky, false) }
            switch status.phase {
            case .active: return ("Simulating · \(name)", Brand.live, true)
            case .starting: return ("Starting · \(name)", Brand.sky, false)
            case .reconnecting: return ("Reconnecting · \(name)", Brand.warning, false)
            case .stopping: return ("Restoring · \(name)", Brand.sky, false)
            case .failed: return ("Retrying · \(name)", Brand.danger, false)
            case .idle: return (status.connected ? "Ready · \(name)" : "\(name) · No iPhone", status.connected ? Brand.live : Brand.warning, false)
            }
        }
    }

    var body: some View {
        let display = self.display
        PillContent(text: display.text, color: display.color, live: display.live)
    }
}

/// The iPhone-only mode's status, in the same capsule.
private struct PhonePill: View {
    let phone: OnDeviceController

    private var display: (text: String, color: Color, live: Bool) {
        guard OnDeviceController.isSupported else { return ("This iPhone · Needs iOS 17", Brand.warning, false) }
        guard phone.isSetUp else { return ("This iPhone · Tap to set up", .gray, false) }
        if phone.isReconnecting { return ("Reconnecting · This iPhone", Brand.warning, false) }
        switch phone.phase {
        case .active: return ("Simulating · This iPhone", Brand.live, true)
        case .connecting: return ("Connecting · This iPhone", Brand.sky, false)
        case .stopping: return ("Stopping · This iPhone", Brand.warning, false)
        case .idle:
            if phone.loopbackReachable == false {
                // Stop turned it off on purpose, and Start turns it on again: nothing to warn about.
                if LocalDevVPN.turnedOffAtStop, !phone.onCellularOnly { return ("LocalDevVPN off · This iPhone", .gray, false) }
                return (phone.onCellularOnly ? "Needs Wi‑Fi or Airplane Mode" : "Developer connection unavailable",
                        Brand.warning, false)
            }
            if phone.pairingFileIsTooOld { return ("Needs a new pairing file", Brand.warning, false) }
            return ("Ready · This iPhone", Brand.live, false)
        }
    }

    var body: some View {
        let display = self.display
        PillContent(text: display.text, color: display.color, live: display.live)
    }
}

private struct PillContent: View {
    let text: String
    let color: Color
    let live: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 8) {
            if live {
                PulsingDot(color: color, size: 8)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(text)
                .font(.subheadline.weight(.semibold))
                // "Not connected · Tap to pair" didn't fit beside the two round buttons even
                // at the usual text size. It shrinks a little, and wraps with very large text.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .minimumScaleFactor(0.8)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassCapsule(interactive: true)
        .animation(Brand.spring, value: text)
    }
}

/// What the iPhone-only mode is holding.
private struct PhoneSimulatingRow: View {
    let name: String?
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Brand.gradient).frame(width: 44, height: 44)
                    .shadow(color: Brand.indigo.opacity(0.5), radius: 10, y: 4)
                Image(systemName: "location.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("NOW SIMULATING · THIS IPHONE")
                    .font(.caption2.weight(.bold))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                Text(name ?? "Custom location")
                    .font(Brand.rounded(.headline))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
    }
}

private struct NowSimulatingRow: View {
    let status: RemoteStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Brand.gradient).frame(width: 44, height: 44)
                    .shadow(color: Brand.indigo.opacity(0.5), radius: 10, y: 4)
                Image(systemName: "location.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && status.phase != .active)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("NOW SIMULATING")
                        .font(.caption2.weight(.bold))
                        .kerning(0.8)
                        .foregroundStyle(.secondary)
                    if let engine = status.engine {
                        Text(engine)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Brand.indigo.opacity(0.18), in: Capsule())
                    }
                }
                Text(status.placeName ?? "Custom location")
                    .font(Brand.rounded(.headline))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                if let latitude = status.latitude, let longitude = status.longitude {
                    Text(String(format: "%.5f, %.5f", latitude, longitude))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                if let detail = status.detail, status.phase != .active {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Brand.warningText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if let device = status.device {
                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: device.connection == "usb" ? "cable.connector" : "wifi")
                        .foregroundStyle(.secondary)
                    Text(device.model).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .animation(Brand.spring, value: status)
    }
}

/// A round glass button with only a symbol. `label` is what VoiceOver says,
/// and `isOn` (for a button that switches something) is its On or Off.
private struct CircleButton: View {
    let symbol: String
    let label: String
    var isOn: Bool? = nil
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 48, height: 48)
                // The whole circle takes the tap, not just the symbol (see the search bar).
                .contentShape(Circle())
                .glassCircle(tint: tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn.map { $0 ? "On" : "Off" } ?? "")
    }
}

/// The chosen spot: a gradient pin that drops in with a bounce.
private struct SelectionPin: View {
    @State private var landed = false

    var body: some View {
        ZStack(alignment: .top) {
            PinShape()
                .fill(LinearGradient(colors: Brand.pin,
                                     startPoint: .top, endPoint: .bottom))
                .overlay(PinShape().stroke(.white, lineWidth: 2.5))
                .frame(width: 34, height: 44)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
            Circle().fill(.white).frame(width: 12, height: 12).padding(.top, 11)
        }
        .scaleEffect(landed ? 1 : 0.4, anchor: .bottom)
        .offset(y: landed ? 0 : -46)
        .opacity(landed ? 1 : 0)
        .onAppear {
            withAnimation(.spring(duration: 0.55, bounce: 0.5)) { landed = true }
        }
    }
}

/// Where the Mac is holding the iPhone: a glowing dot with a ripple, amber
/// while it's (re)connecting.
private struct DeviceMarker: View {
    let phase: SpoofPhase
    @State private var ripple = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        switch phase {
        case .active: return Brand.indigo
        case .failed: return Brand.danger
        default: return Brand.warning
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.25))
                .frame(width: 70, height: 70)
                .scaleEffect(ripple ? 1.25 : 0.55)
                .opacity(ripple ? 0 : 1)
            Circle()
                .fill(.white)
                .frame(width: 26, height: 26)
                .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
            Circle()
                .fill(phase == .active ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(color))
                .frame(width: 18, height: 18)
        }
        .animation(Brand.spring, value: phase)
        .onAppear {
            // With Reduce Motion on the ripple stays out: the dot alone marks the spot.
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { ripple = true }
        }
    }
}
