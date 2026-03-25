import Foundation

/// Tracks groups where the user has requested to leave but the admin
/// hasn't yet processed the removal (which triggers MLS key rotation).
///
/// UserDefaults-backed so the "Leaving…" state survives app restarts.
@MainActor
final class PendingLeaveStore: ObservableObject {

    private static let storageKey = "fmf.pendingLeaves"

    @Published private(set) var pendingLeaves: Set<String> = []  // groupIds

    init(skipLoad: Bool = false) {
        if !skipLoad { load() }
    }

    // MARK: - Queries

    func contains(_ groupId: String) -> Bool {
        pendingLeaves.contains(groupId)
    }

    // MARK: - Mutations

    func add(_ groupId: String) {
        guard !pendingLeaves.contains(groupId) else { return }
        pendingLeaves.insert(groupId)
        save()
        FMFLogger.marmot.info("PendingLeaveStore: added leave request for group \(groupId)")
    }

    func remove(_ groupId: String) {
        guard pendingLeaves.contains(groupId) else { return }
        pendingLeaves.remove(groupId)
        save()
        FMFLogger.marmot.info("PendingLeaveStore: removed leave request for group \(groupId)")
    }

    /// Remove all pending leaves (used during identity replacement).
    func removeAll() {
        pendingLeaves.removeAll()
        save()
    }

    /// Remove any pending leaves for groups that no longer exist in the active
    /// group list — meaning the admin processed the removal successfully.
    func removeResolved(activeGroupIds: Set<String>) {
        let resolved = pendingLeaves.subtracting(activeGroupIds)
        guard !resolved.isEmpty else { return }
        pendingLeaves.subtract(resolved)
        save()
        FMFLogger.marmot.info("PendingLeaveStore: auto-cleared \(resolved.count) resolved leave(s)")
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(pendingLeaves)) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        pendingLeaves = Set(decoded)
    }
}
