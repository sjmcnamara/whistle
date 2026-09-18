import Foundation
import WhistleCore
import NostrSDK

/// Manages the user's Nostr identity.
///
/// On first launch a new keypair is generated and the nsec is stored via `storage`.
/// On subsequent launches the nsec is restored and the `Keys` object reconstructed.
/// The nsec is never exposed outside this class.
@MainActor
final class IdentityService: ObservableObject {

    /// The displayable (public-only) identity. Nil only transiently during init,
    /// or persistently while `identityAnomalyDetected` is true.
    @Published private(set) var identity: NostrIdentity?

    /// True when this is the first time the app has run on this device.
    @Published private(set) var isNewUser = false

    /// True when Keychain has no stored nsec, but local MLS/group data already
    /// exists on disk from a previous session — a strong signal this is NOT a
    /// genuine first launch. Silently generating a new identity in this state
    /// would orphan every existing group with no warning, exactly what
    /// happened to real users in the v1.8.7 bundle-id rename (`#203`): the
    /// keychain-access-groups entitlement dropped the old group entirely
    /// instead of keeping both during a transition, so the real identity
    /// became unreachable — Keychain looked empty, and a fresh identity was
    /// generated silently. The (non-Keychain-scoped) MDK database was
    /// unaffected, so every existing group kept working under the orphaned
    /// identity's MLS credentials while everything else silently moved on.
    /// `initialise()` refuses to auto-generate when this is true; the caller
    /// must explicitly call `createNewIdentityDespiteAnomaly()` to proceed.
    @Published private(set) var identityAnomalyDetected = false

    /// The live nostr-sdk-swift Keys object used to sign events.
    /// Accessed by RelayService; never exposed further up the stack.
    private(set) var keys: Keys?

    // MARK: - Init

    /// - Parameters:
    ///   - storage: Injected key storage (defaults to Keychain for production).
    ///   - hasExistingLocalData: Injected check for "does this device already
    ///     have real local group data from a previous session" (defaults to
    ///     checking the real `whistle.db` on disk). Overridable in tests so
    ///     the anomaly path doesn't depend on the test runner's own
    ///     filesystem state.
    init(
        storage: SecureStorage = EncryptedSecureStorage.shared,
        hasExistingLocalData: @escaping () -> Bool = IdentityService.hasExistingLocalGroupDataOnDisk
    ) {
        self.storage = storage
        self.hasExistingLocalData = hasExistingLocalData
        // Loading/creating the identity is deferred to initialise() — doing it
        // here blocks the main thread (Rust FFI init + Keychain/SE crypto)
        // before SwiftUI renders.
    }

    /// Load or generate the Nostr identity.
    ///
    /// Runs Rust key operations (Keys.generate / Keys.parse) and Secure Enclave
    /// crypto on a background thread so the main thread stays free to render the
    /// splash screen. Must be called from AppViewModel.onAppear() after the first
    /// Task.yield().
    func initialise() async {
        switch await Self.loadOrCreate(storage: storage, hasExistingLocalData: hasExistingLocalData, allowCreateOnAnomaly: false) {
        case .restored(let keys, let npub, let pubHex):
            self.keys = keys
            self.identity = NostrIdentity(npub: npub, publicKeyHex: pubHex)
            self.isNewUser = false
            WhistleLogger.identity.info("Identity restored: \(npub)")
        case .created(let keys, let npub, let pubHex):
            self.keys = keys
            self.identity = NostrIdentity(npub: npub, publicKeyHex: pubHex)
            self.isNewUser = true
            WhistleLogger.identity.info("New identity created: \(npub)")
        case .anomaly:
            self.identityAnomalyDetected = true
            WhistleLogger.identity.error("Identity anomaly: local group data exists on disk but no nsec found in Keychain — refusing to silently create a new identity")
        case .failure:
            WhistleLogger.identity.error("Fatal: could not create/load identity")
        }
    }

