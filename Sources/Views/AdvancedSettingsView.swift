import SwiftUI
import WhistleCore

struct AdvancedSettingsView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @State private var showBurnConfirmation = false
    @State private var showAddRelay = false
    @State private var newRelayURL = ""
    @State private var relayError: String?

    var body: some View {
        List {
            identitySection
            securitySection
            locationPrivacySection
            relaysSection
            connectionSection
            dangerSection
        }
        .navigationTitle("Advanced")
        .alert("Burn Identity?", isPresented: $showBurnConfirmation) {
            Button("Burn Everything", role: .destructive) {
                Task { try? await appViewModel.burnIdentity() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently destroy your current identity, leave all groups, and erase all messages. A new identity will be generated. This cannot be undone.")
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section("Identity") {
            NavigationLink {
                IdentityImportExportView()
            } label: {
                Label("Import / Export Key", systemImage: "arrow.left.arrow.right")
            }
        }
    }

    private var securitySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { appViewModel.settings.isAppLockEnabled },
                set: { appViewModel.settings.isAppLockEnabled = $0 }
            )) {
                Label("App Lock", systemImage: "lock.shield")
            }

            if appViewModel.settings.isAppLockEnabled {
                Toggle(isOn: Binding(
                    get: { appViewModel.settings.isAppLockReauthOnForeground },
                    set: { appViewModel.settings.isAppLockReauthOnForeground = $0 }
                )) {
                    Label("Require Unlock", systemImage: "arrow.clockwise.circle")
                }
            }

            Picker(selection: Binding(
                get: { appViewModel.settings.keyRotationIntervalDays },
                set: { appViewModel.settings.keyRotationIntervalDays = $0 }
            )) {
                Text("1 day").tag(1)
                Text("3 days").tag(3)
                Text("7 days").tag(7)
                Text("14 days").tag(14)
                Text("30 days").tag(30)
            } label: {
                Label("Key Rotation", systemImage: "arrow.triangle.2.circlepath")
            }
        } header: {
            Text("Security")
        } footer: {
            Text("How often encryption keys are rotated for forward secrecy. Shorter intervals are more secure.")
        }
    }

    private var locationPrivacySection: some View {
        Section {
            Picker(selection: Binding(
                get: { appViewModel.settings.locationFuzzMeters },
                set: { appViewModel.settings.locationFuzzMeters = $0 }
            )) {
                Text("Off — exact location").tag(0)
                Text("10 m").tag(10)
                Text("50 m").tag(50)
                Text("200 m").tag(200)
            } label: {
                Label("Location Fuzzing", systemImage: "location.slash")
            }
        } header: {
            Text("Location Privacy")
        } footer: {
            Text("Randomly adjusts your shared location by up to this distance. Others see an approximate position instead of your exact coordinates.")
        }
    }

    private var relaysSection: some View {
        Section {
            ForEach(appViewModel.settings.relays) { relay in
                HStack {
                    Circle()
                        .fill(relayDotColor(for: relay.url))
                        .frame(width: 8, height: 8)
                    Text(relay.url.replacingOccurrences(of: "wss://", with: ""))
                        .font(.body)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { relay.isEnabled },
                        set: { newValue in
                            if let idx = appViewModel.settings.relays.firstIndex(where: { $0.id == relay.id }) {
                                appViewModel.settings.relays[idx].isEnabled = newValue
                            }
                            Task { await appViewModel.reconnectRelays() }
                        }
                    ))
                    .labelsHidden()
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !AppSettings.defaultRelays.contains(where: { $0.url == relay.url }) {
                        Button(role: .destructive) {
                            appViewModel.settings.relays.removeAll { $0.id == relay.id }
                            Task { await appViewModel.reconnectRelays() }
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }

            Button {
                newRelayURL = "wss://"
                relayError = nil
                showAddRelay = true
            } label: {
                Label("Add Relay", systemImage: "plus.circle")
            }
        } header: {
            Text("Relays")
        } footer: {
            Text("Toggle relays on/off. Swipe to remove custom relays. Default relays cannot be removed.")
        }
        .alert("Add Relay", isPresented: $showAddRelay) {
            TextField("wss://relay.example.com", text: $newRelayURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") { addRelay() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let relayError {
                Text(relayError)
            } else {
                Text("Enter the WebSocket URL of the relay.")
            }
        }
    }

    private func addRelay() {
        let url = newRelayURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard url.hasPrefix("wss://") || url.hasPrefix("ws://") else {
            relayError = "URL must start with wss:// or ws://"
            showAddRelay = true
            return
        }
        guard url.count > 6, URL(string: url) != nil else {
            relayError = "Invalid URL format"
            showAddRelay = true
            return
        }
        guard !appViewModel.settings.relays.contains(where: { $0.url == url }) else {
            relayError = "Relay already exists"
            showAddRelay = true
            return
        }

        appViewModel.settings.relays.append(RelayConfig(url: url))
        Task { await appViewModel.reconnectRelays() }
    }

    private var connectionSection: some View {
        Section("Connection") {
            HStack {
                Text("Relay")
                Spacer()
                connectionLabel
            }

            HStack {
                Text("MLS Crypto")
                Spacer()
                mlsStatusLabel
            }
        }
    }

    // MARK: - Danger zone

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                showBurnConfirmation = true
            } label: {
                Label("Burn Identity", systemImage: "flame.fill")
            }
        } header: {
            Text("Danger Zone")
        } footer: {
            Text("Generate a fresh identity. All groups, messages, and cryptographic state will be permanently erased.")
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var connectionLabel: some View {
        switch appViewModel.relay.connectionState {
        case .disconnected:
            Label("Disconnected", systemImage: "wifi.slash").foregroundStyle(.secondary)
        case .connecting:
            Label("Connecting…", systemImage: "wifi").foregroundStyle(.orange)
        case .connected:
            Label("Connected", systemImage: "wifi").foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.wifi")
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var mlsStatusLabel: some View {
        if let error = appViewModel.mlsError {
            VStack(alignment: .trailing, spacing: 4) {
                Label("Failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } else if appViewModel.marmot != nil {
            Label("Ready", systemImage: "checkmark.shield")
                .foregroundStyle(.green)
        } else {
            Label("Starting…", systemImage: "hourglass")
                .foregroundStyle(.orange)
        }
    }

    private func relayDotColor(for url: String) -> Color {
        appViewModel.relay.connectedRelayURLs.contains(url) ? .green : .secondary
    }
}
