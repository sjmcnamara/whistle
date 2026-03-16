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

    /// Current user's public key hex — convenience for ViewModels.
    var myPubkeyHex: String? { identity.identity?.publicKeyHex }

    /// MLS initialisation error surfaced to the UI (non-fatal — app works without it).
    @Published private(set) var mlsError: String?

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
    }

    /// Called once when the app becomes active.
    func onAppear() async {
        guard let keys = identity.keys else {
            FMFLogger.relay.error("No identity available — cannot connect to relays")
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
        self.marmot = marmotService

        // Start Marmot subscriptions only if MLS initialised successfully
        if await mls.isInitialised {
            await marmotService.startSubscriptions()
            FMFLogger.marmot.info("MarmotService initialised with subscriptions")
        } else {
            FMFLogger.marmot.warning("MarmotService created but subscriptions skipped — MLS not initialised")
        }

        // Wire location pipeline: LocationService → MarmotService (all groups)
        wireLocationPipeline(marmot: marmotService)

        // Start or stop location based on current pause setting
        applyLocationPauseSetting()

        // React to future changes in the pause toggle
        settings.$isLocationPaused
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyLocationPauseSetting()
            }
            .store(in: &cancellables)

        // React to future changes in the location interval
        settings.$locationIntervalSeconds
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newInterval in
                self?.locationService.intervalSeconds = newInterval
                FMFLogger.location.info("Location interval updated to \(newInterval)s")
            }
            .store(in: &cancellables)
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
    }

    /// Send a location update to every active MLS group.
    private func broadcastLocation(_ location: CLLocation, via marmot: MarmotService) async {
        let payload = LocationPayload(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            accuracy: location.horizontalAccuracy,
            timestamp: location.timestamp
        )

        for group in marmot.groups where group.isActive {
            do {
                try await marmot.sendLocationUpdate(payload, toGroup: group.mlsGroupId)
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
    private func applyLocationPauseSetting() {
        if settings.isLocationPaused {
            locationService.stopUpdating()
            FMFLogger.location.info("Location paused by user setting")
        } else {
            locationService.startUpdating()
            FMFLogger.location.info("Location active")
        }
    }
}
