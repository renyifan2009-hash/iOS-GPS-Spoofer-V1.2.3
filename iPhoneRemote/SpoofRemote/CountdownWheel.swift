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
                picker.countDownDuration = parent.maxSeconds
                UISelectionFeedbackGenerator().selectionChanged()
            }
            parent.seconds = parent.clamp(picker.countDownDuration)
        }
    }
}

/// "Stop automatically after…", laid out like the Clock app's Add Alarm sheet: ✕ and ✓ at the top, the timer
/// wheel (up to 12 hours), a quick-time menu and the clock time it ends. ✓ starts the timer.
struct AutoStopSheet: View {
    var connection: any ControlTarget
    @Environment(\.dismiss) private var dismiss
    @AppStorage("autoStop.lastSeconds") private var seconds: Double = 3600

    private static let quick: [Double] = [900, 1800, 3600, 7200, 4 * 3600, 8 * 3600, 12 * 3600]

    private var minutes: Int { Int((seconds / 60).rounded()) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    CountdownWheel(seconds: $seconds)
                        .frame(height: 216)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .accessibilityLabel("Stop after")
                }
                Section {
                    QuickTimeRow(seconds: Binding(get: { seconds },
                                                  set: { value in withAnimation(Brand.snappy) { seconds = value } }),
                                 choices: Self.quick)
                    TimelineView(.everyMinute) { context in
                        LabeledContent("Ends At",
                                       value: (context.date + Double(minutes * 60)).formatted(date: .omitted, time: .shortened))
                    }
                } footer: {
                    Text("Your real location comes back by itself when the timer ends.")
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .contentMargins(.top, 0, for: .scrollContent)
            .alarmSheetToolbar(title: "Stop After", confirmLabel: "Start Timer, \(Killswitch.label(minutes: minutes))",
                               onCancel: { dismiss() }, onConfirm: start)
        }
        .presentationDetents([.large])
    }

    private func start() {
        let minutes = minutes
        Task { await connection.setAutoStop(minutes: minutes) }
        dismiss()
    }
}