    /// Explicit, user-consented override for the anomaly case: create a brand
    /// new identity even though existing local group data was found. Never
    /// called automatically — only from a UI the user has to actively confirm.
    /// Every existing group's MLS state stays on disk regardless (it isn't
    /// tied to Keychain), so this doesn't erase anything — it just means this
    /// new identity won't be recognized as a member of groups the old,
    /// now-unreachable identity belonged to.
    func createNewIdentityDespiteAnomaly() async {
        switch await Self.loadOrCreate(storage: storage, hasExistingLocalData: hasExistingLocalData, allowCreateOnAnomaly: true) {
        case .created(let keys, let npub, let pubHex):
            self.keys = keys
            self.identity = NostrIdentity(npub: npub, publicKeyHex: pubHex)
            self.isNewUser = true
            self.identityAnomalyDetected = false
            WhistleLogger.identity.info("New identity created despite anomaly (explicit user choice): \(npub)")
        default:
            WhistleLogger.identity.error("Fatal: could not create identity despite anomaly override")
        }
    }

    private enum BootOutcome {
        case restored(keys: Keys, npub: String, pubHex: String)
        case created(keys: Keys, npub: String, pubHex: String)
        /// Keychain has no nsec, but local MLS/group data already exists —
        /// not a genuine first launch. See `identityAnomalyDetected`.
        case anomaly
        case failure
    }

    private static func loadOrCreate(
        storage: SecureStorage,
        hasExistingLocalData: @escaping () -> Bool,
        allowCreateOnAnomaly: Bool
    ) async -> BootOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if let nsec = storage.load(key: .nsec) {
                    guard let restored = try? Keys.parse(secretKey: nsec),
                          let npub = try? restored.publicKey().toBech32() else {
                        continuation.resume(returning: .failure)
                        return
                    }
                    let pubHex = restored.publicKey().toHex()
                    continuation.resume(returning: .restored(keys: restored, npub: npub, pubHex: pubHex))
                    return
                }

                if hasExistingLocalData(), !allowCreateOnAnomaly {
                    continuation.resume(returning: .anomaly)
                    return
                }

                let newKeys = Keys.generate()
                guard let nsec = try? newKeys.secretKey().toBech32(),
                      let npub = try? newKeys.publicKey().toBech32() else {
                    continuation.resume(returning: .failure)
                    return
                }
                let pubHex = newKeys.publicKey().toHex()
                storage.save(key: .nsec, value: nsec)
                continuation.resume(returning: .created(keys: newKeys, npub: npub, pubHex: pubHex))
            }
        }
    }

    /// True if a real, non-trivial MLS database already exists on disk from a
    /// previous session (checked by size, not just presence, to ignore an
    /// empty/stub file). A genuine first-ever launch has neither this nor a
    /// stored nsec; a device that's actually been used has this regardless of
    /// whether its identity is currently reachable. The production default
    /// for `hasExistingLocalData`.
    static func hasExistingLocalGroupDataOnDisk() -> Bool {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for name in ["whistle.db", "findmyfam-mdk.db"] {
            let path = docs.appendingPathComponent(name).path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int, size > 100 {
                return true
            }
        }
        return false
    }

    // MARK: - Import / Export (v0.8.2)

    /// Returns the raw nsec from secure storage so it can be encrypted for export.
    func exportNsec() -> String? {
        storage.load(key: .nsec)
    }

    /// Explicitly destroy the current key from secure storage.
    ///
    /// Called during burn identity to ensure old key material is deleted from
    /// the Keychain (and UserDefaults fallback) before the new key is written.
    /// The in-memory `keys` reference is also nil'd so no stale reference remains.
    func destroyCurrentKey() {
        storage.delete(key: .nsec)
        self.keys = nil
        self.identity = nil
        WhistleLogger.identity.info("Current key destroyed from secure storage")
    }

    /// Replace the current identity with an imported nsec.
    ///
    /// Validates the key, stores it, and updates the in-memory `keys` and `identity`.
    /// The caller (AppViewModel) is responsible for tearing down and restarting
    /// all services that depend on the identity (relays, MLS, groups, caches).
    func importKey(nsec: String) throws {
        let imported = try Keys.parse(secretKey: nsec)
        let npub     = try imported.publicKey().toBech32()
        let pubHex   = imported.publicKey().toHex()

        storage.save(key: .nsec, value: nsec)

        self.keys      = imported
        self.identity  = NostrIdentity(npub: npub, publicKeyHex: pubHex)
        self.isNewUser = false

        WhistleLogger.identity.info("Identity imported: \(npub)")
    }

    // MARK: - Private

    private let storage: SecureStorage
    private let hasExistingLocalData: () -> Bool
}
