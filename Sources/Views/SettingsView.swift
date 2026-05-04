import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                identitySection
                locationSection
                appearanceSection
                aboutSection

                Section {
                    NavigationLink {
                        AdvancedSettingsView()
                    } label: {
                        Label("Advanced", systemImage: "gearshape.2")
                    }
                }
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

    private var locationSection: some View {
        Section("Location") {
            // Authorization row — tappable when the status can be changed in Settings.
            authorizationRow

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
        }
    }

    @ViewBuilder
    private var authorizationRow: some View {
        let status = appViewModel.locationService.authorizationStatus
        switch status {
        case .notDetermined:
            Button {
                appViewModel.locationService.requestAlwaysAuthorization()
            } label: {
                HStack {
                    Label("Authorization", systemImage: "checkmark.shield")
                    Spacer()
                    Text("Not Requested")
                        .foregroundStyle(Color.accentColor)
                }
            }
        case .restricted:
            HStack {
                Label("Authorization", systemImage: "checkmark.shield")
                Spacer()
                Text("Restricted")
                    .foregroundStyle(.orange)
            }
        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                HStack {
                    Label("Authorization", systemImage: "checkmark.shield")
                    Spacer()
                    Text("Denied")
                        .foregroundStyle(Color.accentColor)
                }
            }
        case .authorizedWhenInUse:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                HStack {
                    Label("Authorization", systemImage: "checkmark.shield")
                    Spacer()
                    Text("When In Use")
                        .foregroundStyle(Color.accentColor)
                }
            }
        case .authorizedAlways:
            HStack {
                Label("Authorization", systemImage: "checkmark.shield")
                Spacer()
                Text("Always")
                    .foregroundStyle(.green)
            }
        @unknown default:
            HStack {
                Label("Authorization", systemImage: "checkmark.shield")
                Spacer()
                Text("Unknown")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker(selection: Binding(
                get: { appViewModel.settings.appearance },
                set: { appViewModel.settings.appearance = $0 }
            )) {
                ForEach(AppAppearance.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            } label: {
                Label("Theme", systemImage: "circle.lefthalf.filled")
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
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
                Link("GitHub", destination: URL(string: "https://github.com/sjmcnamara/whistle")!)
            }
        }
    }
}
