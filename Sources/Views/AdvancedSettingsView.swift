import SwiftUI
import WhistleCore

struct AdvancedSettingsView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @State private var showBurnConfirmation = false
    @State private var showBurnPlanReview = false
    @State private var burnPlan: BurnPlan?
    @State private var burnPromotions: [String: String] = [:]
    @State private var isPreparingBurnPlan = false
    @State private var showAddRelay = false
    @State private var newRelayURL = ""
    @State private var relayError: String?
    /// Held locally rather than read through `appViewModel` on each render.
    ///
    /// `AppViewModel.forwardChildChanges()` republishes `settings`,
    /// `locationService` and the **v1** `relay` — not `marmot` — so a change
    /// to `MarmotKitService.relayStatus` never invalidated this view. It
    /// painted the initial `.disconnected` once and kept it, while the
    /// diagnostics bundle (which reads the value directly when generating)
    /// correctly said "connected (2 of 2)".
    ///
    /// Keeping it in `@State` fed by the polling task below fixes it without
    /// forwarding every `MarmotKitService` change into `AppViewModel`, which
    /// would re-render every view observing it on each relay event — the
    /// amplification the avatar picker already had to be insulated from.
    @State private var relayStatus: MarmotKitService.RelayStatus?

    /// Enabled relays that this runtime is not dialling, because they were
    /// added after it started.
    private var pendingRelayChanges: [String] {
        guard let dialled = appViewModel.marmot?.dialledRelayEndpoints else { return [] }
        let enabled = appViewModel.settings.relays.filter(\.isEnabled).map(\.url)
        return enabled.filter { candidate in
            // Compared on host rather than exact string: MarmotKit normalises
            // endpoints, so a trailing slash alone would otherwise read as a
            // pending change forever.
            !dialled.contains { $0.hasPrefix(candidate) || candidate.hasPrefix($0) }
        }
    }

    var body: some View {
        List {
            identitySection
            securitySection
            locationPrivacySection
            relaysSection
            connectionSection
            diagnosticsSection
            dangerSection
        }
        .navigationTitle("Advanced")
        // Relay sockets drop and reconnect in the background, so the status
        // goes stale unless it is re-read while this screen is open. Polls
        // MarmotKit, which owns the connections — the v1 `RelayService` this
        // used to refresh is never connected under v2.
        .task {
            while !Task.isCancelled {
                // Re-read the configured list each pass so adding or toggling
                // a relay is reflected without leaving the screen.
                let configured = appViewModel.settings.relays.map(\.url)
                await appViewModel.marmot?.refreshRelayStatus(configured: configured)
                relayStatus = appViewModel.marmot?.relayStatus
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .sheet(isPresented: $showBurnPlanReview) {
            if let burnPlan {
                BurnPlanReviewView(plan: burnPlan, promotions: $burnPromotions) {
                    showBurnConfirmation = true
                }
            }
        }
        .alert("Burn Identity?", isPresented: $showBurnConfirmation) {
            Button("Burn Everything", role: .destructive) {
                let plan = burnPlan ?? BurnPlan(leaving: [], promoteOrEnd: [], ending: [])
                Task { await appViewModel.executeBurnPlan(plan, promotions: burnPromotions) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove you from every group where you're not the only admin, then permanently destroy your identity and erase everything on this device. This cannot be undone.")
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
                    VStack(alignment: .leading, spacing: 1) {
                        Text(relay.url.replacingOccurrences(of: "wss://", with: ""))
                            .font(.body)
                        // Names the policy when MarmotKit will not dial this
                        // relay, so "retired" reads as a setting to change
                        // rather than an outage to wait out.
                        if let note = relayPolicyNote(for: relay.url) {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
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
            VStack(alignment: .leading, spacing: 6) {
                Text("Toggle relays on/off. Swipe to remove custom relays. Default relays cannot be removed.")
                // A newly added relay is advertised immediately but cannot be
                // dialled until the app restarts: MarmotKit fixes its relay
                // pool at construction. Saying so beats leaving the
                // connection count silently excluding it.
                if !pendingRelayChanges.isEmpty {
                    Label(
                        "Restart Whistle to connect to \(pendingRelayChanges.joined(separator: ", "))",
                        systemImage: "arrow.clockwise"
                    )
                    .foregroundStyle(.orange)
                }
            }
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

    /// Placed just above the danger zone: it is the thing to reach for when
    /// something is wrong, and the thing to try before anything destructive.
    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            NavigationLink {
                DiagnosticsView()
            } label: {
                Label("Share Diagnostics", systemImage: "stethoscope")
            }
        }
    }

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                isPreparingBurnPlan = true
                Task {
                    // Every active group needs its own MLS actor round-trip
                    // to re-sync admin state before this can be decided (see
                    // prepareBurnPlan's doc comment) — with several groups
                    // this is genuinely a few seconds, not free. The spinner
                    // exists so that reads as "working", not "frozen".
                    let plan = await appViewModel.prepareBurnPlan()
                    isPreparingBurnPlan = false
                    burnPlan = plan
                    burnPromotions = [:]
                    if plan.needsReview {
                        showBurnPlanReview = true
                    } else {
                        showBurnConfirmation = true
                    }
                }
            } label: {
                HStack {
                    Label("Burn Identity", systemImage: "flame.fill")
                    if isPreparingBurnPlan {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isPreparingBurnPlan)
        } header: {
            Text("Danger Zone")
        } footer: {
            Text("Generate a fresh identity. All groups, messages, and cryptographic state will be permanently erased.")
        }
    }

    // MARK: - Helpers

    /// Reads MarmotKit, not `RelayService`.
    ///
    /// The v2 startup path never connects the v1 service, so this used to read
    /// a permanently-disconnected object and report "Disconnected" while
    /// MarmotKit was connected to every relay.
    @ViewBuilder
    private var connectionLabel: some View {
        let status = relayStatus
        switch status?.connection {
        case .connected:
            Label("Connected (\(status?.connected ?? 0) of \(status?.total ?? 0))", systemImage: "wifi")
                .foregroundStyle(.green)
        case .connecting:
            Label("Connecting…", systemImage: "wifi").foregroundStyle(.orange)
        case .disconnected:
            Label("Disconnected", systemImage: "wifi.slash").foregroundStyle(.secondary)
        case nil:
            Label("Starting…", systemImage: "hourglass").foregroundStyle(.orange)
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

    /// Per-relay **policy**, not connectivity.
    ///
    /// MarmotKit exposes no per-endpoint connection status — only aggregate
    /// counts — so a per-row connectivity dot cannot be honest. Policy is more
    /// useful anyway: `retired` is a permanent configuration error the user has
    /// to correct, which a connectivity dot never distinguished from a relay
    /// that happened to be down.
    private func relayDotColor(for url: String) -> Color {
        switch relayStatus?.policies[url] {
        case "allowed": return .green
        case .some(let policy) where policy.isEmpty == false: return .orange
        default: return .secondary
        }
    }

    /// Shown beside a relay that MarmotKit will not dial, so the reason is
    /// visible rather than presenting as an unexplained failure.
    private func relayPolicyNote(for url: String) -> String? {
        guard let policy = relayStatus?.policies[url],
              policy != "allowed" else { return nil }
        return policy
    }
}
