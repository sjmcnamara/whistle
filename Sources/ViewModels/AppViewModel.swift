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
    private(set) var marmot: MarmotService?

    // MARK: - Location (v0.4)

    /// CoreLocation wrapper — publishes via callback.
    let locationService: LocationService

    /// Shared in-memory cache of group members' latest locations.
    let locationCache: LocationCache

    /// View-model for the family map — observes `locationCache`.
    let locationViewModel: LocationViewModel

    /// MLS initialisation error surfaced to the UI (non-fatal — app works without it).
    @Published private(set) var mlsError: String?

    private var settingsCancellable: AnyCancellable?

    init() {
        self.identity        = IdentityService()
        self.relay           = RelayService()
        self.mls             = MLSService()
        self.settings        = AppSettings.shared
        self.locationService = LocationService()
        self.locationCache   = LocationCache()

        let cache = self.locationCache
        let settingsRef = self.settings
        self.locationViewModel = LocationViewModel(
            locationCache: cache,
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
        self.marmot = marmotService

        // Start Marmot subscriptions (non-fatal)
        await marmotService.startSubscriptions()
        FMFLogger.marmot.info("MarmotService initialised")

        // Wire location pipeline: LocationService → MarmotService (all groups)
        wireLocationPipeline(marmot: marmotService)

        // Start or stop location based on current pause setting
        applyLocationPauseSetting()

        // React to future changes in the pause toggle
        settingsCancellable = settings.$isLocationPaused
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyLocationPauseSetting()
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
    private func applyLocationPauseSetting() {
        if settings.isLocationPaused {
            locationService.stopUpdating()
            FMFLogger.location.info("Location paused by user setting")
        } else {
            locationService.requestAuthorization()
            locationService.startUpdating()
            FMFLogger.location.info("Location active")
        }
    }
}
