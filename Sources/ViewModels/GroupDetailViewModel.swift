import Foundation
import WhistleCore
import Combine
import NostrSDK

/// Drives the group detail / management view — member list, invite, remove.
@MainActor
final class GroupDetailViewModel: ObservableObject {

    // MARK: - Published state

    @Published var groupName: String = ""
    @Published private(set) var members: [MemberItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isAddingMember = false
    @Published private(set) var didAddMember = false
    @Published private(set) var error: String?
    @Published var addMemberNpub: String = ""

    // Leave / rename state
    @Published var isLeaving = false
    @Published var didLeave = false
    @Published var isRenaming = false

    /// Pubkey currently being hard-resynced (remove + re-add), for per-row spinner.
    @Published private(set) var resyncingMemberPubkey: String?

    // MARK: - Item model

    struct MemberItem: Identifiable, Equatable {
        let id: String           // pubkeyHex
        let pubkeyHex: String
        let displayName: String
        let isAdmin: Bool
        let isMe: Bool
    }

    // MARK: - Dependencies

    let groupId: String
    private let marmot: MarmotKitService
    private let nicknameStore: NicknameStore
    private let myPubkeyHex: String
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(
        groupId: String,
        marmot: MarmotKitService,
        nicknameStore: NicknameStore,
        myPubkeyHex: String
    ) {
        self.groupId = groupId
        self.marmot = marmot
        self.nicknameStore = nicknameStore
        self.myPubkeyHex = myPubkeyHex

        // Re-resolve display names when nicknames change
        nicknameStore.$nicknames
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshDisplayNames()
            }
            .store(in: &cancellables)

    }

    // MARK: - Load

    /// Fetch group metadata and member list from MDK.
    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            // Load group metadata, members and admin list. One group read
            // serves both the name and the admin list. No separate metadata
            // sync step: v1 cached group state itself and could drift from
            // what MLS enforced, so it had to reconcile first — MarmotKit
            // reads this straight from live group state.
            let group = try await marmot.group(id: groupId)
            if let group {
                groupName = group.displayName
            }
            let memberPubkeys = try await marmot.members(ofGroup: groupId)
            let adminPubkeys = Set(group?.adminPubkeys ?? [])

            members = memberPubkeys.map { pubkey in
                MemberItem(
                    id: pubkey,
                    pubkeyHex: pubkey,
                    displayName: nicknameStore.displayName(for: pubkey),
                    isAdmin: adminPubkeys.contains(pubkey),
                    isMe: pubkey == myPubkeyHex
                )
            }.sorted { lhs, rhs in
                // Sort: me first, then admins, then alphabetical
                if lhs.isMe != rhs.isMe { return lhs.isMe }
                if lhs.isAdmin != rhs.isAdmin { return lhs.isAdmin }
                return lhs.displayName < rhs.displayName
            }

