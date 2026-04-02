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

/// Keychain-backed secure storage with UserDefaults fallback.
///
/// Tries iOS Keychain first. If Keychain is unavailable (Simulator quirks,
/// entitlement issues), falls back to UserDefaults so the identity is stable
/// across launches. This avoids regenerating a new identity every launch.
final class KeychainService: SecureStorage {

    static let shared = KeychainService()
    private init() {}

    private static let service = "org.findmyfam"
    private static let fallbackPrefix = "fmf.keychain.fallback."

    /// Saves a string to the Keychain, overwriting any existing entry.
    /// Falls back to UserDefaults if Keychain write fails.
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

        if status == errSecSuccess {
            return true
        }

        FMFLogger.identity.warning("Keychain save failed [\(key.rawValue)]: OSStatus \(status), using UserDefaults fallback")
        saveFallback(key: key, value: value)
        return true
    }

    /// Returns the stored string from Keychain, falling back to UserDefaults.
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

        // Try UserDefaults fallback
        if let fallback = loadFallback(key: key) {
            FMFLogger.identity.debug("Loaded \(key.rawValue) from UserDefaults fallback")
            return fallback
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
        deleteFallback(key: key)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - UserDefaults fallback

    private func saveFallback(key: KeychainKey, value: String) {
        UserDefaults.standard.set(value, forKey: Self.fallbackPrefix + key.rawValue)
    }

    private func loadFallback(key: KeychainKey) -> String? {
        UserDefaults.standard.string(forKey: Self.fallbackPrefix + key.rawValue)
    }

    private func deleteFallback(key: KeychainKey) {
        UserDefaults.standard.removeObject(forKey: Self.fallbackPrefix + key.rawValue)
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
