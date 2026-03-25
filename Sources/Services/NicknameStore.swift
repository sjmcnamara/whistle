import Foundation

/// Local store for member display names, backed by UserDefaults.
///
/// Maps `pubkeyHex → displayName`. Updated when:
/// - The user sets their own nickname in Settings
/// - A "nickname" control message is received from another member via MarmotService
@MainActor
final class NicknameStore: ObservableObject {

    private static let storageKey = "fmf.nicknames"

    /// All known nicknames keyed by pubkey hex.
    @Published private(set) var nicknames: [String: String] = [:]

    init() {
        load()
    }

    /// Test-only initialiser that skips UserDefaults loading.
    init(skipLoad: Bool) {
        if !skipLoad { load() }
    }

    /// Get the display name for a pubkey, or return a short hex fallback.
    func displayName(for pubkeyHex: String) -> String {
        nicknames[pubkeyHex] ?? (String(pubkeyHex.prefix(8)) + "…")
    }

    /// Set a nickname for a pubkey. Empty strings remove the entry.
    func set(name: String, for pubkeyHex: String) {
        if name.isEmpty {
            nicknames.removeValue(forKey: pubkeyHex)
        } else {
            nicknames[pubkeyHex] = name
        }
        save()
    }

    /// Remove all nicknames (used during identity replacement).
    func clearAll() {
        nicknames = [:]
        save()
    }

    /// Remove a nickname for a pubkey.
    func remove(for pubkeyHex: String) {
        nicknames.removeValue(forKey: pubkeyHex)
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        nicknames = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(nicknames) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
