import Foundation
import WhistleCore
import Combine

/// Drives the Groups tab group list — observes `MarmotKitService.groups`.
@MainActor
final class GroupListViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var groups: [GroupListItem] = []
    @Published var showCreateGroup = false
    /// False until account setup finishes publishing.
    ///
    /// Creating a group needs a published account; before that MarmotKit
    /// rejects it with `OnboardingRequired`. The action used to be offered
    /// anyway and failed when tapped, which read as a broken button rather
    /// than as "not ready yet". Mirrors `MarmotKitService.accountIsReady`.
    @Published private(set) var isAccountReady = false

    /// Shows this device's own member code, so an admin can scan it.
    ///
    /// Replaces v1's `showJoinGroup`. There is no "join" action under
    /// protocol v2 — a non-member has no out-of-group message to send, so the
    /// only thing they can do is display who they are and be added.
    @Published var showMyCode = false

    // MARK: - Dependencies

    private let marmot: MarmotKitService
    private let displayName: () -> String
    private let settings: AppSettings
    private let notices: NoticeCenter
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
        /// Whether the user has paused their own outbound sharing to this group
        /// (see `AppSettings.pausedGroupIds`) — independent of `isActive`.
        var isSharingPaused: Bool = false
    }

    // MARK: - Init

    init(
        marmot: MarmotKitService,
        notices: NoticeCenter,
        settings: AppSettings = .shared,
        displayName: @escaping () -> String = { "" }
    ) {
        self.marmot = marmot
        self.notices = notices
        self.settings = settings
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

        // Reflect per-group pause toggles immediately, without waiting for the
        // next marmot.$groups emission to rebuild the whole list.
        // Observed, not polled. The first version polled for 60 seconds and
        // then gave up for good; real setup on device took longer than that,
        // so Create Group stayed disabled for the whole session after the
        // account had in fact published.
        marmot.$accountIsReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in self?.isAccountReady = ready }
            .store(in: &cancellables)

        settings.$pausedGroupIds
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paused in
                guard let self else { return }
                for idx in self.groups.indices {
                    self.groups[idx].isSharingPaused = paused.contains(self.groups[idx].id)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Refresh

    func refresh() async {
        // Catch up first, then re-read: a group we were added to while the app
        // was closed only appears once its Welcome has been processed, so
        // refreshing without this shows a stale list on the pull the user
        // expects to fix exactly that.
        try? await marmot.catchUpAccounts()
        await marmot.refreshGroups()
    }

    private func refreshItems(from groups: [WhistleGroup]) async {
        // Fetch member counts first — this is the only async work.
        var memberCounts: [String: Int] = [:]
        for group in groups {
            memberCounts[group.mlsGroupId] = (try? await marmot.members(ofGroup: group.mlsGroupId).count) ?? 0
        }
        // Read timestamps AFTER all awaits so any markAsRead calls that happened
        // during suspension are reflected — avoids showing already-read groups as unread.
        // Use lastChatTimestamps (chat-only) rather than group.lastMessageAt, which MDK
        // advances for every MLS event including location and nickname updates.
        let readTimestamps = lastReadTimestamps
        let chatTimestamps = lastChatTimestamps
        var items: [GroupListItem] = []
        for group in groups {
            let lastMessageEpoch = group.lastMessageAt.map { TimeInterval($0) }
            let lastChatEpoch = chatTimestamps[group.mlsGroupId]
            let lastRead = readTimestamps[group.mlsGroupId] ?? 0
            let hasUnread = lastChatEpoch.map { $0 > lastRead } ?? false
            items.append(GroupListItem(
                id: group.mlsGroupId,
                name: group.displayName,
                memberCount: memberCounts[group.mlsGroupId] ?? 0,
                lastActivity: lastMessageEpoch.map { Date(timeIntervalSince1970: $0) },
                isActive: group.isActive,
                hasUnread: hasUnread,
                isSharingPaused: settings.pausedGroupIds.contains(group.mlsGroupId)
            ))
        }
        self.groups = items
    }

    // MARK: - Actions

    func createGroup(name: String) async throws -> String {
        // No relay argument — MarmotKit publishes to the account's own relay
        // list, which it maintains itself.
        let groupId = try await marmot.createGroup(name: name)

        // Broadcast our display name so other members see it immediately
        let dn = displayName()
        if !dn.isEmpty {
            try? await marmot.sendNicknameUpdate(name: dn, toGroup: groupId)
        }

        return groupId
    }

    /// Leave a group directly — takes effect immediately, no admin action needed.
    func leaveGroup(id: String) async {
        do {
            try await marmot.leaveGroup(id)
        } catch {
            WhistleLogger.chat.error("Failed to leave group \(id): \(error)")
            // This path only logged, so a sole admin swiping to leave saw the
            // row animate closed and nothing else — the action looked like it
            // had worked. `GroupDetailView`'s leave was migrated to notices
            // and this one, the same operation by a different route, was not.
            notices.report(error, fallback: "Couldn't leave the group.")
        }
    }
}
