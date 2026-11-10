import PhoneOnlyCore
import RemoteAPI
import SwiftUI

/// "Stop automatically": while a location is held, a menu to put the real location back by itself after a
/// while, which becomes a live countdown once it is set. The Mac does the stopping, so it still works if
/// this iPhone is locked or out of range.
struct AutoStopRow: View {
    var connection: any ControlTarget
    /// Just an icon (and the countdown when set), to sit in a header.
    var compact = false
    @State private var choosing = false

    private var deadline: Date? {
        guard let at = connection.status?.autoStopAt else { return nil }
        let date = Date(timeIntervalSince1970: at)
        return date > Date() ? date : nil
    }

    var body: some View {
        HStack(spacing: 10) {
            if let deadline {
                // One clock on a fixed schedule (a schedule that starts "now" changes on every redraw).
                TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 1)) { context in
                    let left = deadline.timeIntervalSince(context.date)
                    Label("Stops in \(Killswitch.countdown(left))", systemImage: "timer")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Brand.skyText)
                        .accessibilityLabel("Stops automatically in \(Killswitch.countdown(left))")
                }
                Spacer(minLength: 0)
                Button {
                    Task { await connection.setAutoStop(minutes: 0) }
                } label: {
                    Text("Cancel").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Cancel the automatic stop")
            } else {
                Button {
                    choosing = true
                } label: {
                    if compact {
                        Image(systemName: "timer")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .glassCircle()
                            .accessibilityLabel("Stop automatically after…")
                    } else {
                        Label("Stop automatically…", systemImage: "timer")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.accentText)
                if !compact { Spacer(minLength: 0) }
            }
        }
        .sheet(isPresented: $choosing) { AutoStopSheet(connection: connection) }
        .disabled(connection.isWorking)
        .animation(Brand.snappy, value: deadline != nil)
    }
}

/// While a place is held and the Route tab is open: where it is held, the timer, and Stop, on one line.
struct HeldStrip: View {
    let status: RemoteStatus
    var connection: any ControlTarget

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Brand.gradient).frame(width: 38, height: 38)
                Image(systemName: "location.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("HOLDING")
                    .font(.caption2.weight(.bold))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                Text(status.placeName ?? "Custom location")
                    .font(Brand.rounded(.subheadline))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            AutoStopRow(connection: connection, compact: true)
            Button {
                Task { await connection.stop() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Brand.danger)
                    .frame(width: 44, height: 44)
                    .glassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop and go back to the real location")
            .disabled(connection.isWorking)
        }
    }
}
