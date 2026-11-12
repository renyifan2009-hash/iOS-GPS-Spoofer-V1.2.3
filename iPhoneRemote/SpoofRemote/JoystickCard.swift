import Observation
import PhoneOnlyCore
import RemoteAPI
import SwiftUI

/// Steers the Mac's location: turns the thumb into a heading and a speed (`JoystickInput`, which has the
/// tests) and keeps sending it while the thumb is down. The Mac moves that way until the next message and
/// stops by itself if none arrives for a second and a half, so a dropped connection can't run away.
@MainActor
@Observable
final class JoystickModel {
    /// The speed at full deflection. nil means "Custom" (`customKmh`).
    var preset: JoystickPreset? = .walk
    var customKmh: Double = SpeedUnits.current.imperial ? SpeedUnits.current.kmh(fromDisplay: 15) : 25
    /// Up on the pad is "up on the screen" (turns with the map) instead of north.
    var relativeToMap = false
    /// The map keeps the simulated location in view while steering.
    var followsMarker = true
    /// How far the map is turned, degrees clockwise.
    private(set) var mapHeading = 0.0
    /// The thumb, for drawing: x right, y up, -1...1.
    private(set) var thumb = CGVector.zero
    /// What is being sent now.
    private(set) var current = JoystickInput.idle
    /// Why the Mac refused or couldn't be reached, until the next message gets through.
    private(set) var problem: String?

    var topSpeed: Double {
        preset?.metersPerSecond ?? JoystickPreset.metersPerSecond(fromKmh: customKmh)
    }

    @ObservationIgnored private var holding = false
    @ObservationIgnored private var sendTask: Task<Void, Never>?

    func setMapHeading(_ degrees: Double) {
        let wrapped = JoystickInput.wrap(degrees)
        if abs(wrapped - mapHeading) > 0.5 { mapHeading = wrapped }
    }

    /// The thumb moved: x right, y up.
    func thumbMoved(to vector: CGVector, connection: any ControlTarget) {
        holding = true
        thumb = vector
        let input = JoystickInput.make(x: Double(vector.dx), y: Double(vector.dy), topSpeed: topSpeed,
                                       mapHeading: mapHeading, relativeToMap: relativeToMap)
        if input != current { current = input }
        sendWhileHeld(connection)
    }

    func thumbLifted(connection: any ControlTarget) {
        holding = false
        thumb = .zero
        current = .idle
        // The loop sends this "stand still" once, then ends.
        sendWhileHeld(connection)
    }

    /// For VoiceOver: a short push in a compass direction, then stand still.
    func nudge(heading: Double, seconds: Double = 2, connection: any ControlTarget) {
        sendTask?.cancel()
        sendTask = Task { [weak self] in
            guard let self else { return }
            let speed = min(self.topSpeed * 0.7, JoystickInput.maxSpeed)
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, !Task.isCancelled {
                self.current = JoystickInput(heading: heading, speed: speed)
                self.problem = await connection.steer(heading: heading, speed: speed)
                try? await Task.sleep(for: .milliseconds(350))
            }
            self.current = .idle
            self.problem = await connection.steer(heading: heading, speed: 0)
            self.sendTask = nil
        }
    }

    /// Stand still and stop sending (the screen went away or the app went to the background).
    func release(connection: any ControlTarget) {
        guard holding || sendTask != nil else { return }
        thumbLifted(connection: connection)
    }

    private func sendWhileHeld(_ connection: any ControlTarget) {
        guard sendTask == nil else { return }
        sendTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let wasHolding = self.holding
                let input = self.current
                let message = await connection.steer(heading: input.heading, speed: input.speed)
                if message != self.problem { self.problem = message }
                if !wasHolding { break }          // the "stand still" after the thumb lifted has gone out
                try? await Task.sleep(for: .milliseconds(350))
            }
            self?.sendTask = nil
            // Touched again while the last message was in flight.
            if let self, self.holding { self.sendWhileHeld(connection) }
        }
    }
}

// MARK: - The thumbstick

/// A round pad with a thumb that follows the finger and springs back. Dragging steers; VoiceOver users get
/// "Move north/east/south/west" actions instead, since dragging a thumb isn't something they can do.
struct JoystickPad: View {
    var isEnabled = true
    var onMove: (CGVector) -> Void
    var onLift: () -> Void
    var onNudge: (Double) -> Void

    @State private var offset = CGSize.zero
    private let diameter: CGFloat = 152
    private let thumbDiameter: CGFloat = 60

