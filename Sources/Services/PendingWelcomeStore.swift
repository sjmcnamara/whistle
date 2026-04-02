import Foundation
import WhistleCore

/// Persists unsolicited Welcome events that need user approval before joining.
///
/// Welcomes that match a pending invite (user explicitly accepted an invite code)
/// are auto-accepted and never land here. Only unexpected Welcomes — where someone
/// added us by npub without our consent — are queued for review.
@MainActor
final class PendingWelcomeStore: ObservableObject {

    private static let storageKey = "fmf.pendingWelcomes"

    @Published private(set) var pendingWelcomes: [PendingWelcome] = []

    init(skipLoad: Bool = false) {
        if !skipLoad { load() }
    }

    // MARK: - Mutations

    func add(_ welcome: PendingWelcome) {
        guard !pendingWelcomes.contains(where: { $0.mlsGroupId == welcome.mlsGroupId }) else { return }
        pendingWelcomes.append(welcome)
        save()
        FMFLogger.marmot.info("PendingWelcomeStore: queued welcome for group \(welcome.mlsGroupId)")
    }

    func remove(mlsGroupId: String) {
        pendingWelcomes.removeAll { $0.mlsGroupId == mlsGroupId }
        save()
    }

    func removeAll() {
        pendingWelcomes.removeAll()
        save()
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(pendingWelcomes) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([PendingWelcome].self, from: data) else {
            return
        }
        pendingWelcomes = decoded
    }
}
