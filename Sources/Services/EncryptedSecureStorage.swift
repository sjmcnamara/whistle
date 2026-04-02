import Foundation

/// A `SecureStorage` wrapper that transparently encrypts the nsec using the
/// Secure Enclave before storing it in the Keychain.
///
/// Non-nsec keys pass through to the underlying `KeychainService` unchanged.
/// On devices without a Secure Enclave (simulators), falls back to plain Keychain storage.
///
/// **Migration:** If a plaintext nsec (starts with `nsec1`) is found in the Keychain,
/// it is automatically re-encrypted with SE and the plaintext overwritten.
final class EncryptedSecureStorage: SecureStorage {

    static let shared = EncryptedSecureStorage()

    private let keychain: KeychainService

    init(keychain: KeychainService = .shared) {
        self.keychain = keychain

        if SecureEnclaveService.isAvailable {
            FMFLogger.identity.info("Secure Enclave available — nsec will be hardware-wrapped")
        } else {
            FMFLogger.identity.warning("Secure Enclave unavailable — nsec stored in Keychain without SE wrapping")
        }
    }

    // MARK: - SecureStorage conformance

    @discardableResult
    func save(key: KeychainKey, value: String) -> Bool {
        guard key == .nsec, SecureEnclaveService.isAvailable else {
            return keychain.save(key: key, value: value)
        }

        do {
            let result = try SecureEnclaveService.encrypt(nsec: value)

            // Store all three pieces
            guard keychain.saveData(key: .sePrivateKey, value: result.sePrivateKeyData, thisDeviceOnly: true),
                  keychain.saveData(key: .seEphemeralPublicKey, value: result.ephemeralPublicKey),
                  keychain.save(key: .nsec, value: result.sealedBox.base64EncodedString()) else {
                FMFLogger.identity.error("Failed to store SE-encrypted nsec components")
                return false
            }

            FMFLogger.identity.info("nsec encrypted with Secure Enclave and stored")
            return true
        } catch {
            FMFLogger.identity.error("SE encryption failed, storing nsec in plain Keychain: \(error)")
            return keychain.save(key: key, value: value)
        }
    }

    func load(key: KeychainKey) -> String? {
        guard key == .nsec, SecureEnclaveService.isAvailable else {
            return keychain.load(key: key)
        }

        // Try to load and decrypt SE-wrapped nsec
        if let stored = keychain.load(key: .nsec) {
            // Check if it's a plaintext nsec (pre-migration)
            if stored.hasPrefix("nsec1") {
                FMFLogger.identity.info("Migrating plaintext nsec to SE-wrapped encryption")
                if save(key: .nsec, value: stored) {
                    return stored
                }
                // Migration failed — return plaintext anyway
                return stored
            }

            // It should be a base64-encoded sealed box
            guard let sealedBoxData = Data(base64Encoded: stored),
                  let seKeyData = keychain.loadData(key: .sePrivateKey),
                  let ephemeralPubData = keychain.loadData(key: .seEphemeralPublicKey) else {
                FMFLogger.identity.error("SE-wrapped nsec found but supporting keys missing")
                return nil
            }

            do {
                let nsec = try SecureEnclaveService.decrypt(
                    sePrivateKeyData: seKeyData,
                    ephemeralPublicKey: ephemeralPubData,
                    sealedBoxData: sealedBoxData
                )
                return nsec
            } catch {
                FMFLogger.identity.error("SE decryption failed: \(error)")
                return nil
            }
        }

        return nil
    }

    @discardableResult
    func delete(key: KeychainKey) -> Bool {
        if key == .nsec {
            // Clean up all SE-related keys when deleting the nsec
            keychain.delete(key: .sePrivateKey)
            keychain.delete(key: .seEphemeralPublicKey)
        }
        return keychain.delete(key: key)
    }

    // MARK: - Data passthrough

    @discardableResult
    func saveData(key: KeychainKey, value: Data, thisDeviceOnly: Bool = false) -> Bool {
        keychain.saveData(key: key, value: value, thisDeviceOnly: thisDeviceOnly)
    }

    func loadData(key: KeychainKey) -> Data? {
        keychain.loadData(key: key)
    }
}
