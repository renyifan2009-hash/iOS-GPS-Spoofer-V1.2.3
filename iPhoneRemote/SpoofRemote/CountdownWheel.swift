import PhoneOnlyCore
import SwiftUI
import UIKit

/// The iPhone Clock app's timer wheel (hours and minutes), held to `maxSeconds`. It can't show zero:
/// the shortest is a minute, like the Clock app's.
struct CountdownWheel: UIViewRepresentable {
    @Binding var seconds: Double
    var maxSeconds: Double = 12 * 3600

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .countDownTimer
        picker.minuteInterval = 1
        picker.countDownDuration = clamp(seconds)
        picker.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return picker
    }

    func updateUIView(_ picker: UIDatePicker, context: Context) {
        context.coordinator.parent = self
        let wanted = clamp(seconds)
        if abs(picker.countDownDuration - wanted) >= 30 { picker.countDownDuration = wanted }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    fileprivate func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 60 }
        return min(max(value, 60), maxSeconds)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: CountdownWheel
        init(_ parent: CountdownWheel) { self.parent = parent }

        @objc func changed(_ picker: UIDatePicker) {
            let value = picker.countDownDuration
            if value > parent.maxSeconds {
                // Past the longest: roll back to it, the way the wheel springs at its ends.
                picker.setDate(picker.date, animated: false)
                picker.countDownDuration = parent.maxSeconds
                UISelectionFeedbackGenerator().selectionChanged()
            }
            parent.seconds = parent.clamp(picker.countDownDuration)
        }
    }
}

/// "Stop automatically after…": spin the wheel (up to 12 hours) or tap a quick time, then Start.
struct AutoStopSheet: View {
    var connection: any ControlTarget
    @Environment(\.dismiss) private var dismiss
    @AppStorage("autoStop.lastSeconds") private var seconds: Double = 3600

    private static let quick: [Double] = [900, 1800, 3600, 7200, 4 * 3600, 8 * 3600, 12 * 3600]

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("Your real location comes back by itself when the timer ends.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                CountdownWheel(seconds: $seconds)
                    .frame(height: 216)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.quick, id: \.self) { value in
                            Button {
                                withAnimation(Brand.snappy) { seconds = value }
                            } label: {
                                Text(WaitDuration.short(value))
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 36)
                                    .foregroundStyle(abs(seconds - value) < 30 ? Color.white : Color.primary)
                                    .background(abs(seconds - value) < 30 ? AnyShapeStyle(Brand.indigo)
                                                                         : AnyShapeStyle(Color.primary.opacity(0.07)),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                Spacer(minLength: 0)
                Button {
                    let minutes = Int((seconds / 60).rounded())
                    Task { await connection.setAutoStop(minutes: minutes) }
                    dismiss()
                } label: {
                    Text("Start Timer · \(Killswitch.label(minutes: Int((seconds / 60).rounded())))")
                        .frame(maxWidth: .infinity)
                }
                .prominentButton()
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .padding(.top, 8)
            .navigationTitle("Stop After")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
