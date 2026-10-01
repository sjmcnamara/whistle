import Foundation
import MarmotKit

/// An in-memory `SecretStore` for tests, standing in for the platform keychain.
///
/// MarmotKit keeps account signing keys in the platform keyring by default.
/// That works in the app, which carries the entitlement for it, but an XCTest
/// bundle does not — the runtime fails before it reaches the network with
/// `KeystoreUnavailable: "A required entitlement isn't present."`, which looks
/// for all the world like a connectivity problem.
///
/// Injecting a store sidesteps the entitlement entirely and makes the tests
/// hermetic: no keychain state survives a run, so tests cannot contaminate
/// each other or the developer's keychain. `SecretStore` is one of only two
/// callback interfaces MarmotKit exposes, and `MarmotOptions.secretStore` is
/// the sanctioned way to supply one.
///
/// Upstream is explicit that this is "a storage boundary, not a security
/// boundary" — plaintext key hex crosses it in both directions. Keeping it in
/// a dictionary is therefore no weaker than intended, but it is also the
/// reason this type lives in the test target and must never ship.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {

    /// The runtime calls these from worker threads and may call them
    /// concurrently, so every access is serialised.
    private let lock = NSLock()
    private var secrets: [Key: String] = [:]

    private struct Key: Hashable {
        let label: String
        let accountIdHex: String
    }

    func hasSecretForLabel(label: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return secrets.keys.contains { $0.label == label }
    }

    func hasSecretForAccountId(accountIdHex: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return secrets.keys.contains { $0.accountIdHex == accountIdHex }
    }

    func writeSecret(label: String, accountIdHex: String, secretKeyHex: String) throws {
        lock.lock(); defer { lock.unlock() }
        secrets[Key(label: label, accountIdHex: accountIdHex)] = secretKeyHex
    }

    func loadSecret(label: String, accountIdHex: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let secret = secrets[Key(label: label, accountIdHex: accountIdHex)] else {
            // The contract names this error specifically for a missing
            // credential; a generic failure would make the runtime treat a
            // first-run account as a broken one.
            throw MarmotKitError.SecretNotFound(details: "no secret for \(accountIdHex)")
        }
        return secret
    }

    /// Removing a missing credential succeeds, per the protocol contract.
    func removeSecret(label: String, accountIdHex: String) throws {
        lock.lock(); defer { lock.unlock() }
        secrets[Key(label: label, accountIdHex: accountIdHex)] = nil
    }
}
