import Foundation
import Security

// MARK: - Key enum

/// Keys used to address items in the Keychain.
enum KeychainKey: String {
    /// The user's nsec (Nostr secret key), bech32-encoded.
    case nsec = "org.findmyfam.nsec"
}

// MARK: - Protocol

/// Abstraction over secure key-value storage.
/// Production code uses `KeychainService`; tests inject `InMemorySecureStorage`.
protocol SecureStorage {
    @discardableResult func save(key: KeychainKey, value: String) -> Bool
    func load(key: KeychainKey) -> String?
    @discardableResult func delete(key: KeychainKey) -> Bool
}

// MARK: - Keychain implementation

/// Keychain-backed secure storage.
///
/// Uses iOS Keychain with `kSecAttrAccessibleWhenUnlocked` protection.
/// No UserDefaults fallback — the nsec must never be stored in plaintext
/// storage (UserDefaults is included in unencrypted backups).
final class KeychainService: SecureStorage {

    static let shared = KeychainService()
    private init() {}

    private static let service = "org.findmyfam"

    // Legacy fallback key prefix — used only for one-time migration.
    private static let legacyFallbackPrefix = "fmf.keychain.fallback."

    /// Saves a string to the Keychain, overwriting any existing entry.
    @discardableResult
    func save(key: KeychainKey, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)

        if status != errSecSuccess {
            FMFLogger.identity.error("Keychain save failed [\(key.rawValue)]: OSStatus \(status)")
            return false
        }

        // If we successfully saved to Keychain, remove any legacy fallback
        removeLegacyFallback(key: key)
        return true
    }

    /// Returns the stored string from Keychain.
    /// On first load, migrates any legacy UserDefaults fallback into Keychain.
    func load(key: KeychainKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) {
            return value
        }

        // One-time migration: move legacy UserDefaults fallback into Keychain
        if let legacy = UserDefaults.standard.string(forKey: Self.legacyFallbackPrefix + key.rawValue) {
            FMFLogger.identity.warning("Migrating \(key.rawValue) from UserDefaults fallback to Keychain")
            if save(key: key, value: legacy) {
                removeLegacyFallback(key: key)
                return legacy
            }
        }

        return nil
    }

    /// Deletes a Keychain item. Returns `true` on success or if the item didn't exist.
    @discardableResult
    func delete(key: KeychainKey) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        removeLegacyFallback(key: key)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Legacy migration

    /// Remove any nsec that was previously stored in UserDefaults by the old fallback path.
    private func removeLegacyFallback(key: KeychainKey) {
        UserDefaults.standard.removeObject(forKey: Self.legacyFallbackPrefix + key.rawValue)
    }
}

// MARK: - In-memory implementation (tests)

/// Thread-unsafe in-memory storage for use in unit tests.
final class InMemorySecureStorage: SecureStorage {
    private var store: [String: String] = [:]

    @discardableResult
    func save(key: KeychainKey, value: String) -> Bool {
        store[key.rawValue] = value
        return true
    }

    func load(key: KeychainKey) -> String? {
        store[key.rawValue]
    }

    @discardableResult
    func delete(key: KeychainKey) -> Bool {
        store.removeValue(forKey: key.rawValue)
        return true
    }
}
