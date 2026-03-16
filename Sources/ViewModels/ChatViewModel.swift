import Foundation
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
    private var cancellable: AnyCancellable?

    // MARK: - Pagination

    private let pageSize: UInt32 = 50
    private var currentOffset: UInt32 = 0
    private(set) var hasMore = true

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
        cancellable = marmot.$lastChatMessageGroupId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updatedGroupId in
                guard let self, updatedGroupId == self.groupId else { return }
                Task { await self.loadMessages() }
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
            messages = mdkMessages.compactMap { mapMessage($0) }
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
            let newItems = mdkMessages.compactMap { mapMessage($0) }
            // Prepend older messages — they come in chronological order
            messages.insert(contentsOf: newItems, at: 0)
            currentOffset += UInt32(newItems.count)
            hasMore = mdkMessages.count == Int(pageSize)
        } catch {
            FMFLogger.chat.error("Failed to load more messages: \(error)")
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
