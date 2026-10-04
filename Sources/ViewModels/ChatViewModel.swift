import Foundation
import WhistleCore
import Combine

/// Drives the single-group chat thread — loads messages from MDK,
/// observes incoming message notifications, and sends new messages.
@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var messages: [ChatMessageItem] = []
    @Published var draftText: String = ""
    @Published private(set) var isSending = false
    /// Posted to `NoticeCenter` rather than held here. The old
    /// `@Published error` was never rendered by `GroupChatView`, so a failed
    /// send produced nothing on screen at all.
    private let notices: NoticeCenter
    @Published private(set) var memberNames: String = ""

    /// Soft-resync (catch-up) state for the decryption banner.
    @Published private(set) var isResyncing = false
    /// Set after a resync attempt that ran but did not clear the failures —
    /// signals the UI to point the user at the admin re-invite (hard) path.
    @Published private(set) var resyncDidNotResolve = false

    // MARK: - Item model

    struct ChatMessageItem: Identifiable, Equatable {
        let id: String              // message id from MDK
        let senderPubkeyHex: String
        let senderDisplayName: String
        let text: String
        let timestamp: Date
        let isMe: Bool
        /// MLS epoch, for ordering — see `inChatOrder`.
        var sourceEpoch: UInt64?
        /// A membership or rename event rather than something someone typed.
        ///
        /// Rendered as a centred line rather than a bubble: it has no sender
        /// in the conversational sense, and attributing "Member added" to the
        /// admin who did it made it look like a message they had written —
        /// which is exactly how it appeared before, raw JSON and all.
        var isSystemEvent: Bool = false
    }

    // MARK: - Dependencies

    let groupId: String
    private let marmot: MarmotKitService
    private let nicknameStore: NicknameStore
    private let myPubkeyHex: String
    private let messageCache: ChatMessageCache
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Pagination

    private let pageSize: UInt32 = 50
    /// The oldest RAW message loaded so far, used as the paging cursor.
    ///
    /// v1 paged by integer offset, which silently skips or repeats rows when
    /// messages arrive mid-session — the offsets shift underneath you.
    /// Protocol v2 pages by cursor instead, so this holds a message rather
    /// than a count. It is deliberately a *raw* message, not a displayed
    /// bubble: location updates dominate the store, and a cursor taken from
    /// the chat bubbles alone would skip every raw row between them.
    private var oldestLoaded: WhistleMessage?
    /// Safety cap on raw pages scanned in a single `loadMore` when a chat-sparse
    /// history is mostly location updates (1000 raw messages / tap).
    private let maxPagesPerLoadMore = 20
    @Published private(set) var hasMore = false
    @Published private(set) var isLoadingMore = false

    // MARK: - Init

    init(
        groupId: String,
        marmot: MarmotKitService,
        nicknameStore: NicknameStore,
        myPubkeyHex: String,
        messageCache: ChatMessageCache,
        notices: NoticeCenter
    ) {
        self.groupId = groupId
        self.notices = notices
        self.marmot = marmot
        self.nicknameStore = nicknameStore
        self.myPubkeyHex = myPubkeyHex
        self.messageCache = messageCache

        // Seed synchronously from the cache so re-entering a chat renders the
        // last-known thread immediately instead of flashing empty while MDK
        // reloads. `loadMessages()` (from `.task`) then merges in anything new.
        if let cached = messageCache.thread(for: groupId) {
            self.messages = cached.messages
            self.hasMore = cached.hasMore
            // No cursor is restored: it is a message, not an integer, and
            // `loadMessages()` from `.task` sets one from the page it fetches
            // before `loadMore()` can be reached (it returns early without a
            // cursor). Caching a stale cursor would be worse than having none.
        }

        // Refresh when a new chat message arrives for this group
        marmot.$lastChatMessageGroupId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updatedGroupId in
                guard let self, updatedGroupId == self.groupId else { return }
                Task { await self.loadMessages() }
            }
            .store(in: &cancellables)

        // Re-resolve display names when nicknames change
        nicknameStore.$nicknames
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshDisplayNames()
                Task { await self?.loadMemberNames() }
            }
            .store(in: &cancellables)

        // Refresh member names when membership changes (after commit events)
        marmot.$lastGroupMembershipChangeId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self, let (changeGroupId, _) = change, changeGroupId == self.groupId else { return }
                Task { await self.loadMemberNames() }
            }
            .store(in: &cancellables)
    }

    /// Re-map display names in-place without reloading from MDK.
    private func refreshDisplayNames() {
        messages = messages.map { msg in
            ChatMessageItem(
                id: msg.id,
                senderPubkeyHex: msg.senderPubkeyHex,
                senderDisplayName: nicknameStore.displayName(for: msg.senderPubkeyHex),
                text: msg.text,
                timestamp: msg.timestamp,
                isMe: msg.isMe
            )
        }
        persist()
    }

    // MARK: - Resync

    /// Soft resync triggered from the decryption banner: re-fetch and
    /// re-process this group's recent commits so a missed epoch advance can be
    /// applied. On success the health tracker clears the banner automatically;
    /// on failure we flag the UI to suggest the admin re-invite path.
    func resync() async {
        guard !isResyncing else { return }
        isResyncing = true
        resyncDidNotResolve = false
        // v1 re-fetched this one group's commits (`catchUpGroup`). v2 has no
        // per-group equivalent and does not need one — `catchUpAccounts`
        // drains everything outstanding, and MarmotKit reports an
        // unrecoverable group as a typed error rather than leaving the caller
        // to infer it from repeated failures.
        do {
            try await marmot.catchUpAccounts()
            await loadMessages()
        } catch {
            WhistleLogger.chat.error("Resync failed for group \(self.groupId): \(error)")
            resyncDidNotResolve = true
        }
        isResyncing = false
    }

    // MARK: - Load messages

    /// Load (or reload) the most recent page of messages.
    func loadMessages() async {
        do {
            let page = try await marmot.messages(inGroup: groupId, limit: pageSize)
            // The store returns newest-first; reverse so oldest is at the top
            // and newest at the bottom (natural chat order).
            let recent = Array(page.messages.compactMap { mapMessage($0) }.reversed())

            if messages.isEmpty {
                // Cold load: the recent page is the whole thread we know about.
                messages = recent
                oldestLoaded = page.messages.last
                hasMore = page.hasMoreBefore
            } else {
                // A thread is already showing (seeded from cache, or the user
                // paged back). Merge the recent page in — picking up new/edited
                // bubbles — without dropping older pages already loaded, and
                // leave `hasMore` (the "load earlier" affordance) untouched since
                // a newest-end refresh says nothing about the start of history.
                messages = merge(existing: messages, incoming: recent)
                // Only move the cursor backwards. A newest-end refresh returns
                // a page that stops short of history already paged in, so
                // adopting its tail unconditionally would rewind the cursor and
                // re-walk pages the user has already seen.
                if oldestLoaded == nil { oldestLoaded = page.messages.last }
            }
            persist()
        } catch {
            WhistleLogger.chat.error("Failed to load messages for group \(self.groupId): \(error)")
            notices.report(error, fallback: "Couldn't load messages.") { [weak self] in
                await self?.loadMessages()
            }
        }
    }

    /// Union two bubble lists by id (incoming wins, for fresh names/text) and
    /// sort into chat order (oldest first), tie-breaking on id for stability.
    private func merge(existing: [ChatMessageItem], incoming: [ChatMessageItem]) -> [ChatMessageItem] {
        var byId: [String: ChatMessageItem] = [:]
        for m in existing { byId[m.id] = m }
        for m in incoming { byId[m.id] = m }
        return byId.values.sorted(by: Self.inChatOrder)
    }

    /// Chat order: time, then epoch, then id.
    ///
    /// Epoch is the load-bearing part. `timestamp` has one-second resolution,
    /// so the three commits behind a single "promote someone and leave" action
    /// share it, and breaking the tie on `id` — a hash — ordered them
    /// arbitrarily. On device that produced "Member left / Admin removed /
    /// Admin added", the exact reverse of what happened. The MLS epoch
    /// increments per commit, so it restores the real sequence.
    ///
    /// Id remains the final tiebreaker so the sort stays total and stable:
    /// chat messages inside one epoch and one second are genuinely
    /// indistinguishable, and an unstable comparator would reshuffle them on
    /// every merge.
    static func inChatOrder(_ lhs: ChatMessageItem, _ rhs: ChatMessageItem) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if let left = lhs.sourceEpoch, let right = rhs.sourceEpoch, left != right {
            return left < right
        }
        return lhs.id < rhs.id
    }

    /// Write the current thread state back to the shared cache so the next
    /// visit to this group renders instantly.
    private func persist() {
        messageCache.store(
            groupId: groupId,
            messages: messages,
            hasMore: hasMore
        )
    }

    /// Load older messages and prepend them. Because location updates dominate
    /// the raw store, a single raw page can contain zero chat messages — so this
    /// keeps paging (walking the cursor back) until it gathers at least one new
    /// chat bubble or reaches the start of history, up to a bounded scan.
    func loadMore() async {
        guard hasMore, !isLoadingMore, let cursor = oldestLoaded else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        // Dupes are filtered inside the loop, not after it. Filtering after
        // would let a page of entirely already-shown messages satisfy the loop
        // and end the tap having added nothing — the user presses "load
        // earlier" and sees no change.
        var existing = Set(messages.map(\.id))
        var collected: [ChatMessageItem] = []
        var walkingCursor: WhistleMessage? = cursor
        var pages = 0
        while hasMore, collected.isEmpty, pages < maxPagesPerLoadMore, let before = walkingCursor {
            pages += 1
            do {
                let page = try await marmot.messages(
                    inGroup: groupId,
                    before: before,
                    limit: pageSize
                )
                hasMore = page.hasMoreBefore
                // An empty page with nothing older left means history is
                // exhausted — stop rather than spinning out the page budget.
                guard let tail = page.messages.last else { break }
                walkingCursor = tail
                oldestLoaded = tail
                // Older page → its bubbles belong above anything gathered so far.
                let mapped = Array(page.messages.compactMap { mapMessage($0) }.reversed())
                    .filter { existing.insert($0.id).inserted }
                collected.insert(contentsOf: mapped, at: 0)
            } catch {
                WhistleLogger.chat.error("Failed to load more messages: \(error)")
                // The user tapped "load earlier" — silence looks like there is
                // nothing older rather than like a failure.
                notices.report(error, fallback: "Couldn't load earlier messages.") { [weak self] in
                    await self?.loadMore()
                }
                return
            }
        }

        if !collected.isEmpty {
            messages.insert(contentsOf: collected, at: 0)
        }
        persist()
    }

    /// Load member names for display in the chat subtitle.
    func loadMemberNames() async {
        do {
          WhistleLogger.chat.info("Loading member names for group \(self.groupId)")
            let pubkeys = try await marmot.members(ofGroup: groupId)
            WhistleLogger.chat.info("Got \(pubkeys.count) pubkeys: \(pubkeys)")
            let names = pubkeys.map { nicknameStore.displayName(for: $0) }
            memberNames = names.joined(separator: ", ")
          WhistleLogger.chat.info("Member names: \(self.memberNames)")
        } catch {
            memberNames = ""
            WhistleLogger.chat.error("Failed to load member names for group \(self.groupId): \(error)")
        }
    }

    // MARK: - Send

    /// Send the current draft as a chat message.
    func sendMessage() async {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isSending = true
        defer { isSending = false }

        do {
            let payload = ChatPayload(text: text)
            let outcome = try await marmot.sendChat(payload, toGroup: groupId)
            draftText = ""

            // Reload to pick up the sent message from MDK storage
            await loadMessages()

            // A send that reached no relay still succeeds and still appears in
            // the timeline, so without this the message looks delivered when
            // nobody else has it — which is what happened in airplane mode.
            if outcome == .queued {
                notices.postToast("Saved, but not sent yet — no relay reachable.") { [weak self] in
                    await self?.resendQueued(text: text)
                }
            }
        } catch {
            WhistleLogger.chat.error("Failed to send message: \(error)")
            // The draft is deliberately left in place so Retry has something
            // to send, and so the text is not lost if the user ignores it.
            notices.report(error, fallback: "Message not sent.") { [weak self] in
                await self?.sendMessage()
            }
        }
    }

    /// Retry for a message that was stored but never published.
    ///
    /// Re-sends the same text rather than re-running `sendMessage`, whose
    /// draft has already been cleared. A duplicate is possible if the original
    /// drains from the queue at the same moment — preferred to the message
    /// silently never arriving, which is the failure this is here to fix.
    private func resendQueued(text: String) async {
        do {
            let outcome = try await marmot.sendChat(ChatPayload(text: text), toGroup: groupId)
            await loadMessages()
            if outcome == .queued {
                notices.postToast("Still no relay reachable.")
            }
        } catch {
            notices.report(error, fallback: "Message not sent.")
        }
    }

    // MARK: - Mapping

    /// Convert a decrypted message into a display-ready `ChatMessageItem`.
    private func mapMessage(_ message: WhistleMessage) -> ChatMessageItem? {
        let content = message.content

        // TEMPORARY diagnostic — remove once the membership-row rendering is
        // settled. Two attempts to fix "member added renders as a bubble on
        // arrival and centres only after re-entering the chat" have been based
        // on an assumed data shape; this prints the actual one.
        if message.isSystemEvent || content.contains("system_type") || content.contains("member_") {
            let kind = message.kind
            let flagged = message.isSystemEvent
            let sysText = message.systemText ?? "-"
            let epoch = message.sourceEpoch.map(String.init) ?? "-"
            let head = String(content.prefix(60))
            WhistleLogger.chat.error(
                "SYSROW kind=\(kind) isSystemEvent=\(flagged) systemText=\(sysText) epoch=\(epoch) content=\(head)"
            )
        }

        // Membership and rename events share this timeline, and are worth
        // showing — people should see who joined or left. They are rendered as
        // a system line using MarmotKit's own resolved display text
        // ("Member added"), never as a bubble: the raw plaintext is JSON, and
        // attributing it to whoever performed the action made it read as a
        // message they had typed.
        if message.isSystemEvent {
            guard let text = message.systemText, !text.isEmpty else { return nil }
            return ChatMessageItem(
                id: message.id,
                senderPubkeyHex: message.senderPubkey,
                senderDisplayName: nicknameStore.displayName(for: message.senderPubkey),
                text: text,
                timestamp: message.date,
                isMe: false,
                sourceEpoch: message.sourceEpoch,
                isSystemEvent: true
            )
        }

        // Kind is the authority on what a row is. `payloadType` reads a field
        // out of the plaintext, which is absent on anything we did not write
        // ourselves, so it cannot be relied on to exclude foreign kinds.
        if message.kind != MarmotKind.ProtocolV2.chat { return nil }

        // Only map "chat" type messages (skip nickname broadcasts, etc.).
        // A nil type is plain text from an older client — treat as chat.
        if let type = message.payloadType, type != "chat" {
            return nil
        }

        // Try parsing as ChatPayload for rich metadata, fall back to raw text
        let text: String
        let timestamp: Date
        if let payload = try? ChatPayload.from(jsonString: content) {
            text = payload.text
            timestamp = payload.date
        } else {
            text = content
            timestamp = message.date
        }

        return ChatMessageItem(
            id: message.id,
            senderPubkeyHex: message.senderPubkey,
            senderDisplayName: nicknameStore.displayName(for: message.senderPubkey),
            text: text,
            timestamp: timestamp,
            isMe: message.senderPubkey == myPubkeyHex,
            sourceEpoch: message.sourceEpoch
        )
    }
}
