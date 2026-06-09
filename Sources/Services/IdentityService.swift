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

    /// The displayable (public-only) identity. Nil only transiently during init.
    @Published private(set) var identity: NostrIdentity?

    /// True when this is the first time the app has run on this device.
    @Published private(set) var isNewUser = false

    /// The live nostr-sdk-swift Keys object used to sign events.
    /// Accessed by RelayService; never exposed further up the stack.
    private(set) var keys: Keys?

    // MARK: - Init

    /// - Parameter storage: Injected key storage (defaults to Keychain for production).
    init(storage: SecureStorage = EncryptedSecureStorage.shared) {
        self.storage = storage
        // loadOrCreate() is deferred to initialise() — calling it here blocks the
        // main thread (Rust FFI init + Keychain/SE crypto) before SwiftUI renders.
    }

    /// Load or generate the Nostr identity.
    ///
    /// Runs Rust key operations (Keys.generate / Keys.parse) and Secure Enclave
    /// crypto on a background thread so the main thread stays free to render the
    /// splash screen. Must be called from AppViewModel.onAppear() after the first
    /// Task.yield().
    func initialise() async {
        typealias BootResult = (keys: Keys, npub: String, pubHex: String, isNew: Bool)
        let storage = self.storage

        let result: BootResult? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if let nsec = storage.load(key: .nsec) {
                    guard let restored = try? Keys.parse(secretKey: nsec),
                          let npub = try? restored.publicKey().toBech32() else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let pubHex = restored.publicKey().toHex()
                    continuation.resume(returning: (restored, npub, pubHex, false))
                } else {
                    let newKeys = Keys.generate()
                    guard let nsec = try? newKeys.secretKey().toBech32(),
                          let npub = try? newKeys.publicKey().toBech32() else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let pubHex = newKeys.publicKey().toHex()
                    storage.save(key: .nsec, value: nsec)
                    continuation.resume(returning: (newKeys, npub, pubHex, true))
                }
            }
        }

        guard let result else {
            WhistleLogger.identity.error("Fatal: could not create/load identity")
            return
        }

        self.keys      = result.keys
        self.identity  = NostrIdentity(npub: result.npub, publicKeyHex: result.pubHex)
        self.isNewUser = result.isNew
        if result.isNew {
            WhistleLogger.identity.info("New identity created: \(result.npub)")
        } else {
            WhistleLogger.identity.info("Identity restored: \(result.npub)")
        }
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

    private func loadOrCreate() {
        if let nsec = storage.load(key: .nsec) {
            restoreKeys(from: nsec)
        } else {
            createNewIdentity()
        }
    }

    private func restoreKeys(from nsec: String) {
        do {
            let restored = try Keys.parse(secretKey: nsec)
            let npub     = try restored.publicKey().toBech32()
            let pubHex   = restored.publicKey().toHex()

            self.keys      = restored
            self.identity  = NostrIdentity(npub: npub, publicKeyHex: pubHex)
            self.isNewUser = false

            WhistleLogger.identity.info("Identity restored: \(npub)")
        } catch {
            WhistleLogger.identity.error("Failed to restore keys, generating new ones: \(error)")
            createNewIdentity()
        }
    }

    private func createNewIdentity() {
        let newKeys = Keys.generate()
        do {
            let nsec   = try newKeys.secretKey().toBech32()
            let npub   = try newKeys.publicKey().toBech32()
            let pubHex = newKeys.publicKey().toHex()

            storage.save(key: .nsec, value: nsec)

            self.keys      = newKeys
            self.identity  = NostrIdentity(npub: npub, publicKeyHex: pubHex)
            self.isNewUser = true

            WhistleLogger.identity.info("New identity created: \(npub)")
        } catch {
            WhistleLogger.identity.error("Fatal: could not create identity: \(error)")
        }
    }
}
