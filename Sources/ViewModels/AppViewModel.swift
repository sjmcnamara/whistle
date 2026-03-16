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

    /// GroupListViewModel — owned here so it survives SwiftUI view identity
    /// changes. Created once after MarmotService is ready.
    @Published private(set) var groupListViewModel: GroupListViewModel?

    /// Current user's public key hex — convenience for ViewModels.
    var myPubkeyHex: String? { identity.identity?.publicKeyHex }

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
        self.nicknameStore   = NicknameStore()

        let cache = self.locationCache
        let settingsRef = self.settings
        let nicknames = self.nicknameStore
        self.locationViewModel = LocationViewModel(
            locationCache: cache,
            nicknameStore: nicknames,
            intervalSeconds: { settingsRef.locationIntervalSeconds }
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

    /// Called once when the app becomes active.
    func onAppear() async {
        guard !didStart else { return }
        didStart = true

        guard let keys = identity.keys else {
            FMFLogger.relay.error("No identity available — cannot connect to relays")
            didStart = false
            return
        }

        // Connect to Nostr relays
        let enabled = settings.relays.filter(\.isEnabled)
        await relay.connect(keys: keys, relays: enabled)

        // Initialise MLS (keyring-backed, non-fatal if it fails)
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

        // Load persisted groups from MDK database BEFORE publishing
        // marmotService to the UI — this avoids a flash of empty state
        // and ensures GroupListViewModel sees groups immediately.
        await marmotService.refreshGroups()
        FMFLogger.marmot.info("Loaded \(marmotService.groups.count) group(s) from MDK database")

        // Create GroupListViewModel (owned by AppViewModel so it survives
        // SwiftUI view identity changes in RootView's conditional branches).
        self.groupListViewModel = GroupListViewModel(
            marmot: marmotService,
            mls: mls,
            displayName: { [weak self] in self?.settings.displayName ?? "" }
        )

        // Now publish to UI — GroupListView will receive a fully loaded marmot.
        self.marmot = marmotService

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
