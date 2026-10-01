import Foundation
import WhistleCore
import MarmotKit

/// Marmot protocol v2 group operations, backed by MarmotKit (MDK 0.10.x).
///
/// Step 3b of the MDK 2.0 / MarmotKit migration (see ROADMAP.md). This exists
/// **alongside** `MarmotService` rather than replacing it: the v1 service
/// carries fixes earned the hard way (the v1.11.1 burn bug, v1.11.2's
/// relay-delivery-order buffer, the leave/admin guards) and nothing is deleted
/// from it until step 3c's two-device comparison shows MarmotKit's own
/// convergence machinery actually covers the same ground. It is not wired into
/// the app; tests drive it.
///
/// Deliberately not expressed as a protocol shared with `MarmotService` yet.
/// With the v1 path untouched such a protocol would have a single conformer
/// and a shape guessed rather than observed, and step 3c compares the two
/// concrete implementations regardless. It gets extracted at the cutover,
/// when both sides are known to line up.
///
/// ## What changes versus the v1 stack
///
/// - **Transport is MarmotKit's.** It owns relay connections, publication
///   retry (`GroupSendQueueFull` when a group's outbound queue saturates) and
///   catch-up (`AccountCatchUp`). The app no longer builds kind-445 events,
///   runs its own subscription, or re-sorts a backlog by `created_at`.
/// - **Groups are "chats".** There is no single group read: identity and
///   activity come from `chatList`, admins and epoch from `groupDetails`.
/// - **Leave is durable.** `leaveGroup` registers an intent that survives
///   restarts and keeps re-proposing until a commit removes us, rather than
///   publishing-and-verifying synchronously. `leaveRequestPending` reports it.
/// - **Admin rules are typed.** `WouldRemoveLastAdmin` / `AdminCannotSelfRemove`
///   / `NotGroupAdmin` replace v1's parsing of MDK error *strings*.
@MainActor
final class MarmotKitService: ObservableObject {

    // MARK: - Published state

    /// Mirrors `MarmotService`'s published surface so the app layer can be
    /// swapped onto this service without ViewModels changing shape.
    @Published private(set) var groups: [WhistleGroup] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastChatMessageGroupId: String?
    @Published private(set) var lastJoinedGroupId: String?
    @Published private(set) var lastGroupMembershipChangeId: (String, Date)?

    // MARK: - Injected stores — deliberately absent until the cutover
    //
    // The v1 service takes LocationCache, NicknameStore, MemberAvatarStore,
    // SharedGroupAvatarStore and BatteryAlertService by injection, and this
    // service will need the same set. They cannot be declared yet: those
    // types live in the Whistle app module, and this file is compiled into
    // WhistleTests until step 3d moves it into the app target (see
    // project.yml). Referencing them here would not compile.
    //
    // No loss in practice — they are only consumed by the receive loop that
    // routes decrypted payloads into app state, which is itself part of
    // wiring the app. They arrive together at 3d.
    //
    // Two of v1's injection points will NOT come across: pendingInviteStore
    // and joinRequestStore. Protocol v2 has no out-of-group messaging, so
    // there is no join-request to collect and no pending-invite state to
    // track (ROADMAP.md step 4).

    // MARK: - Errors

