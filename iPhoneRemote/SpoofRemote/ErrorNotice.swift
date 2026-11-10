import SwiftUI
import UIKit

/// Something went wrong, said quietly: one line that reads "Error". The message and its code stay
/// folded away until the line is tapped, then there's a Copy button for a bug report.
struct ErrorNotice: View {
    let message: String
    var detail: String? = nil
    /// A follow-up, shown once it's open (for example "A newer version may fix this").
    var action: (title: String, run: () -> Void)? = nil

    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Brand.snappy) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Brand.danger)
                    Text("Error")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Text(open ? "Hide" : "Details")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Error")
            .accessibilityValue(open ? message : "")
            .accessibilityHint(open ? "Hides the details" : "Shows what went wrong")

            if open {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 14) {
                        Button {
                            UIPasteboard.general.string = [message, detail].compactMap { $0 }.joined(separator: "\n")
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        if let action {
                            Button(action.title, action: action.run)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.accentText)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Brand.danger.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // A new problem starts folded again.
        .id(message)
    }
}

/// The connection dropped and the app is getting it back: not an error yet, so no red.
struct ReconnectingNotice: View {
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Reconnecting…")
                    .font(.subheadline.weight(.semibold))
                Text("Your location is kept. Leave LocalDevVPN on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Brand.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
