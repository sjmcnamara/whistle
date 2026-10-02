import Foundation

/// A decrypted application message as the app layer sees it, with no MLS or
/// MDK types in sight. Companion to `WhistleGroup` — see that type for why
/// this lives in `WhistleCore`.
///
/// `content` is the already-extracted inner plaintext. `MDKBindings.Message`
/// instead carries the raw inner event JSON and needs a `plaintextContent`
/// extension to dig the `content` field out of it; doing that extraction once,
/// at the service boundary, keeps the JSON-shape knowledge out of ViewModels.
public struct WhistleMessage: Equatable, Identifiable, Sendable {
    public let id: String
    public let mlsGroupId: String
    public let senderPubkey: String
    /// Inner application kind — see `MarmotKind` (location, chat, leaveRequest).
    public let kind: UInt16
    /// Inner plaintext, already extracted from the decrypted event.
    public let content: String
    /// Inner event `created_at`, in seconds since the epoch.
    public let createdAt: UInt64

    /// True for a membership or rename event rather than an app payload.
    ///
    /// These share the timeline with chat, and `payloadType` is nil for them,
    /// so the chat filter used to let them through and render raw JSON in a
    /// bubble.
    public let isSystemEvent: Bool

    /// The MLS epoch the message was sent in, when known.
    ///
    /// A causally correct tiebreaker. `createdAt` has only **one-second**
    /// resolution, so several commits from one action — promote, self-demote,
    /// leave — share a timestamp and sort arbitrarily; ordering by message id
    /// put them on screen in exactly the reverse of what happened. The epoch
    /// increments per commit, so it orders group-state events correctly.
    public let sourceEpoch: UInt64?

    /// MarmotKit's own display string for a system event ("Member added"),
    /// with actor and subject already resolved. Carried so these can be shown
    /// as system rows later instead of being discarded — see ROADMAP.
    public let systemText: String?

    public init(
        id: String,
        mlsGroupId: String,
        senderPubkey: String,
        kind: UInt16,
        content: String,
        createdAt: UInt64,
        isSystemEvent: Bool = false,
        systemText: String? = nil,
        sourceEpoch: UInt64? = nil
    ) {
        self.id = id
        self.mlsGroupId = mlsGroupId
        self.senderPubkey = senderPubkey
        self.kind = kind
        self.content = content
        self.createdAt = createdAt
        self.isSystemEvent = isSystemEvent
        self.systemText = systemText
        self.sourceEpoch = sourceEpoch
    }

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAt))
    }

    /// A page of messages plus the raw row count behind it.
    ///
    /// Paging offsets index the underlying message store, not the mapped
    /// results, and a row whose plaintext cannot be read is dropped during
    /// mapping. A caller that advanced its offset by `messages.count` would
    /// therefore drift and start skipping or re-reading rows, so `rawCount`
    /// reports how many rows the store actually returned.
    public struct Page: Equatable, Sendable {
        public let messages: [WhistleMessage]
        public let rawCount: Int

        public init(messages: [WhistleMessage], rawCount: Int) {
            self.messages = messages
            self.rawCount = rawCount
        }
    }

    /// The `type` discriminator carried inside `content` for `MarmotKind.chat`
    /// payloads (`chat`, `nickname`, `avatar`, `group_avatar`).
    ///
    /// Several distinct payloads share the chat kind and are told apart by this
    /// field, so both the receive path and the chat UI need to read it. `nil`
    /// when the content is not a JSON object with a string `type` — plain text
    /// from an older client, which callers treat as ordinary chat.
    public var payloadType: String? {
        guard
            let data = content.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["type"] as? String
    }
}
