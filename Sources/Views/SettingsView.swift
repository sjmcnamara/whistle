import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    /// Observed directly: `AppViewModel` does not forward this store's changes,
    /// so without it the avatar row would only refresh when some unrelated
    /// relay or settings event happened to re-render this view.
    @EnvironmentObject private var memberAvatars: MemberAvatarStore
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

            // Display name for group chat. Extracted so typing doesn't
            // re-render this whole view — see DisplayNameRow.
            DisplayNameRow(
                committedName: appViewModel.settings.displayName,
                onCommit: { appViewModel.settings.displayName = $0 }
            )

            avatarRow
        }
    }

    /// Picker for the user's own avatar, shown to every member of every group.
    ///
    /// Extracted into `AvatarPickerRow` so it takes plain values rather than
    /// observing `AppViewModel` — see that type for why re-rendering here made
    /// the photo library reload on a loop.
    @ViewBuilder
    private var avatarRow: some View {
        if let pubkey = appViewModel.myPubkeyHex {
            AvatarPickerRow(
                pubkeyHex: pubkey,
                displayName: appViewModel.settings.displayName,
                image: memberAvatars.image(for: pubkey),
                onPicked: { data in await appViewModel.setOwnAvatar(data: data) },
                onRemove: { await appViewModel.removeOwnAvatar() }
            )
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

            Toggle(isOn: Binding(
                get: { appViewModel.settings.isMotionAdaptiveEnabled },
                set: { appViewModel.settings.isMotionAdaptiveEnabled = $0 }
            )) {
                Label("Movement Aware", systemImage: "figure.walk.motion")
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

    /// e.g. `1.2.1(24)` — marketing version with build number in parens.
    private static let appVersionString: String = {
        let m = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(m)(\(b))"
    }()

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(Self.appVersionString)
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
