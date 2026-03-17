import Foundation
import Combine
import MDKBindings

/// Drives the Chat tab group list — observes `MarmotService.groups`.
@MainActor
final class GroupListViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var groups: [GroupListItem] = []
    @Published var showCreateGroup = false
    @Published var showJoinGroup = false

    // MARK: - Dependencies

    private let marmot: MarmotService
    private let mls: MLSService
    private let displayName: () -> String
    let pendingInviteStore: PendingInviteStore
    let healthTracker: GroupHealthTracker
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Item model

    struct GroupListItem: Identifiable, Hashable {
        let id: String          // mlsGroupId
        let name: String
        let memberCount: Int
        let lastActivity: Date?
        let isActive: Bool
    }

    // MARK: - Init

    init(
        marmot: MarmotService,
        mls: MLSService,
        pendingInviteStore: PendingInviteStore,
        displayName: @escaping () -> String = { "" }
    ) {
        self.marmot = marmot
        self.mls = mls
        self.pendingInviteStore = pendingInviteStore
        self.healthTracker = marmot.healthTracker
        self.displayName = displayName

        marmot.$groups
            .receive(on: DispatchQueue.main)
            .sink { [weak self] groups in
                Task { await self?.refreshItems(from: groups) }
            }
            .store(in: &cancellables)

        // Forward pending invite changes so the view re-renders.
        pendingInviteStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Forward health tracker changes so unhealthy badges update.
        healthTracker.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Refresh

    func refresh() async {
        await marmot.refreshGroups()
    }

    private func refreshItems(from mdkGroups: [Group]) async {
        var items: [GroupListItem] = []
        for group in mdkGroups {
            let memberCount = (try? await mls.getMembers(groupId: group.mlsGroupId).count) ?? 0
            items.append(GroupListItem(
                id: group.mlsGroupId,
                name: group.name.isEmpty ? "Unnamed Group" : group.name,
                memberCount: memberCount,
                lastActivity: group.lastMessageAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                isActive: group.isActive
            ))
        }
        self.groups = items
    }

    // MARK: - Actions

    func createGroup(name: String) async throws -> String {
        let relays = marmot.activeRelayURLs
        let groupId = try await marmot.createGroup(name: name, relays: relays)

        // Broadcast our display name so other members see it immediately
        let dn = displayName()
        if !dn.isEmpty {
            try? await marmot.sendNicknameUpdate(name: dn, toGroup: groupId)
        }

        return groupId
    }

    func joinGroup(inviteCode: String) async throws {
        // Decode first so we can extract the group hint for pending state.
        let invite = try InviteCode.decode(from: inviteCode)

        try await marmot.acceptInvite(inviteCode)

        // Record as pending — will be auto-removed when Welcome arrives.
        pendingInviteStore.add(PendingInvite(
            groupHint: invite.groupId,
            inviterNpub: invite.inviterNpub
        ))
    }
}