    enum ServiceError: LocalizedError {
        case notStarted
        case lastAdminCannotLeave
        case notGroupAdmin
        case alreadyMember
        case memberNotInGroup
        case leaveAlreadyRequested
        /// The group is halted and only a re-admit by another member can
        /// revive it — MarmotKit's `GroupUnrecoverableRepairRequired`. The v1
        /// stack inferred this state from consecutive failures; here it is
        /// reported outright.
        case groupNeedsRepair
        case sendQueueFull
        case avatarTooLarge
        case reAddFailed(String)
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case .notStarted:
                return "Marmot is not started yet."
            case .lastAdminCannotLeave:
                return "You're the only admin of this group. Promote another member to admin before leaving."
            case .notGroupAdmin:
                return "Only an admin can do that."
            case .alreadyMember:
                return "This person is already a member of the group"
            case .memberNotInGroup:
                return "That person isn't a member of this group."
            case .leaveAlreadyRequested:
                return "You're already leaving this group — it will complete shortly."
            case .groupNeedsRepair:
                return "This group needs to be re-joined. Ask an admin to re-invite you."
            case .sendQueueFull:
                return "This group is stuck sending. Try again once it catches up."
            case .avatarTooLarge:
                return "That picture is too large to share. Try a different one."
            case .reAddFailed:
                return "Removed the member, but re-adding them failed. Tap Resync again to retry."
            case .underlying(let detail):
                return detail
            }
        }
    }

    /// Translate MarmotKit's typed errors into app-level ones.
    ///
    /// The point of doing this at all is that v1 had to pattern-match MDK's
    /// error *text* (`"last active admin"`, `"only admins can perform this
    /// operation"`) because 0.8 surfaced these as untyped strings. These are
    /// first-class cases now, so the matching is exhaustive instead of
    /// fragile.
    private static func mapError(_ error: Error) -> ServiceError {
        guard let kitError = error as? MarmotKitError else {
            return .underlying(error.localizedDescription)
        }
        switch kitError {
        case .WouldRemoveLastAdmin:
            return .lastAdminCannotLeave
        case .NotGroupAdmin, .NotAdmin:
            return .notGroupAdmin
        case .AlreadyAdmin:
            return .alreadyMember
        case .MemberNotInGroup:
            return .memberNotInGroup
        case .LeaveAlreadyRequested:
            return .leaveAlreadyRequested
        case .GroupUnrecoverableRepairRequired:
            return .groupNeedsRepair
        case .GroupSendQueueFull:
            return .sendQueueFull
        default:
            return .underlying(String(describing: kitError))
        }
    }

    private static func run<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw mapError(error)
        }
    }

    // MARK: - State

    private let marmot: Marmot
    private let relayUrls: [String]
    private var accountRef: String?

    /// Account reference for the started identity, for callers that need to
    /// pass it back into MarmotKit directly (tests, diagnostics).
    var currentAccountRef: String? { accountRef }

    // MARK: - Init

    /// - Parameters:
    ///   - rootPath: Directory MarmotKit owns its account database under. This
    ///     is a store of its own, entirely separate from v1's `whistle.db` —
    ///     v1 groups do not migrate, so the two never share state.
    ///   - relayUrls: Relays to dial.
    ///   - allowLoopback: Opt into loopback relay endpoints. Upstream gates
    ///     this behind an explicit development flag
    ///     (`RelayPolicyFfi.allowLoopback`); it is what lets a test point this
    ///     service at a relay it controls, since MarmotKit exposes no
    ///     injectable transport.
    ///   - secretStore: Where account signing keys live. `nil` uses
    ///     MarmotKit's default platform keyring, which is right for the app
    ///     but unavailable to an XCTest bundle — without the app's
    ///     entitlement the runtime fails with `KeystoreUnavailable` before it
    ///     reaches the network at all, which reads misleadingly like a
    ///     connectivity fault. Tests pass their own store.
    init(
        rootPath: String,
        relayUrls: [String],
        allowLoopback: Bool = false,
        secretStore: SecretStore? = nil
    ) throws {
        self.relayUrls = relayUrls
        let options = MarmotOptions(
            relayPolicy: allowLoopback ? .allowLoopbackRelaysAndBlobs : .publicOnly,
            secretStore: secretStore
        )
        self.marmot = try Marmot.newWithConfiguration(
            rootPath: rootPath,
            relayUrls: relayUrls,
            options: options
        )
    }

    // MARK: - Relay policy

    /// Hostnames MarmotKit "will never dial or adopt".
    ///
    /// The app's own default relay list is not automatically acceptable:
    /// MarmotKit enforces a relay safety policy at the dial boundary and
    /// refuses retired hosts outright, failing identity creation with a
    /// `Runtime` error rather than quietly skipping them. Verified on device —
    /// `wss://relay.damus.io` is retired, and it is the first entry in
    /// `AppDefaults.defaultRelays`.
    nonisolated func retiredRelayHosts() -> [String] {
        marmot.retiredRelayHosts()
    }

    /// Classify relay URLs with the same policy applied when dialling.
    nonisolated func classifyRelays(_ endpoints: [String]) -> [(endpoint: String, policy: String)] {
        marmot.classifyRelayEndpoints(endpoints: endpoints).map {
            ($0.endpoint, String(describing: $0.policy))
        }
    }

    /// The subset of `endpoints` MarmotKit is willing to dial.
    nonisolated func allowedRelays(from endpoints: [String]) -> [String] {
        marmot.classifyRelayEndpoints(endpoints: endpoints)
            .filter { $0.policy == .allowed }
            .map { $0.normalizedEndpoint ?? $0.endpoint }
    }

    // MARK: - Lifecycle

    /// Start the runtime and create a fresh identity, returning its account ref.
    ///
    /// `createIdentityWithProfile` is used rather than `createIdentity`: the
    /// latter only returns once relay lists and the first KeyPackage have been
    /// published, whereas this returns at local-ready and reports publication
    /// progress through `readiness`. That distinction matters for onboarding —
    /// "show my invite QR" has to gate on the KeyPackage actually being
    /// published, not merely on an identity existing.
    @discardableResult
    func startWithNewIdentity() async throws -> String {
        try await Self.run {
            try await marmot.start()
            let identity = try await marmot.createIdentityWithProfile(
                defaultRelays: relayUrls,
                bootstrapRelays: relayUrls
            )
            let ref = identity.account.accountIdHex
            accountRef = ref
            return ref
        }
    }

    private func requireAccount() throws -> String {
        guard let accountRef else { throw ServiceError.notStarted }
        return accountRef
    }

    /// Resume the account already stored under this service's root.
    ///
    /// The counterpart to `startWithNewIdentity` for a restart: the signing
    /// key lives in the secret store and the account in the database, so a
    /// relaunch signs back in rather than creating a second identity.
    @discardableResult
    func resumeExistingIdentity() async throws -> String {
        try await Self.run {
            try await marmot.start()
            guard let existing = try marmot.listAccounts().first else {
                throw ServiceError.notStarted
            }
            let summary = try await marmot.signInAccount(accountRef: existing.accountIdHex)
            accountRef = summary.accountIdHex
            return summary.accountIdHex
        }
    }

    /// Stop the runtime.
    ///
    /// Root ownership outlives this call — upstream notes it is held "until
    /// the final `Marmot`/runtime handle is dropped, even after
    /// `Marmot::shutdown`" — so constructing another service on the same root
    /// requires releasing this object first, or the new one fails with
    /// `RuntimeBusy`.
    func shutdown() async {
        await marmot.shutdown()
    }

    /// Ask the runtime to catch up on anything it missed while not running.
    ///
    /// MarmotKit's own equivalent of v1's `catchUpGroup`, which re-fetches 30
    /// days of kind-445 events by hand. Whether this covers the same ground
    /// is what step 3c has to establish before that code is deleted.
    func catchUpAccounts() async throws {
        try await Self.run {
            try await marmot.catchUpAccounts()
        }
    }

    /// Publish a fresh KeyPackage and return its published-at timestamp.
    ///
    /// `createIdentityWithProfile` returns at local-ready, before publication
    /// completes, so an account can exist while nothing discoverable about it
    /// has reached a relay yet. Anyone inviting this account needs its
    /// KeyPackage to be fetchable first — which is also why onboarding has to
    /// gate "show my invite QR" on publication rather than on identity
    /// creation (ROADMAP.md step 4).
    @discardableResult
    func publishKeyPackage() async throws -> UInt64 {
        let account = try requireAccount()
        return try await Self.run {
            try await marmot.publishNewKeyPackage(accountRef: account)
        }
    }

    // MARK: - Groups

    /// All groups, newest activity first.
    ///
    /// Costs one `chatList` plus a `groupDetails` per group: a chat row carries
    /// identity and activity but neither the admin list nor the epoch. Fine at
    /// this app's scale (a handful of groups), and avoidable later — the only
    /// caller that needs admins off the cached list is `promoteToAdmin`, and
    /// reading those live would be more correct anyway, since v1's own notes
    /// record the cached admin list diverging from live MLS state.
    func groups() async throws -> [WhistleGroup] {
        let account = try requireAccount()
        return try await Self.run {
            let rows = try marmot.chatList(accountRef: account, includeArchived: false)
            var result: [WhistleGroup] = []
            for row in rows {
                let details = try? await marmot.groupDetails(
                    accountRef: account,
                    groupIdHex: row.groupIdHex
                )
                result.append(Self.map(row: row, details: details))
            }
            return result
        }
    }

    func group(id groupIdHex: String) async throws -> WhistleGroup? {
        let account = try requireAccount()
        return try await Self.run {
            guard let row = try marmot.chatListRow(accountRef: account, groupIdHex: groupIdHex) else {
                return nil
            }
            let details = try? await marmot.groupDetails(accountRef: account, groupIdHex: groupIdHex)
            return Self.map(row: row, details: details)
        }
    }

    func members(ofGroup groupIdHex: String) async throws -> [String] {
        let account = try requireAccount()
        return try await Self.run {
            try await marmot.groupMembers(accountRef: account, groupIdHex: groupIdHex)
                .map(\.memberIdHex)
        }
    }

    /// Whether a leave is already in flight — MarmotKit keeps re-proposing a
    /// durable leave until a commit removes us, so a second attempt is
    /// progress to surface rather than an error to retry.
    func isLeavePending(groupIdHex: String) async throws -> Bool {
        let account = try requireAccount()
        return try await Self.run {
            try marmot.chatListRow(accountRef: account, groupIdHex: groupIdHex)?
                .leaveRequestPending ?? false
        }
    }

    @discardableResult
    func createGroup(name: String, description: String? = nil, memberRefs: [String] = []) async throws -> String {
        let account = try requireAccount()
        return try await Self.run {
            try await marmot.createGroup(
                accountRef: account,
                name: name,
                memberRefs: memberRefs,
                description: description
            )
        }
    }

    // MARK: - Membership & admin

    /// Add members directly by account reference.
    ///
    /// There is no v1-style join-request round trip here: MarmotKit has no
    /// outside-group messaging, so an admin invites a known npub rather than
    /// receiving a gift-wrapped request carrying a KeyPackage. That is the
    /// product change step 4 covers (reversed invite QR).
    func invite(memberRefs: [String], toGroup groupIdHex: String) async throws {
        let account = try requireAccount()
        _ = try await Self.run {
            try await marmot.inviteMembers(
                accountRef: account,
                groupIdHex: groupIdHex,
                memberRefs: memberRefs
            )
        }
    }

    func removeMembers(_ memberRefs: [String], fromGroup groupIdHex: String) async throws {
        let account = try requireAccount()
        _ = try await Self.run {
            try await marmot.removeMembers(
                accountRef: account,
                groupIdHex: groupIdHex,
                memberRefs: memberRefs
            )
        }
    }

    func promoteToAdmin(_ memberRef: String, inGroup groupIdHex: String) async throws {
        let account = try requireAccount()
        _ = try await Self.run {
            try await marmot.promoteAdmin(
                accountRef: account,
                groupIdHex: groupIdHex,
                memberRef: memberRef
            )
        }
    }

    /// Leave a group.
    ///
    /// Self-demote first when we hold admin: MarmotKit refuses a bare leave
    /// from an admin (`AdminCannotSelfRemove`), and refuses the demote itself
    /// when we are the only admin (`WouldRemoveLastAdmin`) — which surfaces as
    /// `.lastAdminCannotLeave` so the caller can tell the user to promote
    /// someone first. v1 reached the same outcome by parsing error strings.
    func leaveGroup(_ groupIdHex: String) async throws {
        let account = try requireAccount()
        do {
            _ = try await marmot.selfDemoteAdmin(accountRef: account, groupIdHex: groupIdHex)
        } catch let error as MarmotKitError {
            switch error {
            case .WouldRemoveLastAdmin:
                throw ServiceError.lastAdminCannotLeave
            case .NotGroupAdmin, .NotAdmin:
                break  // not an admin — nothing to demote, fall through to leave
            default:
                throw Self.mapError(error)
            }
        }
        _ = try await Self.run {
            try await marmot.leaveGroup(accountRef: account, groupIdHex: groupIdHex)
        }
    }

    func rename(group groupIdHex: String, to name: String) async throws {
        let account = try requireAccount()
        _ = try await Self.run {
            try await marmot.updateGroupProfile(
                accountRef: account,
                groupIdHex: groupIdHex,
                name: name,
                description: nil
            )
        }
    }

    // MARK: - Send

    /// Send an app payload as a custom event.
    ///
    /// `kind` must be outside MDK's reserved set — use `MarmotKind.ProtocolV2`, which
    /// exists precisely because v1's `chat = 9` collides with MDK's own CHAT
    /// and would be rejected here.
    func send(content: String, kind: UInt16, toGroup groupIdHex: String) async throws {
        let account = try requireAccount()
        _ = try await Self.run {
            try await marmot.sendCustomEvent(
                accountRef: account,
                groupIdHex: groupIdHex,
                kind: UInt64(kind),
                tags: [],
                content: content
            )
        }
    }

    func sendLocation(_ payload: LocationPayload, toGroup groupIdHex: String) async throws {
        try await send(
            content: try payload.jsonString(),
            kind: MarmotKind.ProtocolV2.location,
            toGroup: groupIdHex
        )
    }

    func sendChat(_ payload: ChatPayload, toGroup groupIdHex: String) async throws {
        try await send(
            content: try payload.jsonString(),
            kind: MarmotKind.ProtocolV2.chat,
            toGroup: groupIdHex
        )
    }

    // MARK: - Receive

    /// Subscribe to a group's custom events, or to every group when
    /// `groupIdHex` is nil.
    ///
    /// Replaces v1's single relay-wide kind-445 filter plus the EOSE catch-up
    /// buffer: MarmotKit owns the subscription and hands over decrypted
    /// messages. `kinds` filters server-side rather than after decryption.
    func subscribe(
        toGroup groupIdHex: String? = nil,
        kinds: [UInt16] = [MarmotKind.ProtocolV2.location, MarmotKind.ProtocolV2.chat, MarmotKind.ProtocolV2.leaveRequest]
    ) async throws -> MessageStream {
        let account = try requireAccount()
        let subscription = try await Self.run {
            try await marmot.subscribeMessages(
                accountRef: account,
                groupIdHex: groupIdHex,
                limit: nil,
                kinds: kinds.map(UInt64.init)
            )
        }
        return MessageStream(subscription: subscription)
    }

    /// Pull-based stream of decrypted app messages, mapped to owned types.
    struct MessageStream {
        private let subscription: MessagesSubscription

        init(subscription: MessagesSubscription) {
            self.subscription = subscription
        }

        /// Next message, or `nil` once the subscription ends. Agent-stream
        /// starts are skipped — Whistle sends no agent payloads, and surfacing
        /// them would make every caller handle a case it has no meaning for.
        func next() async -> WhistleMessage? {
            while let update = await subscription.next() {
                guard case .message(let received) = update else { continue }
                return MarmotKitService.map(received: received.message)
            }
            return nil
        }
    }

    // MARK: - Group queries (parity with the v1 service)

    /// Refresh the published `groups` list.
    func refreshGroups() async {
        do {
            groups = try await groups()
        } catch {
            // No WhistleLogger here: it lives in the app module and this file
            // is compiled into WhistleTests until the cutover. `lastError` is
            // the observable signal either way; logging joins at 3d.
            lastError = error.localizedDescription
        }
    }

    /// Is this pubkey an admin of the group, per live MLS state?
    func isAdmin(_ pubkeyHex: String, ofGroup groupIdHex: String) async -> Bool {
        (try? await group(id: groupIdHex))?.isAdmin(pubkeyHex) ?? false
    }

    /// The admin responsible for re-announcing group state to new joiners.
    ///
    /// Lexicographically smallest admin pubkey, as in v1: every admin sees a
    /// join, so without a rule a three-admin group would send three copies of
    /// the group photo, and "first in the array" resolves differently per
    /// device.
    func designatedBroadcaster(forGroup groupIdHex: String) async -> String? {
        (try? await group(id: groupIdHex))?.adminPubkeys.min()
    }

    /// Relays MarmotKit is actually willing to dial from the configured set.
    var activeRelayURLs: [String] {
        allowedRelays(from: relayUrls)
    }

    // MARK: - Message history

    /// One page of history, newest-first, ending before `beforeMessageId`.
    ///
    /// Cursor-based, unlike v1's offset paging — which makes v1's careful
    /// raw-row-count bookkeeping unnecessary rather than merely different.
    /// Offsets drift when new messages land mid-scroll, so v1 had to advance
    /// by the raw store count and infer "more" from `count == pageSize`;
    /// MarmotKit reports `hasMoreBefore` outright and a cursor cannot drift.
    /// - Parameter before: the oldest message already held, or `nil` for the
    ///   newest page. Takes a whole message rather than an id because the
    ///   cursor is compound: the backend rejects a bare id with "timeline
    ///   pagination requires before and before_message_id together", since
    ///   `timelineAt` has one-second resolution and needs the id to break
    ///   ties. Passing the message keeps that detail out of callers.
    func messages(
        inGroup groupIdHex: String,
        before: WhistleMessage? = nil,
        limit: UInt32 = 50
    ) async throws -> (messages: [WhistleMessage], hasMoreBefore: Bool) {
        let account = try requireAccount()
        return try await Self.run {
            let page = try marmot.timelineMessages(
                accountRef: account,
                query: TimelineMessageQueryFfi(
                    groupIdHex: groupIdHex,
                    search: nil,
                    before: before?.createdAt,
                    beforeMessageId: before?.id,
                    after: nil,
                    afterMessageId: nil,
                    limit: limit
                )
            )
            // The backend treats `before` as *inclusive* and returns the
            // cursor row again, so consecutive pages overlap by one. Dropped
            // here rather than left to callers: v1's ChatViewModel dedupes by
            // id and would have hidden the duplicate instead of surfacing it,
            // and anything that trusted the page contents would double-render
            // one message per page.
            let mapped = page.messages
                .map { Self.map(timeline: $0) }
                .filter { $0.id != before?.id }
            return (mapped, page.hasMoreBefore)
        }
    }

    // MARK: - Chat sub-type senders

    /// Nickname, member avatar and group avatar all ride the chat kind with a
    /// `type` discriminator, exactly as in v1 — the wire shape of these
    /// payloads is unchanged by the migration, only the transport is.
    func sendNicknameUpdate(name: String, toGroup groupIdHex: String) async throws {
        try await send(
            content: try NicknamePayload(name: name).jsonString(),
            kind: MarmotKind.ProtocolV2.chat,
            toGroup: groupIdHex
        )
    }

    func sendAvatarUpdate(_ payload: AvatarPayload, toGroup groupIdHex: String) async throws {
        guard payload.isWithinSizeLimit else { throw ServiceError.avatarTooLarge }
        try await send(
            content: try payload.jsonString(),
            kind: MarmotKind.ProtocolV2.chat,
            toGroup: groupIdHex
        )
    }

    func sendGroupAvatarUpdate(_ payload: GroupAvatarPayload, toGroup groupIdHex: String) async throws {
        guard payload.isWithinSizeLimit else { throw ServiceError.avatarTooLarge }
        try await send(
            content: try payload.jsonString(),
            kind: MarmotKind.ProtocolV2.chat,
            toGroup: groupIdHex
        )
    }

    // MARK: - Fork repair

    /// Remove a member and immediately re-invite them.
    ///
    /// Ported forward deliberately. Step 3c showed MarmotKit resolving a
    /// two-admin concurrent-commit fork on its own, but upstream still
    /// documents `GroupUnrecoverableRepairRequired` as a group "halted until
    /// another member re-admits this device" — a state that only exists if
    /// some divergence is unrecoverable, and this is the only cure for it.
    ///
    /// Ordering matches v1: nothing is removed until the re-invite is possible,
    /// and a failure after removal is reported distinctly so the caller can
    /// retry rather than silently stranding the member.
    func resyncMember(_ memberRef: String, inGroup groupIdHex: String) async throws {
        let members = try await members(ofGroup: groupIdHex)
        if members.contains(memberRef) {
            try await removeMembers([memberRef], fromGroup: groupIdHex)
        }
        do {
            try await invite(memberRefs: [memberRef], toGroup: groupIdHex)
        } catch {
            throw ServiceError.reAddFailed(memberRef)
        }
        lastGroupMembershipChangeId = (groupIdHex, Date())
    }

    // MARK: - Mapping

    nonisolated private static func map(row: ChatListRowFfi, details: GroupDetailsFfi?) -> WhistleGroup {
        WhistleGroup(
            mlsGroupId: row.groupIdHex,
            name: row.groupName,
            // A group we have left, been removed from, or that was disbanded
            // is not active. `.unrecoverable` deliberately still counts as
            // active: it needs a re-admit to work again, but hiding it would
            // leave the user unable to see the group they have to act on.
            isActive: row.selfMembership == .member && row.lifecycleState != .disbanded,
            epoch: details?.mlsState.epoch ?? 0,
            adminPubkeys: details?.group.admins ?? [],
            // 0 means "no activity recorded", which v1 represents as nil.
            lastMessageAt: row.activitySortAt == 0 ? nil : row.activitySortAt
        )
    }

    nonisolated private static func map(timeline record: TimelineMessageRecordFfi) -> WhistleMessage {
        WhistleMessage(
            id: record.messageIdHex,
            mlsGroupId: record.groupIdHex,
            senderPubkey: record.sender,
            kind: UInt16(truncatingIfNeeded: record.kind),
            content: record.plaintext,
            createdAt: record.timelineAt
        )
    }

    nonisolated private static func map(received: ReceivedMessageFfi) -> WhistleMessage {
        WhistleMessage(
            id: received.messageIdHex,
            mlsGroupId: received.groupIdHex,
            senderPubkey: received.sender,
            kind: UInt16(truncatingIfNeeded: received.kind),
            content: received.plaintext,
            createdAt: received.sourceEpoch
        )
    }
}
