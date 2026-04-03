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
    private var currentOffset: UInt32 = 0
    @Published private(set) var hasMore = false

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
            currentOffset = UInt32(messages.count)
            hasMore = mdkMessages.count == Int(pageSize)
            error = nil
        } catch {
            self.error = error.localizedDescription
            FMFLogger.chat.error("Failed to load messages for group \(self.groupId): \(error)")
        }
    }

    /// Load the next page of older messages (prepend to list).
    func loadMore() async {
        guard hasMore else { return }
        do {
            let mdkMessages = try await mls.getMessages(
                groupId: groupId,
                limit: pageSize,
                offset: currentOffset,
                sortOrder: MLSSortOrder.createdAtFirst
            )
            // MDK returns newest-first; reverse for chronological order
            let newItems = Array(mdkMessages.compactMap { mapMessage($0) }.reversed())
            // Prepend older messages at the top
            messages.insert(contentsOf: newItems, at: 0)
            currentOffset += UInt32(newItems.count)
            hasMore = mdkMessages.count == Int(pageSize)
        } catch {
            FMFLogger.chat.error("Failed to load more messages: \(error)")
        }
    }

    /// Load member names for display in the chat subtitle.
    func loadMemberNames() async {
        do {
          FMFLogger.chat.info("Loading member names for group \(self.groupId)")
            let pubkeys = try await mls.getMembers(groupId: groupId)
            FMFLogger.chat.info("Got \(pubkeys.count) pubkeys: \(pubkeys)")
            let names = pubkeys.map { nicknameStore.displayName(for: $0) }
            memberNames = names.joined(separator: ", ")
          FMFLogger.chat.info("Member names: \(self.memberNames)")
        } catch {
            memberNames = ""
            FMFLogger.chat.error("Failed to load member names for group \(self.groupId): \(error)")
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
            FMFLogger.chat.error("Failed to send message: \(error)")
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