    private var travel: CGFloat { (diameter - thumbDiameter) / 2 }

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            // Compass marks, so "up" is clear.
            ForEach(0..<4, id: \.self) { index in
                let angle = Double(index) * .pi / 2
                Text(["N", "E", "S", "W"][index])
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .position(x: diameter / 2 + CGFloat(sin(angle)) * (diameter / 2 - 14),
                              y: diameter / 2 - CGFloat(cos(angle)) * (diameter / 2 - 14))
            }
            Circle()
                .fill(Brand.gradient)
                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
                .shadow(color: Brand.indigo.opacity(0.45), radius: 10, y: 4)
                .frame(width: thumbDiameter, height: thumbDiameter)
                .offset(offset)
                .opacity(isEnabled ? 1 : 0.4)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(isEnabled ? drag : nil)
        .sensoryFeedback(.impact(weight: .light), trigger: offset == .zero)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Joystick")
        .accessibilityHint("Dragging steers. VoiceOver: use the move actions.")
        .accessibilityAction(named: "Move north") { onNudge(0) }
        .accessibilityAction(named: "Move east") { onNudge(90) }
        .accessibilityAction(named: "Move south") { onNudge(180) }
        .accessibilityAction(named: "Move west") { onNudge(270) }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                var dx = value.location.x - diameter / 2
                var dy = value.location.y - diameter / 2
                let length = hypot(dx, dy)
                if length > travel {            // the thumb stops at the edge
                    dx *= travel / length
                    dy *= travel / length
                }
                offset = CGSize(width: dx, height: dy)
                // Screen y grows downward; the pad's "up" is positive.
                onMove(CGVector(dx: dx / travel, dy: -dy / travel))
            }
            .onEnded { _ in
                withAnimation(Brand.snappy) { offset = .zero }
                onLift()
            }
    }
}

// MARK: - The card

/// Steer from the iPhone: pick a pace, drag the pad.
struct JoystickCardView: View {
    @Bindable var joystick: JoystickModel
    var connection: any ControlTarget
    var hasPlace: Bool

    @Environment(\.scenePhase) private var scenePhase
    /// Redraws this view when Settings switches miles and kilometres.
    @AppStorage(UnitsChoice.key) private var unitsChoice: UnitsChoice = .automatic

    private var status: RemoteStatus? { connection.status }
    private var held: Bool { connection.isSpoofing }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if held {
                pace
                HStack(alignment: .center, spacing: 16) {
                    JoystickPad(isEnabled: !connection.isWorking,
                                onMove: { joystick.thumbMoved(to: $0, connection: connection) },
                                onLift: { joystick.thumbLifted(connection: connection) },
                                onNudge: { joystick.nudge(heading: $0, connection: connection) })
                    controls
                }
                .frame(maxWidth: .infinity)
                if let problem = joystick.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Brand.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.rise)
                }
            } else {
                Text(hasPlace ? "Start from the place you picked, then steer with the pad."
                              : "Tap the map to choose where to start.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Brand.spring, value: held)
        .animation(Brand.spring, value: joystick.problem)
        .onDisappear { joystick.release(connection: connection) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { joystick.release(connection: connection) }
        }
        .onChange(of: held) { _, nowHeld in
            if !nowHeld { joystick.release(connection: connection) }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "gamecontroller.fill", size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("Joystick").font(Brand.rounded(.title3))
                Text(readout)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
            if held { AutoStopRow(connection: connection, compact: true) }
        }
    }

    /// What the Mac says it is doing, or what to do.
    private var readout: String {
        guard held else { return "Steer with your thumb" }
        guard let status, status.activity == "joystick", let speed = status.speed, speed > 0.05 else {
            return status?.placeName ?? "Drag the pad to move"
        }
        let pace = RouteText.speed(speed)
        guard let heading = status.heading else { return pace }
        return "\(pace) \(JoystickInput.compassPoint(heading))"
    }

    private var pace: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(JoystickPreset.allCases) { preset in
                    paceButton(label: preset.label, symbol: preset.symbol, selected: joystick.preset == preset) {
                        joystick.preset = preset
                    }
                }
                paceButton(label: "Custom", symbol: "slider.horizontal.3", selected: joystick.preset == nil) {
                    joystick.preset = nil
                }
            }
            if joystick.preset == nil {
                HStack(spacing: 12) {
                    Slider(value: Binding(get: { SpeedUnits.current.display(kmh: joystick.customKmh) },
                                          set: { joystick.customKmh = SpeedUnits.current.kmh(fromDisplay: $0) }),
                           in: SpeedUnits.current.joystickRange, step: 1)
                        .accessibilityLabel("Top speed")
                        .accessibilityValue(customSpeedText)
                    Text(customSpeedText)
                        .font(.system(.subheadline, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 64, alignment: .trailing)
                }
                .transition(.rise)
            }
        }
        .animation(Brand.snappy, value: joystick.preset)
    }

    private var customSpeedText: String {
        RouteText.speed(joystick.topSpeed)
    }

    private func paceButton(label: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                Text(label).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.indigo)
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.07))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Beside the pad: which way is up, and whether the map follows.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Up means", selection: $joystick.relativeToMap) {
                Text("North").tag(false)
                Text("Map").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Whether up on the pad means north, or up on the screen as the map is turned")
            Toggle(isOn: $joystick.followsMarker) {
                Label("Follow", systemImage: "scope")
                    .font(.subheadline.weight(.semibold))
            }
            .toggleStyle(.button)
            .tint(Brand.indigo)
        }
        .frame(maxWidth: .infinity)
    }
}
