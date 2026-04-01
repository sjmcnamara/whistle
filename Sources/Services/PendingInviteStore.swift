import Foundation
import WhistleCore

/// Persists pending group invites — invites where the user has published
/// their key package but hasn't yet received a Welcome event.
///
/// UserDefaults-backed so pending state survives app restarts.
@MainActor
final class PendingInviteStore: ObservableObject {

    private static let storageKey = "fmf.pendingInvites"

    @Published private(set) var pendingInvites: [PendingInvite] = []

    /// - Parameter skipLoad: When `true`, skip loading from UserDefaults (for testing).
    init(skipLoad: Bool = false) {
        if !skipLoad { load() }
    }

    // MARK: - Mutations

    /// Record a new pending invite.
    func add(_ invite: PendingInvite) {
        // Don't duplicate
        guard !pendingInvites.contains(where: { $0.groupHint == invite.groupHint }) else { return }
        pendingInvites.append(invite)
        save()
        FMFLogger.marmot.info("PendingInviteStore: added invite for group \(invite.groupHint)")
    }

    /// Remove a pending invite by group hint (e.g. when a Welcome is received).
    func remove(groupHint: String) {
        pendingInvites.removeAll { $0.groupHint == groupHint }
        save()
        FMFLogger.marmot.info("PendingInviteStore: removed invite for group \(groupHint)")
    }

    /// Remove all pending invites.
    func removeAll() {
        pendingInvites.removeAll()
        save()
    }

    /// Remove invites that match any of the given active group IDs.
    /// Called after receiving Welcomes to clean up resolved invites.
    func removeResolved(activeGroupIds: Set<String>) {
        let before = pendingInvites.count
        pendingInvites.removeAll { activeGroupIds.contains($0.groupHint) }
        let removed = before - pendingInvites.count
        if removed > 0 {
            save()
            FMFLogger.marmot.info("PendingInviteStore: auto-removed \(removed) resolved invite(s)")
        }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(pendingInvites) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([PendingInvite].self, from: data) else {
            return
        }
        pendingInvites = decoded
    }
}
