import Foundation
import CoreLocation
import NostrSDK
import Combine

/// Root view-model. Owns the core services and coordinates startup.
@MainActor
final class AppViewModel: ObservableObject {

    let identity: IdentityService
    let relay: RelayService
    let mls: MLSService
    let settings: AppSettings

    /// Marmot orchestration layer — bridges MLS ↔ Relay (v0.3).
    @Published private(set) var marmot: MarmotService?

    // MARK: - Location (v0.4)

    /// CoreLocation wrapper — publishes via callback.
    let locationService: LocationService

    /// Shared in-memory cache of group members' latest locations.
    let locationCache: LocationCache

    /// View-model for the family map — observes `locationCache`.
    let locationViewModel: LocationViewModel

    // MARK: - Chat & Nicknames (v0.5)

    /// Local nickname store — maps pubkey hex → display name.
    let nicknameStore: NicknameStore

    // MARK: - Pending Invites (v0.6)

    /// Tracks invites where key package was published but Welcome not yet received.
    let pendingInviteStore: PendingInviteStore

    // MARK: - Pending Approval (v0.7)

    /// A member approval request received via `famstr://addmember/` deep link.
    struct PendingApprovalRequest {
        let pubkeyHex: String
        let groupId: String
    }

    /// Non-nil when the inviter's app has received an add-member deep link.
    @Published var pendingApproval: PendingApprovalRequest?

    /// Non-nil when an approval attempt failed — surfaced as an error alert.
    @Published var approvalError: String?

    /// GroupListViewModel — owned here so it survives SwiftUI view identity
    /// changes. Created once after MarmotService is ready.
    @Published private(set) var groupListViewModel: GroupListViewModel?

    /// Current user's public key hex — convenience for ViewModels.
    var myPubkeyHex: String? { identity.identity?.publicKeyHex }

    // MARK: - Startup / Splash (v0.7.1)

    enum StartupPhase: Equatable {
        case connecting
        case initialisingEncryption
        case loadingGroups
        case ready

        var message: String {
            switch self {
            case .connecting:              return "Connecting to relays…"
            case .initialisingEncryption:  return "Setting up encryption…"
            case .loadingGroups:           return "Loading groups…"
            case .ready:                   return ""
            }
        }
    }

    @Published private(set) var startupPhase: StartupPhase = .connecting

    /// MLS initialisation error surfaced to the UI (non-fatal — app works without it).
    @Published private(set) var mlsError: String?

    /// Tracks whether onAppear has completed — prevents duplicate startup.
    private var didStart = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        self.identity        = IdentityService()
        self.relay           = RelayService()
        self.mls             = MLSService()
        self.settings        = AppSettings.shared
        self.locationService = LocationService()
        self.locationCache   = LocationCache()
        self.nicknameStore       = NicknameStore()
        self.pendingInviteStore  = PendingInviteStore()

        let cache = self.locationCache
        let settingsRef = self.settings
        let nicknames = self.nicknameStore
        let identityRef = self.identity
        let locationSvc = self.locationService
        self.locationViewModel = LocationViewModel(
            locationCache: cache,
            nicknameStore: nicknames,
            intervalSeconds: { settingsRef.locationIntervalSeconds },
            myPubkeyHex: { identityRef.identity?.publicKeyHex },
            nextFireDate: {
                guard let last = locationSvc.lastFireDate else { return nil }
                return last.addingTimeInterval(TimeInterval(settingsRef.locationIntervalSeconds))
            }
        )

        // Forward objectWillChange from nested ObservableObjects so that
        // SwiftUI views observing AppViewModel re-render when child
        // @Published properties change (e.g. SettingsView watching
        // locationService.authorizationStatus, settings.isLocationPaused,
        // relay.connectionState).
        forwardChildChanges()

