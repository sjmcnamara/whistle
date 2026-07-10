import Foundation
import WhistleCore
import Combine
import MDKBindings

/// Drives the single-group chat thread — loads messages from MDK,
/// observes incoming message notifications, and sends new messages.
@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var messages: [ChatMessageItem] = []
    @Published var draftText: String = ""
    @Published private(set) var isSending = false
    @Published private(set) var error: String?
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
    }

    // MARK: - Dependencies

    let groupId: String
    private let marmot: MarmotService
    private let mls: MLSService
    private let nicknameStore: NicknameStore
    private let myPubkeyHex: String
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Pagination

    private let pageSize: UInt32 = 50
    /// Offset into the RAW message store (all inner kinds — chat, location,
    /// nickname), NOT the count of displayed chat bubbles. Location updates
    /// dominate the store, so tracking this in displayed-chat units would make
    /// paging overlap itself and stall.
    private var currentOffset: UInt32 = 0
    /// Safety cap on raw pages scanned in a single `loadMore` when a chat-sparse
    /// history is mostly location updates (1000 raw messages / tap).
    private let maxPagesPerLoadMore = 20
    @Published private(set) var hasMore = false
    @Published private(set) var isLoadingMore = false

    // MARK: - Init

    init(
        groupId: String,
        marmot: MarmotService,
        mls: MLSService,
        nicknameStore: NicknameStore,
        myPubkeyHex: String
    ) {
        self.groupId = groupId
        self.marmot = marmot
        self.mls = mls
        self.nicknameStore = nicknameStore
        self.myPubkeyHex = myPubkeyHex

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
        let recovered = await marmot.catchUpGroup(groupId: groupId)
        if recovered {
            await loadMessages()
        } else {
            resyncDidNotResolve = true
        }
        isResyncing = false
    }

    // MARK: - Load messages

    /// Load (or reload) the most recent page of messages.
    func loadMessages() async {
        do {
            let mdkMessages = try await mls.getMessages(
                groupId: groupId,
                limit: pageSize,
                offset: nil,
                sortOrder: MLSSortOrder.createdAtFirst
            )
            // MDK returns newest-first; reverse so oldest is at the top
            // and newest at the bottom (natural chat order).
            messages = mdkMessages.compactMap { mapMessage($0) }.reversed()
            // Advance by the RAW page size consumed, not the mapped chat count —
            // the offset indexes the raw store (see `currentOffset`).
            currentOffset = UInt32(mdkMessages.count)
            hasMore = mdkMessages.count == Int(pageSize)
            error = nil
        } catch {
            self.error = error.localizedDescription
            WhistleLogger.chat.error("Failed to load messages for group \(self.groupId): \(error)")
        }
    }

    /// Load older messages and prepend them. Because location updates dominate
    /// the raw store, a single raw page can contain zero chat messages — so this
    /// keeps paging (advancing the raw offset) until it gathers at least one chat
    /// bubble or reaches the start of history, up to a bounded scan.
    func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        var collected: [ChatMessageItem] = []
        var pages = 0
        while hasMore, collected.isEmpty, pages < maxPagesPerLoadMore {
            pages += 1
            do {
                let mdkMessages = try await mls.getMessages(
                    groupId: groupId,
                    limit: pageSize,
                    offset: currentOffset,
                    sortOrder: MLSSortOrder.createdAtFirst
                )
                // Advance by the RAW count so successive pages don't overlap.
                currentOffset += UInt32(mdkMessages.count)
                hasMore = mdkMessages.count == Int(pageSize)
                // Older page → its bubbles belong above anything gathered so far.
                let mapped = Array(mdkMessages.compactMap { mapMessage($0) }.reversed())
                collected.insert(contentsOf: mapped, at: 0)
            } catch {
                WhistleLogger.chat.error("Failed to load more messages: \(error)")
                return
            }
        }

        // Dedupe against what's already shown (guards any overlap) and prepend.
        let existing = Set(messages.map(\.id))
        let fresh = collected.filter { !existing.contains($0.id) }
        if !fresh.isEmpty {
            messages.insert(contentsOf: fresh, at: 0)
        }
    }

    /// Load member names for display in the chat subtitle.
    func loadMemberNames() async {
        do {
          WhistleLogger.chat.info("Loading member names for group \(self.groupId)")
            let pubkeys = try await mls.getMembers(groupId: groupId)
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
            let json = try payload.jsonString()
            try await marmot.sendMessage(content: json, toGroup: groupId, kind: MarmotKind.chat)
            draftText = ""

            // Reload to pick up the sent message from MDK storage
            await loadMessages()
        } catch {
            self.error = error.localizedDescription
            WhistleLogger.chat.error("Failed to send message: \(error)")
        }
    }

    // MARK: - Mapping

    /// Convert an MDK `Message` into a display-ready `ChatMessageItem`.
    private func mapMessage(_ message: Message) -> ChatMessageItem? {
        guard let content = message.plaintextContent else { return nil }

        // Only map "chat" type messages (skip nickname broadcasts, etc.)
        if let data = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = json["type"] as? String, type != "chat" {
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
            timestamp = Date(timeIntervalSince1970: TimeInterval(message.createdAt))
        }

        return ChatMessageItem(
            id: message.id,
            senderPubkeyHex: message.senderPubkey,
            senderDisplayName: nicknameStore.displayName(for: message.senderPubkey),
            text: text,
            timestamp: timestamp,
            isMe: message.senderPubkey == myPubkeyHex
        )
    }
}
