import SwiftUI

/// Pairing this iPhone with AnyWhere itself, from Settings, with no computer (iOS 27 and later).
struct PhonePairingView: View {
    @Environment(OnDeviceController.self) private var phone
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = PhonePairing()

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if PhonePairing.isAvailable {
                            content
                        } else {
                            notAvailable
                        }
                    }
                    .padding(20)
                    .animation(Brand.spring, value: pairing.state)
                }
            }
            .navigationTitle("Pair Without a Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(pairing.state == .done ? "Done" : "Close") {
                        pairing.cancel()
                        dismiss()
                    }
                }
            }
        }
        .tint(Brand.sky)
        .onDisappear { pairing.cancel() }
        .sensoryFeedback(.success, trigger: pairing.state) { _, state in state == .done }
    }

    @ViewBuilder
    private var content: some View {
        Text("This makes a new pairing file on this iPhone. Use it if you have no computer and cable, or if starting fails with \u{201C}Connection reset by peer\u{201D}.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 12) {
            stepRow(1, "Tap Start. AnyWhere stays awake while you're in Settings.")
            stepRow(2, "Open Settings \u{25B8} Privacy & Security \u{25B8} Developer Mode.")
            stepRow(3, "Tap Pair with \(PhonePairing.hostName).")
            stepRow(4, "Type the code AnyWhere shows. It's also in a notification.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 20)

        status
    }

    @ViewBuilder
    private var status: some View {
        switch pairing.state {
        case .idle:
            Button {
                pairing.start { phone.importPairingFile(from: $0) }
            } label: {
                Label("Start", systemImage: "link").frame(maxWidth: .infinity)
            }
            .prominentButton()
        case .waiting:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for Settings\u{2026} Open Settings \u{25B8} Privacy & Security \u{25B8} Developer Mode and tap Pair with \(PhonePairing.hostName).")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Cancel", role: .cancel) { pairing.cancel() }.glassButton()
            }
        case .code(let code):
            VStack(spacing: 10) {
                Text("Enter this code in Settings")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(code)
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .kerning(6)
                    .textSelection(.enabled)
                    .accessibilityLabel(code.map(String.init).joined(separator: " "))
            }
            .frame(maxWidth: .infinity)
            .padding(18)
            .cardSurface(cornerRadius: 20, tint: Brand.sky)
        case .finishing:
            HStack(spacing: 10) {
                ProgressView()
                Text("Pairing\u{2026}").font(.subheadline)
            }
        case .done:
            Label("Paired. AnyWhere has a new pairing file for this iPhone.", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.live)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Brand.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") {
                    pairing.reset()
                    pairing.start { phone.importPairingFile(from: $0) }
                }
                .glassButton()
            }
        }
    }

    private var notAvailable: some View {
        Text("Pairing without a computer needs iOS 27 or later. This iPhone has iOS \(UIDevice.current.systemVersion). Make the pairing file on your Mac instead: plug this iPhone in, open AnyWhere and choose File \u{25B8} Pairing File for the iPhone App\u{2026}.")
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Brand.sky.opacity(0.3)))
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
