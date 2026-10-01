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
final class MarmotKitService {

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
