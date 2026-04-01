import Foundation
import WhistleCore
import Combine
import MDKBindings

/// Drives the Chat tab group list — observes `MarmotService.groups`.
@MainActor
final class GroupListViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var groups: [GroupListItem] = []
    @Published var showCreateGroup = false
    @Published var showJoinGroup = false
    /// Pre-populated invite code delivered via deep link / QR scan / NFC.
    @Published var pendingJoinCode: String?

    // MARK: - Dependencies

    private let marmot: MarmotService
    private let mls: MLSService
    private let displayName: () -> String
    let pendingInviteStore: PendingInviteStore
    let pendingLeaveStore: PendingLeaveStore
    let healthTracker: GroupHealthTracker
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Unread tracking

    private static let lastReadKey = "groupLastReadTimestamps"
    private static let lastChatKey  = "groupLastChatTimestamps"

    /// Per-group epoch timestamp of the last time the user viewed the chat.
    private var lastReadTimestamps: [String: TimeInterval] {
        get { UserDefaults.standard.dictionary(forKey: Self.lastReadKey) as? [String: TimeInterval] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastReadKey) }
    }

    /// Per-group epoch timestamp of the last chat message received (chat-only — not location/nickname/etc.).
    /// Used by refreshItems so that non-chat MLS events don't re-trigger the unread indicator.
    private var lastChatTimestamps: [String: TimeInterval] {
        get { UserDefaults.standard.dictionary(forKey: Self.lastChatKey) as? [String: TimeInterval] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastChatKey) }
    }

    /// Call when the user opens a group chat to clear the unread indicator.
    func markAsRead(groupId: String) {
        lastReadTimestamps[groupId] = Date().timeIntervalSince1970
        // Update the list to clear bold state
        if let idx = groups.firstIndex(where: { $0.id == groupId }), groups[idx].hasUnread {
            groups[idx].hasUnread = false
        }
    }

    // MARK: - Item model

    struct GroupListItem: Identifiable, Hashable {
        let id: String          // mlsGroupId
        let name: String
        let memberCount: Int
        let lastActivity: Date?
        let isActive: Bool
        var hasUnread: Bool = false
    }

    // MARK: - Init

    init(
        marmot: MarmotService,
        mls: MLSService,
        pendingInviteStore: PendingInviteStore,
        pendingLeaveStore: PendingLeaveStore,
        displayName: @escaping () -> String = { "" }
    ) {
        self.marmot = marmot
        self.mls = mls
        self.pendingInviteStore = pendingInviteStore
        self.pendingLeaveStore = pendingLeaveStore
        self.healthTracker = marmot.healthTracker
        self.displayName = displayName

        marmot.$groups
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] groups in
                Task { await self?.refreshItems(from: groups) }
            }
            .store(in: &cancellables)

        // When a new chat message arrives, mark that group as unread immediately
        // and persist the timestamp so refreshItems can use it instead of MDK's
        // lastMessageAt (which advances for location/nickname events too).
        marmot.$lastChatMessageGroupId
            .compactMap { $0 }
            .sink { [weak self] groupId in
                guard let self else { return }
                var stamps = self.lastChatTimestamps
                stamps[groupId] = Date().timeIntervalSince1970
                self.lastChatTimestamps = stamps
                if let idx = self.groups.firstIndex(where: { $0.id == groupId }) {
                    self.groups[idx].hasUnread = true
                }
            }
            .store(in: &cancellables)

        // Merge child objectWillChange and debounce to avoid cascading renders.
        Publishers.Merge3(
            pendingInviteStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            pendingLeaveStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            healthTracker.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &cancellables)
    }

    // MARK: - Refresh

    func refresh() async {
        await marmot.refreshGroups()
    }

    private func refreshItems(from mdkGroups: [Group]) async {
        // Fetch member counts first — this is the only async work.
        var memberCounts: [String: Int] = [:]
        for group in mdkGroups {
            memberCounts[group.mlsGroupId] = (try? await mls.getMembers(groupId: group.mlsGroupId).count) ?? 0
        }
        // Read timestamps AFTER all awaits so any markAsRead calls that happened
        // during suspension are reflected — avoids showing already-read groups as unread.
        // Use lastChatTimestamps (chat-only) rather than group.lastMessageAt, which MDK
        // advances for every MLS event including location and nickname updates.
        let readTimestamps = lastReadTimestamps
        let chatTimestamps = lastChatTimestamps
        var items: [GroupListItem] = []
        for group in mdkGroups {
            let lastMessageEpoch = group.lastMessageAt.map { TimeInterval($0) }
            let lastChatEpoch = chatTimestamps[group.mlsGroupId]
            let lastRead = readTimestamps[group.mlsGroupId] ?? 0
            let hasUnread = lastChatEpoch.map { $0 > lastRead } ?? false
            items.append(GroupListItem(
                id: group.mlsGroupId,
                name: group.name.isEmpty ? "Unnamed Group" : group.name,
                memberCount: memberCounts[group.mlsGroupId] ?? 0,
                lastActivity: lastMessageEpoch.map { Date(timeIntervalSince1970: $0) },
                isActive: group.isActive,
                hasUnread: hasUnread
            ))
        }
        self.groups = items.filter { !pendingLeaveStore.contains($0.id) }

        // Clean up pending leaves for groups that no longer exist
        // (admin processed the removal).
        let activeIds = Set(items.map(\.id))
        pendingLeaveStore.removeResolved(activeGroupIds: activeIds)
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

    /// Poll relays for gift-wrap events that may have been missed by the
    /// real-time subscription. Called by JoinGroupView while waiting for Welcome.
    func fetchMissedWelcomes() async {
        await marmot.fetchMissedGiftWraps()
    }

    /// Send a leave request to the group and mark it as "Leaving…" locally.
    func requestLeaveGroup(id: String) async {
        do {
            try await marmot.sendLeaveRequest(groupId: id)
            pendingLeaveStore.add(id)
        } catch {
            FMFLogger.chat.error("Failed to request leave for group \(id): \(error)")
        }
    }

    /// Force relay reconnection after MPC / NearbyShare activity.
    func forceReconnectRelays() async {
        await marmot.forceReconnectRelays()
    }

    func joinGroup(inviteCode: String) async throws {
        // Decode first so we can extract the group hint for pending state.
        let invite = try InviteCode.decode(from: inviteCode)

        try await marmot.acceptInvite(inviteCode)

        // If the user previously left this group, clear the stale pending leave
        // marker so the group reappears once Welcome is accepted.
        pendingLeaveStore.remove(invite.groupId)

        // Record as pending — will be auto-removed when Welcome arrives.
        pendingInviteStore.add(PendingInvite(
            groupHint: invite.groupId,
            inviterNpub: invite.inviterNpub
        ))
    }
}
