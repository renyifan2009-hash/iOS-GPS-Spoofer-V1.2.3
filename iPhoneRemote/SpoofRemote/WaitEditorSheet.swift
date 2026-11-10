import PhoneOnlyCore
import SwiftUI

/// How long to stop somewhere on a route: spin the iPhone timer wheel (up to 12 hours), tap a quick
/// time, or type one ("30", "45 min", "1h 15m", "1:30"; a number on its own is minutes).
struct WaitEditorSheet: View {
    let title: String
    let prompt: String
    let initial: Double
    /// What "no wait" is called here: "Leave now" at the start, "No stop" elsewhere.
    var zeroLabel = "No wait"
    let onSave: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var wheel: Double = 900
    @State private var typing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private static let quick: [Double] = [300, 900, 1800, 3600, 7200, 4 * 3600]

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsed: WaitDuration.Parsed { WaitDuration.parse(text) }

    private var typed: Double? {
        if case .wait(let value) = parsed { return value }
        return nil
    }

    /// What Save keeps: the typed time while typing, else the wheel's.
    private var seconds: Double? { typing ? typed : wheel }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text(prompt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                if typing {
                    typedEntry
                } else {
                    CountdownWheel(seconds: $wheel)
                        .frame(height: 216)
                }
                quickPicks
                Button(typing ? "Use the wheel" : "Type a time instead") {
                    withAnimation(Brand.snappy) {
                        typing.toggle()
                        focused = typing
                        if typing, text.isEmpty { text = WaitDuration.format(wheel) }
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.accentText)
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(seconds == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if initial > 0 { wheel = min(initial, 12 * 3600) }
            text = initial > 0 ? WaitDuration.format(initial) : ""
            // A wait longer than the wheel goes (it holds 12 hours) is shown as typed.
            typing = initial > 12 * 3600
        }
    }

    private var typedEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("30, 45 min or 1h 15m", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit(save)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .padding(14)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel("How long")
            Text(feedback)
                .font(.footnote)
                .foregroundStyle(typed == nil && !trimmed.isEmpty ? Brand.danger : Color.secondary)
                .contentTransition(.opacity)
        }
        .padding(.horizontal)
    }

    private var feedback: String {
        if trimmed.isEmpty { return "A number on its own is minutes. Up to 24 hours." }
        if let typed { return typed == 0 ? zeroLabel : "Waits \(WaitDuration.format(typed))" }
        return parsed.description
    }

    private var quickPicks: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                quickButton(0)
                ForEach(Self.quick, id: \.self) { quickButton($0) }
            }
            .padding(.horizontal)
        }
    }

    /// A quick pick saves straight away: one tap for the usual times.
    private func quickButton(_ value: Double) -> some View {
        Button {
            onSave(value)
            dismiss()
        } label: {
            Text(value == 0 ? zeroLabel : WaitDuration.short(value))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .foregroundStyle(Color.primary)
                .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func save() {
        guard let seconds else { return }
        onSave(seconds)
        dismiss()
    }
}