        // Observe settings changes immediately — NOT in onAppear() which
        // runs async and may not reach the subscription code in time.
        observeSettings()
    }

    /// Forward `objectWillChange` from nested ObservableObjects so views
    /// that observe AppViewModel (via @EnvironmentObject) re-render when
    /// child properties change.
    private func forwardChildChanges() {
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        locationService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        relay.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Subscribe to settings changes. Called from init() so the observers
    /// are active before any async startup work.
    private func observeSettings() {
        settings.$isLocationPaused
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyLocationPauseSetting()
            }
            .store(in: &cancellables)

        settings.$locationIntervalSeconds
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newInterval in
                guard let self else { return }
                self.locationService.intervalSeconds = newInterval
                self.locationService.resetThrottle()
                FMFLogger.location.info("Interval changed to \(newInterval)s, throttle reset")
            }
            .store(in: &cancellables)

        // When location authorization changes (user taps "Enable Location"
        // in Settings), re-apply the pause setting so updates actually start.
        locationService.$authorizationStatus
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                let isAuthorized = status == .authorizedWhenInUse || status == .authorizedAlways
                if isAuthorized {
                    FMFLogger.location.info("Location authorization granted — re-applying pause setting")
                    self.applyLocationPauseSetting()
                }
            }
            .store(in: &cancellables)

        // Seed own display name into NicknameStore, and broadcast to
        // all groups whenever it changes.
        settings.$displayName
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] newName in
                guard let self else { return }
                if let pubkey = self.myPubkeyHex {
                    self.nicknameStore.set(name: newName, for: pubkey)
                }
                Task { @MainActor [weak self] in
                    await self?.broadcastNicknameToAllGroups()
                }
            }
            .store(in: &cancellables)

        // Seed initial value (no broadcast — we do that after Marmot starts)
        if let pubkey = myPubkeyHex, !settings.displayName.isEmpty {
            nicknameStore.set(name: settings.displayName, for: pubkey)
        }
    }

    // MARK: - Deep Link Handling (v0.7)

    /// Route incoming `famstr://` URLs to the appropriate flow.
    func handleIncomingURL(_ url: URL) {
        guard url.scheme == "famstr" else { return }
        switch url.host {
        case "invite":
            guard let code = try? InviteCode.from(url: url).encode() else {
                FMFLogger.marmot.warning("handleIncomingURL: failed to decode invite from \(url)")
                return
            }
            groupListViewModel?.pendingJoinCode = code
            groupListViewModel?.showJoinGroup = true

        case "addmember":
            let parts = url.pathComponents.dropFirst()
            guard parts.count >= 2 else {
                FMFLogger.marmot.warning("handleIncomingURL: malformed addmember URL \(url)")
                return
            }
            let pubkeyHex = String(parts[parts.startIndex])
            let groupId   = String(parts[parts.index(parts.startIndex, offsetBy: 1)])
                                .removingPercentEncoding ?? String(parts[parts.index(parts.startIndex, offsetBy: 1)])
            pendingApproval = PendingApprovalRequest(pubkeyHex: pubkeyHex, groupId: groupId)

        default:
            FMFLogger.marmot.warning("handleIncomingURL: unknown host in \(url)")
        }
    }

    /// Add the member from a pending approval request to their group.
    func approvePendingMember() async {
        guard let approval = pendingApproval else { return }
        pendingApproval = nil
        do {
            try await marmot?.addMember(publicKeyHex: approval.pubkeyHex, toGroup: approval.groupId)
            FMFLogger.marmot.info("Approved member \(approval.pubkeyHex.prefix(8)) into group \(approval.groupId)")
        } catch {
            FMFLogger.marmot.error("Failed to approve member: \(error)")
            approvalError = errorMessage(for: error)
        }
    }

    private func errorMessage(for error: Error) -> String {
        let desc = error.localizedDescription
        // Translate common MarmotError cases into plain English.
        if desc.contains("noKeyPackageFound") || desc.contains("key package") {
            return "Could not find this person's key package on the relay. Ask them to re-open the app and share the invite again."
        }
        return desc
    }

    /// Called once when the app becomes active.
    func onAppear() async {
        guard !didStart else { return }
        didStart = true

        guard let keys = identity.keys else {
            FMFLogger.relay.error("No identity available — cannot connect to relays")
            didStart = false
            startupPhase = .ready   // dismiss splash so onboarding/empty state is visible
            return
        }

        // Connect to Nostr relays
        startupPhase = .connecting
        let enabled = settings.relays.filter(\.isEnabled)
        await relay.connect(keys: keys, relays: enabled)

        // Initialise MLS (keyring-backed, non-fatal if it fails)
        startupPhase = .initialisingEncryption
        do {
            try await mls.initialise()
        } catch {
            let msg = error.localizedDescription
            FMFLogger.mls.error("MLSService init failed: \(msg)")
            mlsError = msg
        }

        // Wire up MarmotService once MLS and relay are ready
        let pubHex = keys.publicKey().toHex()
        let marmotService = MarmotService(
            relay: relay,
            mls: mls,
            publicKeyHex: pubHex,
            keys: keys
        )
        marmotService.locationCache = locationCache
        marmotService.nicknameStore = nicknameStore
        marmotService.pendingInviteStore = pendingInviteStore
        marmotService.settings = settings

        // Load persisted groups from MDK database BEFORE publishing
        // marmotService to the UI — this avoids a flash of empty state
        // and ensures GroupListViewModel sees groups immediately.
        startupPhase = .loadingGroups
        await marmotService.refreshGroups()
        FMFLogger.marmot.info("Loaded \(marmotService.groups.count) group(s) from MDK database")

        // Clean up any pending invites that were resolved while the app was closed.
        let activeIds = Set(marmotService.groups.map(\.mlsGroupId))
        pendingInviteStore.removeResolved(activeGroupIds: activeIds)

        // Clear any dangling pending commits from a previous crash.
        // If the app was killed mid-commit, the MLS state may have a
        // pending commit that can never be merged — clear it so the
        // group can process new events.
        for group in marmotService.groups {
            do {
                try await mls.clearPendingCommit(groupId: group.mlsGroupId)
            } catch {
                // Expected to throw if there's no pending commit — that's fine.
            }
        }

        // Create GroupListViewModel (owned by AppViewModel so it survives
        // SwiftUI view identity changes in RootView's conditional branches).
        self.groupListViewModel = GroupListViewModel(
            marmot: marmotService,
            mls: mls,
            pendingInviteStore: pendingInviteStore,
            displayName: { [weak self] in self?.settings.displayName ?? "" }
        )

        // Now publish to UI — GroupListView will receive a fully loaded marmot.
        self.marmot = marmotService
        startupPhase = .ready

        // Auto-broadcast display name when we join a group via welcome
        marmotService.$lastJoinedGroupId
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak marmotService] groupId in
                guard let self, let marmotService else { return }
                let name = self.settings.displayName
                guard !name.isEmpty else { return }
                Task {
                    try? await marmotService.sendNicknameUpdate(name: name, toGroup: groupId)
                    FMFLogger.chat.info("Auto-broadcast nickname to newly joined group \(groupId)")
                }
            }
            .store(in: &cancellables)

        // Wire location pipeline: LocationService → MarmotService (all groups)
        wireLocationPipeline(marmot: marmotService)

        // Start or stop location based on current pause setting
        applyLocationPauseSetting()

        // Broadcast display name to all groups so other members see it
        await broadcastNicknameToAllGroups()

        // Start Marmot subscriptions LAST — handleNotifications() runs an
        // infinite event loop that never returns, so everything above must
        // complete before this call.
        if await mls.isInitialised {
            FMFLogger.marmot.info("Starting subscriptions, \(marmotService.groups.count) group(s) loaded")
            await marmotService.startSubscriptions()
        } else {
            FMFLogger.marmot.warning("MarmotService created but subscriptions skipped — MLS not initialised")
        }
    }

    // MARK: - Location Pipeline

    /// Wire `LocationService.onLocationUpdate` to broadcast location via MarmotService.
    private func wireLocationPipeline(marmot: MarmotService) {
        locationService.intervalSeconds = settings.locationIntervalSeconds

        locationService.onLocationUpdate = { [weak self, weak marmot] location in
            guard let self, let marmot else { return }
            Task { @MainActor in
                await self.broadcastLocation(location, via: marmot)
            }
        }
        FMFLogger.location.info("Location pipeline wired (interval=\(self.settings.locationIntervalSeconds)s)")
    }

    /// Send a location update to every active MLS group.
    ///
    /// Also inserts the user's own location into `LocationCache` so it appears
    /// on the map immediately — relays may not echo back our own events.
    private func broadcastLocation(_ location: CLLocation, via marmot: MarmotService) async {
        let activeGroups = marmot.groups.filter(\.isActive)
        guard !activeGroups.isEmpty else {
            FMFLogger.location.warning("broadcastLocation: no active groups — \(marmot.groups.count) total group(s)")
            return
        }

        let payload = LocationPayload(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            accuracy: location.horizontalAccuracy,
            timestamp: location.timestamp
        )

        // Insert our own location into the cache immediately so the map
        // shows our pin without waiting for a relay round-trip.
        if let myKey = myPubkeyHex {
            for group in activeGroups {
                locationCache.update(
                    groupId: group.mlsGroupId,
                    memberPubkeyHex: myKey,
                    payload: payload
                )
            }
        }

        for group in activeGroups {
            do {
                try await marmot.sendLocationUpdate(payload, toGroup: group.mlsGroupId)
                FMFLogger.location.info("Location sent to group \(group.mlsGroupId)")
            } catch {
                FMFLogger.location.error("Failed to send location to group \(group.mlsGroupId): \(error)")
            }
        }
    }

    /// Start or stop location updates based on the current pause setting.
    ///
    /// Note: does NOT call `requestAuthorization()` — that's triggered by the
    /// "Enable Location" button in Settings to avoid iOS silently dropping
    /// the permission prompt during early app lifecycle.
    ///
    /// Guards against starting location updates before `wireLocationPipeline()`
    /// has set the `onLocationUpdate` callback. The CLLocationManager delegate
    /// fires via Task after LocationService.init(), which can trigger this
    /// method (via Combine observer) before `onAppear()` wires the pipeline.
    /// Stopping is always allowed so the user can pause sharing immediately.
    private func applyLocationPauseSetting() {
        if settings.isLocationPaused {
            locationService.stopUpdating()
        } else if locationService.onLocationUpdate != nil {
            locationService.startUpdating()
        }
        // If pipeline not yet wired, onAppear() will call this again after wireLocationPipeline().
    }

    // MARK: - Nickname Broadcasting

    /// Send the user's display name to every active group so other members
    /// can resolve it. Called on startup and whenever the name changes.
    func broadcastNicknameToAllGroups() async {
        let name = settings.displayName
        guard !name.isEmpty, let marmot else { return }

        for group in marmot.groups where group.isActive {
            do {
                try await marmot.sendNicknameUpdate(name: name, toGroup: group.mlsGroupId)
            } catch {
                FMFLogger.chat.error("Failed to broadcast nickname to group \(group.mlsGroupId): \(error)")
            }
        }
        FMFLogger.chat.info("Broadcast nickname '\(name)' to \(marmot.groups.filter(\.isActive).count) group(s)")
    }
}
