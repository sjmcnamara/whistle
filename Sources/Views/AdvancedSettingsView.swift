import SwiftUI

struct AdvancedSettingsView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @State private var showBurnConfirmation = false

    var body: some View {
        List {
            identitySection
            securitySection
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

    private var relaysSection: some View {
        Section("Relays") {
            ForEach(appViewModel.settings.relays) { relay in
                HStack {
                    Circle()
                        .fill(relayDotColor(for: relay.url))
                        .frame(width: 8, height: 8)
                    Text(relay.url.replacingOccurrences(of: "wss://", with: ""))
                        .font(.body)
                    Spacer()
                    if !relay.isEnabled {
                        Text("Disabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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
