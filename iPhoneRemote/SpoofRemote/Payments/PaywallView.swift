import SwiftUI

/// Choose a plan: monthly, yearly or lifetime. Paying happens on Stripe's page in Safari; it comes back
/// with `anywhere://activate?key=…`. Someone with a key already can type or paste it here.
struct PaywallView: View {
    @Environment(LicenseStore.self) private var licenses
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var plan: Plan = .yearly
    @State private var enteringKey = false
    @State private var key = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    features
                    VStack(spacing: 10) {
                        ForEach(Plan.allCases) { option in planRow(option) }
                    }
                    if let error = licenses.lastError {
                        ErrorNotice(message: error)
                    }
                    Button {
                        Task {
                            if let url = await licenses.checkoutURL(for: plan) { openURL(url) }
                        }
                    } label: {
                        Group {
                            if licenses.working {
                                ProgressView()
                            } else {
                                Text("Continue · \(plan.price) \(plan.period)")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .prominentButton()
                    .disabled(licenses.working)
                    keyEntry
                    Text("Payments are handled by Stripe. Subscriptions renew until you cancel, which you can do any time from Settings ▸ Manage Subscription. \(licenses.summary).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("AnyWhere Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not Now") { dismiss() } }
            }
            .onChange(of: licenses.hasPro) { _, pro in if pro { dismiss() } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            IconTile(symbol: "location.north.circle.fill", size: 52)
            Text("Your location, your call.")
                .font(Brand.rounded(.title2))
                .padding(.top, 6)
            Text(licenses.inTrial ? "You're on the free trial. Pick a plan to keep everything when it ends."
                                  : "Your free trial has ended. Pick a plan to keep using AnyWhere on this iPhone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 12) {
            feature("iphone", "Works on this iPhone alone", "No computer once it's set up.")
            feature("car.fill", "Drives that look real", "Stops, red lights, corners and natural GPS.")
            feature("lock.fill", "Stays on when locked", "Your location holds until you press Stop.")
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Brand.indigo)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func planRow(_ option: Plan) -> some View {
        let selected = plan == option
        return Button {
            withAnimation(Brand.snappy) { plan = option }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? Brand.indigo : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.title).font(.headline)
                        if let badge = option.badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Brand.indigo.opacity(0.16), in: Capsule())
                                .foregroundStyle(Brand.accentText)
                        }
                    }
                    Text(option.detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(option.price).font(.headline.monospacedDigit())
                    Text(option.period).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? Brand.indigo : Color.clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(option.title), \(option.price) \(option.period)")
    }

    @ViewBuilder
    private var keyEntry: some View {
        if enteringKey {
            VStack(alignment: .leading, spacing: 8) {
                TextField("aw_…", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Button("Activate") {
                    Task { await licenses.activate(key: key) }
                }
                .glassButton()
                .disabled(key.isEmpty || licenses.working)
            }
        } else {
            Button("I already have a license key") { withAnimation(Brand.snappy) { enteringKey = true } }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.accentText)
                .frame(maxWidth: .infinity)
        }
    }
}
