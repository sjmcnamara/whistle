import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appViewModel: AppViewModel

    var body: some View {
        NavigationStack {
            List {
                identitySection
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
                Text("Status")
                Spacer()
                connectionLabel
            }
        }
    }

    private var locationSection: some View {
        Section("Location") {
            Toggle(isOn: Binding(
                get: { appViewModel.settings.isLocationPaused },
                set: { appViewModel.settings.isLocationPaused = $0 }
            )) {
                Label("Pause Sharing", systemImage: "location.slash")
            }

            Picker("Update Interval", selection: Binding(
                get: { appViewModel.settings.locationIntervalSeconds },
                set: { appViewModel.settings.locationIntervalSeconds = $0 }
            )) {
                Text("5 min").tag(300)
                Text("15 min").tag(900)
                Text("30 min").tag(1800)
                Text("1 hour").tag(3600)
            }

            HStack {
                Text("Authorization")
                Spacer()
                authorizationLabel
            }
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
                Text("0.4.0")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Protocol")
                Spacer()
                Text("Nostr + MLS (Marmot)")
                    .foregroundStyle(.secondary)
            }
            Link(destination: URL(string: "https://github.com/sjmcnamara/findmyfam")!) {
                Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
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
