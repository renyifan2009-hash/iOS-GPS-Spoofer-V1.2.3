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
    /// The Me tab is open (the other three tabs are `macMode`).
    @State private var showsMe = false
    /// How far the panel at the bottom is pulled up.
    @State private var panelDetent: PanelDetent = .medium
    /// The map's satellite view, from the map button at the top right.
    @AppStorage("mapHybrid") private var mapHybrid = false
    /// Lets the compass sit under the map buttons instead of on top of them.
    @Namespace private var mapScope
    /// How far out the map is, so following the simulated location keeps the zoom.
    @State private var mapDistance: CLLocationDistance = 3500
    /// The iPhone was on cellular data alone and hasn't finished the Airplane Mode steps: show them, and
    /// once a location runs in Airplane Mode, say it's time to turn Airplane Mode off.
    @State private var cellularGuide = false
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

    /// How much of the screen the panel takes at its middle height. Steering needs the pad and its
    /// pace row, and a route its stops; the rest of the time the map matters more.
    private var mediumFraction: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 0.66 }
        if showsMe { return 0.56 }
        switch macMode {
        case .joystick: return isSpoofing ? 0.66 : 0.46
        case .route: return 0.56
        case .teleport: return 0.46
        }
    }

    /// The tab that's open.
    private var currentTab: MainTab {
        if showsMe { return .me }
        switch macMode {
        case .teleport: return .teleport
        case .route: return .route
        case .joystick: return .joystick
        }
    }

    private var tabSelection: Binding<MainTab> {
        Binding(get: { currentTab }, set: { tab in
            switch tab {
            case .me: showsMe = true
            case .teleport: showsMe = false; macMode = .teleport
            case .route: showsMe = false; macMode = .route
            case .joystick: showsMe = false; macMode = .joystick
            }
            // A tab opened from the folded-down panel shows what's in it.
            if panelDetent == .collapsed { panelDetent = .medium }
        })
    }

    var body: some View {
        GeometryReader { screen in
            ZStack {
                map
                // Find My's map buttons: in glass at the top right, the compass under them.
                VStack(alignment: .trailing, spacing: 10) {
                    overMap("mapButtons", MapControlStack(hybrid: $mapHybrid,
                                                          showsLocation: locations.showsReportedLocation) {
                        withAnimation(Brand.snappy) { locations.toggleReportedLocation() }
                    })
                    MapCompass(scope: mapScope)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
                .padding(.top, 4)
                // At full height the panel covers them.
                .opacity(panelDetent == .large ? 0 : 1)
                .allowsHitTesting(panelDetent != .large)
                .accessibilityHidden(panelDetent == .large)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    overMap("card", panel(screen))
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .ignoresSafeArea(.container, edges: .bottom)
            }
            .coordinateSpace(.named(Self.screenSpace))
            .mapScope(mapScope)
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
        .onChange(of: phone.onCellularOnly) { _, cellularOnly in
            // Cellular alone: the Airplane Mode steps start. Back on cellular with a location running:
            // Airplane Mode is off again, and the steps are done.
            if cellularOnly { cellularGuide = !phone.isSpoofing }
        }
        .onChange(of: phone.isSpoofing) { _, spoofing in
            if !spoofing, !phone.onCellularOnly { cellularGuide = false }
        }
        .onChange(of: phone.onWiFi) { _, wifi in
            // On Wi‑Fi LocalDevVPN works as it is: no Airplane Mode steps.
            if wifi { cellularGuide = false }
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
        .onChange(of: locations.selection?.id) { _, id in
            // A place was picked (on the map, in search, from a list): the folded panel opens to show
            // its Start.
            if id != nil, panelDetent == .collapsed { withAnimation(Brand.spring) { panelDetent = .medium } }
        }
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
            Map(position: $locations.camera, scope: mapScope) {
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
            // The standard map, as in Find My, or satellite from the map button.
            .mapStyle(mapHybrid ? .hybrid(elevation: .realistic) : .standard(elevation: .realistic))
            .mapControls {
                // The compass is in the stack at the top right.
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
                // (The map buttons are hidden at full height; their spot is the map's then.)
                let controls = controlFrames.filter { panelDetent != .large || $0.key != "mapButtons" }
                guard !controls.values.contains(where: { $0.contains(point) }),
                      let coordinate = proxy.convert(point, from: .named(Self.screenSpace)) else { return }
                withAnimation(Brand.spring) {
                    // From the Me tab, a tap on the map goes back to the tab it's for.
                    showsMe = false
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

    // MARK: - The panel

    /// Find My's floating panel: the title, what's happening and the search button at the top, the
    /// tab's controls under them, and the tabs along the bottom.
    private func panel(_ screen: GeometryProxy) -> some View {
        FindMyPanel(detent: $panelDetent,
                    screenHeight: screen.size.height + screen.safeAreaInsets.top + screen.safeAreaInsets.bottom,
                    mediumFraction: mediumFraction,
                    bottomInset: screen.safeAreaInsets.bottom) {
            panelHeader
        } content: {
            panelContent
        } footer: {
            PanelTabBar(selection: tabSelection)
        }
    }

    private var panelTitle: String {
        switch currentTab {
        case .teleport: locations.selection?.name ?? "Teleport"
        case .route: route.name ?? "Route"
        case .joystick: "Joystick"
        case .me: "Me"
        }
    }

    /// Under the title, for a chosen place: its address, as Find My shows a person's.
    private var panelSubtitle: String? {
        guard currentTab == .teleport, let place = locations.selection else { return nil }
        return place.subtitle.flatMap { $0.isEmpty ? nil : $0 } ?? place.coordinateText
    }

    private var panelHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(panelTitle)
                    .font(.title.bold())
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle = panelSubtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                statusLine
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if currentTab == .me {
                    PanelHeaderButton(symbol: "gearshape", label: "Settings") { showSettings = true }
                } else {
                    PanelHeaderButton(symbol: "magnifyingglass", label: "Search for a place") { showSearch = true }
                }
                if currentTab == .teleport, locations.selection != nil {
                    PanelHeaderButton(symbol: "xmark", label: "Clear the chosen place") {
                        withAnimation(Brand.spring) { locations.selection = nil }
                    }
                }
            }
            .padding(.top, 2)
        }
        .animation(Brand.spring, value: panelTitle)
    }

    /// What's happening, in colour like Find My's green "Now". A tap opens the setup or the pairing.
    private var statusLine: some View {
        let display = source == .thisPhone ? PhonePill(phone: phone).display : StatusPill(connection: connection).display
        return Button {
            if source == .thisPhone { showPhoneSetup = true } else { showPairing = true }
        } label: {
            HStack(spacing: 6) {
                if display.live {
                    PulsingDot(color: display.color, size: 7)
                } else {
                    Circle().fill(display.color).frame(width: 7, height: 7)
                }
                Text(display.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusTextColor(display.color))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                    .contentTransition(.opacity)
            }
            // A taller place to tap than the line itself, without making the header taller.
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .padding(.vertical, -10)
        }
        .buttonStyle(.plain)
        .accessibilityHint(source == .thisPhone ? "Opens the setup for this iPhone" : "Opens the pairing with your Mac")
        .animation(Brand.spring, value: display.text)
    }

    /// Gray says nothing's wrong; green and orange are darkened to read as text.
    private func statusTextColor(_ color: Color) -> Color {
        if color == .gray { return .secondary }
        if color == Brand.warning { return Brand.warningText }
        if color == Brand.live { return Brand.liveText }
        return color
    }

    /// About the whole app, not one tab: the other source holding a location, signing about to run out,
    /// a newer version. Each tab puts them under its buttons, so Start and Stop stay in view.
    @ViewBuilder
    private var notices: some View {
        otherSourceHoldingNotice
        if SigningStatus.isEndingSoon {
            signingNotice.transition(.rise)
        }
        UpdateNoticeView()
    }

    /// The open tab, with the notices under its buttons.
    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsMe {
                notices
                meContent
                    .transition(.opacity)
            } else if source == .thisPhone {
                phoneCard
            } else {
                macCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .animation(Brand.spring, value: source)
        .animation(Brand.spring, value: macMode)
        .animation(Brand.spring, value: showsMe)
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

    // MARK: - Me

    private var isBusy: Bool { isSpoofing || phone.isWorking || connection.isWorking }

    /// Where the location is controlled from, the iPhone and the Mac, Settings and the plan.
    private var meContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Control From")
                    .font(.title3.bold())
                Picker("Control from", selection: $source.animation(Brand.spring)) {
                    Text("This iPhone").tag(LocationSource.thisPhone)
                    Text("Mac").tag(LocationSource.mac)
                }
                .pickerStyle(.segmented)
                .disabled(isBusy)
                if phone.isSpoofing {
                    holdingRow("This iPhone is holding a location.") { _ = await phoneMotion?.stop() }
                } else if connection.isSpoofing {
                    holdingRow("The Mac is holding a location.") { _ = await connection.stop() }
                }
                Text(isBusy ? "Stop the current location to switch."
                            : "This iPhone works on its own with LocalDevVPN. A Mac holds the location over a cable or Wi‑Fi.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GroupedCard {
                PanelRow(symbol: "iphone", title: "This iPhone", value: phoneSetupValue) { presentPhoneSetup() }
                Divider().padding(.leading, 40)
                PanelRow(symbol: "laptopcomputer", title: "Mac",
                         value: connection.isPaired ? (connection.server?.name ?? "Paired") : "Not paired") {
                    showPairing = true
                }
            }
            GroupedCard {
                PanelRow(symbol: "gearshape", title: "Settings") { showSettings = true }
                if PaymentsConfig.isEnabled {
                    Divider().padding(.leading, 40)
                    PanelRow(symbol: "sparkles", title: "AnyWhere Pro", value: licenses.summary) { showPaywall = true }
                }
            }
            Text(appVersion)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private var phoneSetupValue: String {
        guard OnDeviceController.isSupported else { return "Needs iOS 17" }
        return phone.isSetUp ? "Ready" : "Set Up"
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "AnyWhere \(version) (\(build))"
    }

    // MARK: - Places

    /// A Teleport tab with nothing chosen: how to pick a place, then the favourites and recent places,
    /// as Find My lists people.
    @ViewBuilder
    private var placesList: some View {
        Label("Tap the map or search to pick a place.", systemImage: "hand.tap.fill")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .transition(.rise)
        if !locations.favorites.isEmpty {
            placeSection("Favorites", Array(locations.favorites), symbol: "star.fill", tint: .orange)
                .transition(.rise)
        }
        let recents = locations.recents.filter { recent in
            !locations.favorites.contains { $0.isSameSpot(as: recent) }
        }
        if !recents.isEmpty {
            placeSection("Recents", Array(recents.prefix(6)), symbol: "clock.fill", tint: .gray)
                .transition(.rise)
        }
    }

    private func placeSection(_ title: String, _ places: [Place], symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title3.bold())
                .padding(.bottom, 2)
            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                if index > 0 { Divider().padding(.leading, 56) }
                PanelPlaceRow(symbol: symbol, tint: tint, title: place.name,
                              subtitle: place.subtitle.flatMap { $0.isEmpty ? nil : $0 } ?? place.coordinateText) {
                    withAnimation(Brand.spring) { locations.select(place) }
                }
            }
        }
    }

    /// Find My's star: add the chosen place to Favorites, or take it off.
    private func favoriteTile(_ place: Place) -> some View {
        let favorite = locations.isFavorite(place)
        return ActionTile(symbol: favorite ? "star.fill" : "star", title: favorite ? "Favorite" : "Add to Favorites",
                          iconColor: favorite ? .orange : Brand.sky) {
            withAnimation(Brand.snappy) { locations.toggleFavorite(place) }
        }
        .accessibilityLabel(favorite ? "Remove from favorites" : "Add to favorites")
    }

    // MARK: - Mac actions

    private var macTeleportTiles: some View {
        buttonRow {
            if connection.isSpoofing {
                if let place = locations.selection, !isCurrent(place) {
                    ActionTile(symbol: "arrow.triangle.turn.up.right.diamond.fill", title: "Move Here", fill: Brand.sky) {
                        send(.move, place)
                    }
                    .disabled(connection.isWorking)
                    .transition(.scale.combined(with: .opacity))
                }
                ActionTile(symbol: "stop.fill", title: "Stop", fill: Brand.danger) {
                    Task { await connection.stop() }
                }
                .disabled(connection.isWorking)
            } else {
                ActionTile(symbol: "location.fill", title: connection.isWorking ? "Starting…" : "Start Here", fill: Brand.sky) {
                    if let place = locations.selection { send(.start, place) }
                }
                .disabled(locations.selection == nil || connection.isWorking || !connection.isOnline)
            }
            if let place = locations.selection { favoriteTile(place) }
        }
    }

    private var macRouteTiles: some View {
        buttonRow {
            ActionTile(symbol: route.driving ? "car.fill" : "figure.walk",
                       title: connection.findingRoads ? "Finding roads…" : connection.isWorking ? "Starting…" : "Drive Route",
                       fill: Brand.sky) {
                driveRoute()
            }
            .disabled(!route.canDrive || connection.isWorking || connection.findingRoads || !connection.isOnline)
        }
    }

    private var macJoystickTiles: some View {
        buttonRow {
            if connection.isSpoofing {
                ActionTile(symbol: "stop.fill", title: "Stop", fill: Brand.danger) {
                    Task { await connection.stop() }
                }
            } else {
                ActionTile(symbol: "gamecontroller.fill", title: connection.isWorking ? "Starting…" : "Start Joystick",
                           fill: Brand.sky) {
                    startJoystick()
                }
                .disabled(locations.selection == nil || !connection.isOnline)
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
            notices
            connectPrompt
                .transition(.rise)
        } else {
            if let status = connection.status, !status.connected, connection.isOnline {
                Label("The Mac can't see this iPhone. Connect them with a cable and tap Trust.",
                      systemImage: "cable.connector")
                    .font(.footnote)
                    .foregroundStyle(Brand.warningText)
                    .transition(.rise)
            }
            switch macMode {
            case .teleport:
                if locations.selection != nil || connection.isSpoofing {
                    macTeleportTiles
                        .transition(.rise)
                }
                notices
                if connection.isSpoofing, let status = connection.status {
                    NowSimulatingRow(status: status)
                        .transition(.rise)
                    AutoStopRow(connection: connection)
                        .transition(.rise)
                }
                if locations.selection == nil, !connection.isSpoofing {
                    placesList
                }
            case .route:
                if isDrivingRoute {
                    notices
                    RouteProgressCardView(route: route, connection: connection)
                        .transition(.rise)
                } else {
                    macRouteTiles
                        .transition(.rise)
                    notices
                    // Something held already: say what, with its Stop. Building a route needs the room.
                    if connection.isSpoofing, let status = connection.status {
                        HeldStrip(status: status, connection: connection)
                            .transition(.rise)
                    }
                    RouteCardView(route: route, connection: connection, library: routeLibrary)
                        .transition(.rise)
                }
            case .joystick:
                // Steering says where it is, and how fast, in its own header.
                macJoystickTiles
                    .transition(.rise)
                notices
                JoystickCardView(joystick: joystick, connection: connection,
                                 hasPlace: locations.selection != nil || connection.isSpoofing)
                    .transition(.rise)
            }
            if let error = connection.lastError {
                ErrorNotice(message: error)
                    .transition(.rise)
            } else if case .offline(let reason) = connection.link {
                // The status line only says "offline". This says why, and what to try.
                Label(reason, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(Brand.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.rise)
            }
        }
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
            notices
            phoneSetupPrompt
                .transition(.rise)
        } else {
            if let motion = phoneMotion {
                switch macMode {
                case .teleport:
                    if locations.selection != nil || phone.isSpoofing {
                        phoneTeleportTiles
                            .transition(.rise)
                    }
                    notices
                    cellularSteps
                    phoneHeldRow
                    if phone.isSpoofing {
                        AutoStopRow(connection: motion)
                            .transition(.rise)
                    }
                    if locations.selection == nil, !phone.isSpoofing {
                        placesList
                    }
                case .route:
                    if motion.planning || motion.activity == "route", phone.isSpoofing || motion.planning {
                        notices
                        cellularSteps
                        phoneHeldRow
                        RouteProgressCardView(route: route, connection: motion)
                    } else {
                        buttonRow {
                            ActionTile(symbol: "play.fill", title: "Drive Route", fill: Brand.sky) {
                                guard requirePro(), let request = route.request() else { return }
                                let snapshot = route.snapshot(named: route.name ?? "iPhone route")
                                let limits = route.driving && route.natural && route.followRoads && route.followSpeedLimits
                                Task {
                                    if await motion.driveRoute(request, followSpeedLimits: limits) {
                                        routeLibrary.recordRecent(snapshot)
                                    }
                                }
                            }
                            .disabled(!route.canDrive || motion.isWorking)
                            if phone.isSpoofing {
                                ActionTile(symbol: "stop.fill", title: "Stop", fill: Brand.danger) {
                                    Task { _ = await motion.stop() }
                                }
                            }
                        }
                        notices
                        cellularSteps
                        phoneHeldRow
                        RouteCardView(route: route, connection: motion, library: routeLibrary)
                        Text(phoneRouteNote)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                case .joystick:
                    buttonRow {
                        if phone.isSpoofing {
                            ActionTile(symbol: "stop.fill", title: "Stop", fill: Brand.danger) {
                                Task { _ = await motion.stop() }
                            }
                        } else {
                            ActionTile(symbol: "gamecontroller.fill", title: "Start Joystick", fill: Brand.sky) {
                                guard requirePro(), let place = locations.selection else { return }
                                Task { _ = await motion.start(at: place.coordinate, name: place.name, joystick: true) }
                            }
                            .disabled(locations.selection == nil || motion.isWorking)
                        }
                    }
                    notices
                    cellularSteps
                    phoneHeldRow
                    JoystickCardView(joystick: joystick, connection: motion, hasPlace: locations.selection != nil)
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
                    Text("Use this iPhone on its own").font(.title3.bold())
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

    /// What this iPhone is holding, on every tab: where it is, while a route or the joystick runs too.
    @ViewBuilder
    private var phoneHeldRow: some View {
        if phone.isSpoofing, let current = phone.current {
            PhoneSimulatingRow(name: phone.currentName, coordinate: current)
                .transition(.rise)
        }
    }

    /// On cellular data alone: the Airplane Mode steps, right under the button they lead to. Once it runs
    /// in Airplane Mode, the word to turn Airplane Mode off.
    @ViewBuilder
    private var cellularSteps: some View {
        if !phone.isSpoofing, phone.onCellularOnly || cellularGuide {
            CellularStepsCard(inAirplaneMode: !phone.onCellularOnly)
                .transition(.rise)
        } else if phone.isSpoofing, cellularGuide, !phone.onCellularOnly {
            Label("It's running. Turn Airplane Mode off now; the location keeps going.",
                  systemImage: "airplane.departure")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.liveText)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.rise)
        }
    }

    private var phoneTeleportTiles: some View {
        buttonRow {
            if phone.isSpoofing {
                if let place = locations.selection, !phoneIsAt(place) {
                    ActionTile(symbol: "arrow.triangle.turn.up.right.diamond.fill", title: "Move Here", fill: Brand.sky) {
                        setPhone(place)
                    }
                    .disabled(phone.isWorking)
                    .transition(.scale.combined(with: .opacity))
                }
                ActionTile(symbol: "stop.fill", title: "Stop", fill: Brand.danger) {
                    Task { _ = await phoneMotion?.stop() }
                }
                .disabled(phone.isWorking)
            } else {
                ActionTile(symbol: "location.fill",
                           title: phone.phase == .stopping ? "Stopping…" : (phone.isWorking ? "Starting…" : "Start Here"),
                           fill: Brand.sky) {
                    if let place = locations.selection { setPhone(place) }
                }
                .disabled(locations.selection == nil || phone.isWorking)
            }
            if let place = locations.selection { favoriteTile(place) }
        }
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
                    Text("Connect your Mac").font(.title3.bold())
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

/// Mac link + iPhone link + what's happening, for the line under the panel's title.
@MainActor
private struct StatusPill {
    let connection: ConnectionManager

    var display: (text: String, color: Color, live: Bool) {
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
}

/// The iPhone-only mode's status, for the same line.
@MainActor
private struct PhonePill {
    let phone: OnDeviceController

    var display: (text: String, color: Color, live: Bool) {
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
}

/// The round green icon of what's being held, like a person's in Find My.
private struct HeldIcon: View {
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(Brand.live.gradient)
            Image(systemName: "location.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating, isActive: pulsing && !reduceMotion)
        }
        .frame(width: 44, height: 44)
    }
}

/// What the iPhone-only mode is holding.
private struct PhoneSimulatingRow: View {
    let name: String?
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        HStack(spacing: 12) {
            HeldIcon()
            VStack(alignment: .leading, spacing: 2) {
                Text(name ?? "Custom location")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                HStack(spacing: 4) {
                    Text("Now").foregroundStyle(Brand.liveText).fontWeight(.semibold)
                    Text("· This iPhone").foregroundStyle(.secondary)
                }
                .font(.subheadline)
                Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now simulating \(name ?? "a custom location") on this iPhone")
    }
}

/// What the Mac is holding.
private struct NowSimulatingRow: View {
    let status: RemoteStatus

    var body: some View {
        HStack(spacing: 12) {
            HeldIcon(pulsing: status.phase != .active)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.placeName ?? "Custom location")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                HStack(spacing: 4) {
                    Text(status.phase == .active ? "Now" : "Starting")
                        .foregroundStyle(status.phase == .active ? Brand.liveText : Brand.warningText)
                        .fontWeight(.semibold)
                    if let engine = status.engine {
                        Text("· \(engine)").foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
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
        // Green like Find My's "Now": iOS's own location dot (the map button) is blue.
        case .active: return Brand.live
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
                .fill(color.gradient)
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

/// What to do when the iPhone is on cellular data alone: iOS blocks LocalDevVPN there, but a location
/// started in Airplane Mode keeps going once Airplane Mode is turned off again.
private struct CellularStepsCard: View {
    /// Step 1 is done: the iPhone isn't on cellular now.
    let inAirplaneMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("On cellular data only", systemImage: "antenna.radiowaves.left.and.right")
                .font(.subheadline.weight(.semibold))
            Text("iOS blocks LocalDevVPN on cellular, so:")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(Array(TunnelFailure.cellularSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: index == 0 && inAirplaneMode ? "checkmark.circle.fill" : "\(index + 1).circle")
                        .foregroundStyle(index == 0 && inAirplaneMode ? Brand.live : .secondary)
                    Text(step)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("If LocalDevVPN is off, turn Airplane Mode off, connect LocalDevVPN, then start again from step 1.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 18, tint: Brand.warning)
        .accessibilityElement(children: .combine)
    }
}
