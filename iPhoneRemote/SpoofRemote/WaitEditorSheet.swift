import PhoneOnlyCore
import SwiftUI

/// How long to stop somewhere on a route, laid out like the iPhone Clock app's Add Alarm sheet: a round
/// ✕ and a round ✓ at the top, the timer wheel (up to 12 hours), then a short list. "Type a Time" takes
/// "30", "45 min", "1h 15m" or "1:30" (a number on its own is minutes), up to 24 hours.
struct WaitEditorSheet: View {
    let title: String
    let prompt: String
    let initial: Double
    /// What "no wait" is called here: "Leave now" at the start, "No wait" elsewhere.
    var zeroLabel = "No wait"
    /// The start of a route: shows the clock time it would leave if it started now.
    var showsLeaveTime = false
    let onSave: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var wheel: Double = 900
    @State private var noWait = false
    @State private var text = ""
    @FocusState private var typing: Bool

    private static let quick: [Double] = [300, 900, 1800, 3600, 7200, 4 * 3600, 8 * 3600, 12 * 3600]
    private static let wheelMax: Double = 12 * 3600

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsed: WaitDuration.Parsed { WaitDuration.parse(text) }

    /// A time typed in, when there is a readable one.
    private var typed: Double? {
        guard !trimmed.isEmpty, case .wait(let value) = parsed else { return nil }
        return value
    }

    /// Something typed that isn't a time: ✓ waits until it's fixed.
    private var typedIsUnreadable: Bool { !trimmed.isEmpty && typed == nil }

    /// What ✓ keeps: nothing with the switch on, else the typed time, else the wheel's.
    private var seconds: Double? {
        if noWait { return 0 }
        if typedIsUnreadable { return nil }
        return typed ?? wheel
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    CountdownWheel(seconds: $wheel, maxSeconds: Self.wheelMax)
                        .frame(height: 216)
                        .frame(maxWidth: .infinity)
                        .opacity(noWait ? 0.35 : 1)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .accessibilityLabel("How long")
                }
                Section {
                    Toggle(zeroLabel, isOn: $noWait.animation(Brand.snappy))
                    LabeledContent("Type a Time") {
                        TextField("1h 15m", text: $text)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($typing)
                            .onSubmit(save)
                            .foregroundStyle(typedIsUnreadable ? Brand.danger : Brand.accentText)
                    }
                    QuickTimeRow(seconds: quickBinding, choices: Self.quick)
                        .disabled(noWait)
                    if showsLeaveTime {
                        TimelineView(.everyMinute) { context in
                            LabeledContent("Leaves At",
                                           value: (context.date + (seconds ?? 0)).formatted(date: .omitted, time: .shortened))
                        }
                    }
                } footer: {
                    Text(footer)
                        .foregroundStyle(typedIsUnreadable ? Brand.danger : Color.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            .alarmSheetToolbar(title: title, confirmDisabled: seconds == nil,
                               onCancel: { dismiss() }, onConfirm: save)
        }
        .presentationDetents([.large])
        .onAppear {
            noWait = initial <= 0
            if initial > 0 { wheel = min(initial, Self.wheelMax) }
            // A wait longer than the wheel goes (it holds 12 hours) is shown as typed.
            text = initial > Self.wheelMax ? WaitDuration.format(initial) : ""
        }
        .onChange(of: text) {
            guard let typed else { return }
            if typed == 0 { noWait = true; return }
            noWait = false
            // Past the wheel's 12 hours, it rests at its end and the typed time is what counts.
            wheel = min(max(60, typed), Self.wheelMax)
        }
        .onChange(of: wheel) {
            if let typed {
                // The wheel showing what was typed (held to 1 minute…12 hours) isn't the person spinning it:
                // a typed 18 h shows as 12 h on the wheel and must stay 18 h.
                let shown = min(max(60, typed), Self.wheelMax)
                guard abs(shown - wheel) >= 30 else { return }
                text = ""   // they spun it after typing: the wheel wins
            }
            // Spinning the wheel picks a wait, so it isn't "Leave now" any more.
            if noWait { withAnimation(Brand.snappy) { noWait = false } }
        }
    }

    private var quickBinding: Binding<Double> {
        Binding(get: { typed ?? wheel },
                set: { value in
                    withAnimation(Brand.snappy) {
                        noWait = false
                        text = ""
                        wheel = value
                    }
                })
    }

    private var footer: String {
        if typedIsUnreadable { return parsed.description }
        if let typed, typed > Self.wheelMax { return "\(prompt) Waits \(WaitDuration.format(typed))." }
        if showsLeaveTime { return "\(prompt) Leaves At is for a route started now." }
        return prompt
    }

    private func save() {
        guard let seconds else { return }
        onSave(seconds)
        dismiss()
    }
}

/// "Quick Time  15 min": a menu of the usual times, its value in the accent color like the Clock app's
/// Snooze Duration. Shows "Custom" when the wheel is on another time.
struct QuickTimeRow: View {
    @Binding var seconds: Double
    let choices: [Double]
    @Environment(\.isEnabled) private var isEnabled

    private var match: Double? { choices.first { abs($0 - seconds) < 30 } }

    var body: some View {
        LabeledContent("Quick Time") {
            Menu {
                ForEach(choices, id: \.self) { value in
                    Button {
                        seconds = value
                    } label: {
                        if match == value {
                            Label(WaitDuration.format(value), systemImage: "checkmark")
                        } else {
                            Text(WaitDuration.format(value))
                        }
                    }
                }
            } label: {
                Text(match.map(WaitDuration.format) ?? "Custom")
                    .foregroundStyle(isEnabled ? Brand.accentText : Color.secondary)
            }
        }
    }
}

extension View {
    /// The top of the Clock app's Add Alarm sheet: a round ✕ on the left, the title, and a round,
    /// filled ✓ on the right.
    func alarmSheetToolbar(title: String, confirmLabel: String = "Save", confirmDisabled: Bool = false,
                           onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onCancel) { Image(systemName: "xmark").foregroundStyle(Color.primary) }
                        .roundToolbarButton(prominent: false)
                        .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onConfirm) { Image(systemName: "checkmark").foregroundStyle(Color.white) }
                        .roundToolbarButton(prominent: true)
                        .disabled(confirmDisabled)
                        .accessibilityLabel(confirmLabel)
                }
            }
    }

    /// On iOS 26 the toolbar already draws round glass buttons; the ✓ gets the accent fill. Before 26,
    /// draw the circles.
    @ViewBuilder
    fileprivate func roundToolbarButton(prominent: Bool) -> some View {
        #if canImport(SwiftUI, _version: 7.0)
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent).tint(Brand.indigo)
            } else {
                self
            }
        } else {
            self.buttonStyle(RoundToolbarFallbackStyle(prominent: prominent))
        }
        #else
        self.buttonStyle(RoundToolbarFallbackStyle(prominent: prominent))
        #endif
    }
}

/// Before iOS 26: a 32 pt circle, filled with the accent for ✓, a light gray for ✕.
private struct RoundToolbarFallbackStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(width: 32, height: 32)
            .background(Circle().fill(prominent ? AnyShapeStyle(Brand.indigo) : AnyShapeStyle(Color.primary.opacity(0.1))))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}
