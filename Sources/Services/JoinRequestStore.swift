import Foundation
import WhistleCore

/// Persists incoming join-requests — gift-wrapped by invitees who accepted an
/// invite (kind `MarmotKind.joinRequest`) — so an admin can review them and
/// batch-add the joiners in a single MLS commit.
///
/// Deduped by (group, pubkey): a re-sent request replaces the old one so the
/// freshest KeyPackage wins (an invitee republishes on launch, which is how a
/// laggard becomes addable on a later "Add all").
@MainActor
final class JoinRequestStore: ObservableObject {

    private static let storageKey = "fmf.pendingJoinRequests"

    @Published private(set) var requests: [JoinRequest] = []

    init(skipLoad: Bool = false) {
        if !skipLoad { load() }
    }

    /// Pending requests for a group, in arrival order.
    func requests(forGroup groupId: String) -> [JoinRequest] {
        requests.filter { $0.groupId == groupId }
    }

    // MARK: - Mutations

    func add(_ request: JoinRequest) {
        // Replace any existing request from the same person for the same group
        // so the freshest KeyPackage wins.
        requests.removeAll { $0.groupId == request.groupId && $0.pubkey == request.pubkey }
        requests.append(request)
        save()
        WhistleLogger.marmot.info("JoinRequestStore: queued join-request from \(request.pubkey.prefix(8))… for group \(request.groupId)")
    }

    func remove(groupId: String, pubkey: String) {
        requests.removeAll { $0.groupId == groupId && $0.pubkey == pubkey }
        save()
    }

    func removeAll(forGroup groupId: String) {
        requests.removeAll { $0.groupId == groupId }
        save()
    }

    func removeAll() {
        requests.removeAll()
        save()
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(requests) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([JoinRequest].self, from: data) else {
            return
        }
        requests = decoded
    }
}
