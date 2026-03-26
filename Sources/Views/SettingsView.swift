import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                identitySection
                securitySection
                locationSection
                relaysSection
                connectionSection
                aboutSection
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section("Identity") {
            if let identity = appViewModel.identity.identity {
                NavigationLink {
                    IdentityCardView(identity: identity)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your Nostr Key")
                            Text(identity.shortNpub)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "person.crop.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
            } else {
                Label("Generating identity…", systemImage: "key.fill")
                    .foregroundStyle(.secondary)
            }

            NavigationLink {
                IdentityImportExportView()
            } label: {
                Label("Import / Export Key", systemImage: "arrow.left.arrow.right")
            }

            // Display name for group chat
            HStack {
                Label("Display Name", systemImage: "person.text.rectangle")
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer()
                TextField("Your Name", text: Binding(
                    get: { appViewModel.settings.displayName },
                    set: { appViewModel.settings.displayName = $0 }
                ))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
            }
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

    private var locationSection: some View {
        Section("Location") {
            // Enable location — shown when authorization not yet requested.
            // Requests "Always" since the app needs background location for
            // family tracking. iOS shows "When In Use" first, then prompts
            // to upgrade to "Always" automatically.
            if appViewModel.locationService.authorizationStatus == .notDetermined {
                Button {
                    appViewModel.locationService.requestAlwaysAuthorization()
                } label: {
                    Label("Enable Location", systemImage: "location.fill")
                }
            }

            // If the user only granted "When In Use", offer to upgrade to
            // "Always" so background location sharing works when the app
            // is not in the foreground.
            if appViewModel.locationService.authorizationStatus == .authorizedWhenInUse {
                Button {
                    if let url = URL(string: "app-settings:") {
                        openURL(url)
                    }
                } label: {
                    Label("Allow Always for Background Sharing", systemImage: "location.fill")
                }
                .font(.subheadline)
            }

            Toggle(isOn: Binding(
                get: { appViewModel.settings.isLocationPaused },
                set: { appViewModel.settings.isLocationPaused = $0 }
            )) {
                Label("Pause Sharing", systemImage: "location.slash")
            }

            Picker(selection: Binding(
                get: { appViewModel.settings.locationIntervalSeconds },
                set: { appViewModel.settings.locationIntervalSeconds = $0 }
            )) {
                Text("10 sec").tag(10)
                Text("5 min").tag(300)
                Text("15 min").tag(900)
                Text("30 min").tag(1800)
                Text("1 hour").tag(3600)
            } label: {
                Label("Update Interval", systemImage: "clock.arrow.2.circlepath")
            }

            HStack {
                Label("Authorization", systemImage: "checkmark.shield")
                Spacer()
                authorizationLabel
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

    @ViewBuilder
    private var authorizationLabel: some View {
        let status = appViewModel.locationService.authorizationStatus
        switch status {
        case .notDetermined:
            Text("Not Requested")
                .foregroundStyle(.secondary)
        case .restricted:
            Text("Restricted")
                .foregroundStyle(.orange)
        case .denied:
            Text("Denied")
                .foregroundStyle(.red)
        case .authorizedWhenInUse:
            Text("When In Use")
                .foregroundStyle(.green)
        case .authorizedAlways:
            Text("Always")
                .foregroundStyle(.green)
        @unknown default:
            Text("Unknown")
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text("0.8.3")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Protocol")
                Spacer()
                Text("Nostr & MLS & Marmot")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Source")
                Spacer()
                Link("GitHub", destination: URL(string: "https://github.com/sjmcnamara/findmyfam")!)
            }
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

    private func relayDotColor(for url: String) -> Color {
        appViewModel.relay.connectedRelayURLs.contains(url) ? .green : .secondary
    }

}
