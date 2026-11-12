import PhoneOnlyCore
import SwiftUI

/// Everything that isn't moving the location: where it's controlled from, staying on when locked,
/// LocalDevVPN, the plan, signing refresh with SideStore, and pairing. Kept off the map so the main
/// screen stays simple.
struct SettingsView: View {
    @Environment(OnDeviceController.self) private var phone
    @Environment(ConnectionManager.self) private var connection
    @Environment(LicenseStore.self) private var licenses
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("locationSource") private var source: LocationSource = .mac
    @AppStorage(LocalDevVPN.autoOpenKey) private var autoOpenVPN = true
    @AppStorage(KeepAwakeSettings.silentAudioKey) private var silentAudio = true
    @AppStorage(NaturalSettings.holdWobbleKey) private var holdWobble = true
    @AppStorage(UnitsChoice.key) private var unitsChoice: UnitsChoice = .automatic
    @State private var showPhoneSetup = false
    @State private var showPairing = false
    @State private var showPaywall = false
    @State private var enteringKey = false
    @State private var key = ""

    private var busy: Bool { phone.isSpoofing || phone.isWorking || connection.isSpoofing || connection.isWorking }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Control from", selection: $source) {
                        Text("This iPhone").tag(LocationSource.thisPhone)
                        Text("Mac").tag(LocationSource.mac)
                    }
                    .pickerStyle(.segmented)
                    .disabled(busy)
                } header: {
                    Text("Location")
                } footer: {
                    Text(busy ? "Stop the current location to switch."
                              : "This iPhone works on its own with LocalDevVPN. Mac lets your Mac hold the location over a cable or Wi-Fi.")
                }

                if source == .thisPhone {
                    Section("This iPhone") {
                        Button { showPhoneSetup = true } label: {
                            row("checklist", "Set Up", value: phone.isSetUp ? "Ready" : "Needs pairing file")
                        }
                        Toggle(isOn: $autoOpenVPN) {
                            Label("Open LocalDevVPN automatically", systemImage: "network.badge.shield.half.filled")
                        }
                        Button { LocalDevVPN.turnOn() } label: {
                            row("power", "Turn On LocalDevVPN Now")
                        }
                    }
                    Section {
                        Toggle(isOn: $silentAudio) {
                            Label("Stay on when locked", systemImage: "lock.iphone")
                        }
                        Toggle(isOn: $holdWobble) {
                            Label("Natural GPS while holding", systemImage: "dot.radiowaves.left.and.right")
                        }
                    } header: {
                        Text("Feels real")
                    } footer: {
                        Text("Stay on when locked plays silence alongside your other audio, so iOS doesn't pause AnyWhere and drop your location. Natural GPS lets a held place drift a few meters like a real phone's.")
                    }
                } else {
                    Section("Mac") {
                        Button { showPairing = true } label: {
                            row("laptopcomputer", connection.isPaired ? "Paired Mac" : "Find My Mac",
                                value: connection.server?.name)
                        }
                    }
                }

                Section {
                    Picker(selection: $unitsChoice) {
                        Text("Automatic").tag(UnitsChoice.automatic)
                        Text("Miles").tag(UnitsChoice.miles)
                        Text("Kilometers").tag(UnitsChoice.kilometers)
                    } label: {
                        Label("Distance & Speed", systemImage: "ruler")
                    }
                } footer: {
                    Text("Automatic uses this iPhone's region, which is set to \(SpeedUnits(region: SpeedUnits.deviceRegion).imperial ? "miles" : "kilometers") (Settings ▸ General ▸ Language & Region ▸ Measurement System).")
                }

                proSection

                Section {
                    if let summary = SigningStatus.summary {
                        Label(summary, systemImage: SigningStatus.isEndingSoon ? "exclamationmark.circle" : "checkmark.seal")
                            .foregroundStyle(SigningStatus.isEndingSoon ? Brand.warningText : Color.primary)
                    }
                    Button { SideStore.addSource() } label: { row("plus.app", "Add AnyWhere to SideStore") }
                    Button { SideStore.open() } label: { row("arrow.clockwise.circle", "Refresh in SideStore") }
                    Button { SideStore.requestPairingFile() } label: { row("doc.badge.arrow.up", "Get Pairing File from SideStore") }
                } header: {
                    Text("Updates & 7-day signing")
                } footer: {
                    Text("Install AnyWhere through SideStore and it refreshes on this iPhone, with no computer: SideStore renews it in the background, and a daily Shortcuts automation (Automation ▸ Time of Day ▸ SideStore “Refresh All Apps”) makes sure. New versions show up there too.")
                }

                Section {
                    LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(BuildVersion.version))")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showPhoneSetup) { PhoneOnlySetupView() }
            .sheet(isPresented: $showPairing) { PairingView() }
            .sheet(isPresented: $showPaywall) { PaywallView() }
        }
    }

    @ViewBuilder
    private var proSection: some View {
        Section {
            LabeledContent("Plan", value: licenses.summary)
            if PaymentsConfig.isEnabled {
                if licenses.hasPro {
                    Button {
                        Task { if let url = await licenses.manageURL() { openURL(url) } }
                    } label: { row("creditcard", "Manage Subscription") }
                } else {
                    Button { showPaywall = true } label: { row("sparkles", "Choose a Plan") }
                }
                if enteringKey {
                    TextField("License key (aw_…)", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .onSubmit { Task { await licenses.activate(key: key) } }
                } else if !licenses.hasPro {
                    Button { enteringKey = true } label: { row("key", "Enter License Key") }
                }
                if let error = licenses.lastError { ErrorNotice(message: error) }
            }
        } header: {
            Text("AnyWhere Pro")
        } footer: {
            if PaymentsConfig.isEnabled {
                Text("$2.99 a month, $15 a year, or $20 once. Paid with Stripe.")
            }
        }
    }

    private func row(_ symbol: String, _ title: String, value: String? = nil) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .foregroundStyle(.primary)
            Spacer()
            if let value {
                Text(value).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}