            error = nil
        } catch {
            self.error = error.localizedDescription
            WhistleLogger.chat.error("Failed to load group detail for \(self.groupId): \(error)")
        }
    }

    // MARK: - Invite
    //
    // There is no invite *code* under protocol v2. A code only works if the
    // person holding it can act on it, and a non-member has no out-of-group
    // message to send. Adding someone is admin-side and in-group now: they
    // show their member code (`MemberCodeView`) and an admin scans it
    // (`ScanMemberCodeView`).

    // MARK: - Add member

    /// Add a member to the group by their npub or hex pubkey.
    ///
    /// The invitee must have already published a key package (via acceptInvite).
    /// This fetches their key package from relays and performs the MLS add.
    func addMember() async {
        let input = addMemberNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        isAddingMember = true
        defer { isAddingMember = false }

        do {
            // Resolve npub → hex if needed
            let pubkeyHex: String
            if input.hasPrefix("npub") {
                let pk = try NostrSDK.PublicKey.parse(publicKey: input)
                pubkeyHex = pk.toHex()
            } else {
                pubkeyHex = input
            }

            try await marmot.invite(memberRefs: [pubkeyHex], toGroup: groupId)
            addMemberNpub = ""
            error = nil

            // Reload member list
            await load()
            WhistleLogger.chat.info("Added member \(pubkeyHex.prefix(8)) to group \(self.groupId)")

            // Signal the view to dismiss back to the chat
            didAddMember = true
        } catch {
            self.error = error.localizedDescription
            WhistleLogger.chat.error("Failed to add member: \(error)")
        }
    }

    // MARK: - Remove member

    /// Remove a member from the group. Only admins can do this.
    func removeMember(pubkeyHex: String) async {
        do {
            try await marmot.removeMembers([pubkeyHex], fromGroup: groupId)

            // Reload member list
            await load()
            WhistleLogger.chat.info("Removed member \(pubkeyHex.prefix(8)) from group \(self.groupId)")
        } catch {
            self.error = error.localizedDescription
            WhistleLogger.chat.error("Failed to remove member: \(error)")
        }
    }

    func promoteToAdmin(pubkeyHex: String) async {
        do {
            try await marmot.promoteToAdmin(pubkeyHex, inGroup: groupId)
            await load()
            WhistleLogger.chat.info("Promoted \(pubkeyHex.prefix(8)) to admin in group \(self.groupId)")
        } catch {
            self.error = error.localizedDescription
            WhistleLogger.chat.error("Failed to promote member: \(error)")
        }
    }

    /// Hard resync a member: remove + re-add to rebuild their ratchet-tree leaf,
    /// curing a fork that soft catch-up cannot. Admin-only. On failure (including
    /// a re-add that failed after removal), surfaces the error so the UI can
    /// prompt a retry — tapping Resync again re-adds the now-removed member.
    func resyncMember(pubkeyHex: String) async {
        guard resyncingMemberPubkey == nil else { return }
        resyncingMemberPubkey = pubkeyHex
        defer { resyncingMemberPubkey = nil }
        do {
            try await marmot.resyncMember(pubkeyHex, inGroup: groupId)
            await load()
            WhistleLogger.chat.info("Hard-resynced \(pubkeyHex.prefix(8)) in group \(self.groupId)")
        } catch {
            self.error = error.localizedDescription
            WhistleLogger.chat.error("Failed to resync member: \(error)")
        }
    }

    /// Display identifier for a pubkey with no group membership yet (e.g. a
    /// pending joiner) — a nickname if one is already known, otherwise an
    /// abbreviated npub the admin can match against what the joiner reads off
    /// their own Identity card, rather than meaningless raw hex.
    func displayIdentifier(for pubkeyHex: String) -> String {
        nicknameStore.displayName(for: pubkeyHex)
    }

    /// The same 8-char group-id prefix diagnostics exports use — lets you
    /// match a group in the diagnostics report (which deliberately shows no
    /// name, only this id) back to an actual group when you're in more than one.
    var diagnosticsGroupId: String {
        DiagnosticsReport.shortHex(groupId)
    }

    /// Full npub for a member — lets you verify a *named* member's identity
    /// out-of-band by comparing it against what they read off their own
    /// Identity card. Unlike a nickname-less fallback (which already shows an
    /// abbreviated npub in place of a name), a member with a cached nickname
    /// otherwise has no way to reveal the pubkey backing that name.
    func fullNpub(for pubkeyHex: String) -> String {
        (try? PublicKey.parse(publicKey: pubkeyHex).toBech32()) ?? pubkeyHex
    }

    /// Whether the current user is an admin of this group.
    var isAdmin: Bool {
        members.first(where: \.isMe)?.isAdmin ?? false
    }

    // MARK: - Leave group

    /// Leave the group directly — a self-remove MLS commit, takes effect immediately.
    func leaveGroup() async {
        isLeaving = true
        defer { isLeaving = false }
        do {
            try await marmot.leaveGroup(groupId)
            didLeave = true
            error = nil
        } catch {
            self.error = error.localizedDescription
            WhistleLogger.chat.error("Failed to leave group: \(error)")
        }
    }

    // MARK: - Rename group

    /// Rename the group (admin only). Updates MLS metadata and publishes.
    func renameGroup(to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != groupName else { return }
        isRenaming = true
        defer { isRenaming = false }
        do {
            try await marmot.rename(group: groupId, to: trimmed)
            groupName = trimmed
            error = nil
        } catch {
            self.error = error.localizedDescription
            WhistleLogger.chat.error("Failed to rename group: \(error)")
        }
    }

    // MARK: - Nickname refresh

    /// Re-resolve display names in-place when NicknameStore changes.
    private func refreshDisplayNames() {
        members = members.map { m in
            MemberItem(
                id: m.id,
                pubkeyHex: m.pubkeyHex,
                displayName: nicknameStore.displayName(for: m.pubkeyHex),
                isAdmin: m.isAdmin,
                isMe: m.isMe
            )
        }
    }
}
