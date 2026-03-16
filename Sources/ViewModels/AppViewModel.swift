import Foundation
import NostrSDK

/// Root view-model. Owns the core services and coordinates startup.
@MainActor
final class AppViewModel: ObservableObject {

    let identity: IdentityService
    let relay: RelayService
    let mls: MLSService
    let settings: AppSettings

    /// Marmot orchestration layer — bridges MLS ↔ Relay (v0.3).
    private(set) var marmot: MarmotService?

    /// MLS initialisation error surfaced to the UI (non-fatal — app works without it).
    @Published private(set) var mlsError: String?

    init() {
        self.identity = IdentityService()
        self.relay    = RelayService()
        self.mls      = MLSService()
        self.settings = AppSettings.shared
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
        self.marmot = marmotService

        // Start Marmot subscriptions (non-fatal)
        await marmotService.startSubscriptions()
        FMFLogger.marmot.info("MarmotService initialised")
    }
}
