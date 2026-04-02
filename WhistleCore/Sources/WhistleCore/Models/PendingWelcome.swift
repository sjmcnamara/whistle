import Foundation

/// A Welcome that arrived without a matching pending invite — requires
/// user approval before joining the group.
public struct PendingWelcome: Codable, Identifiable, Equatable {
    public var id: String { mlsGroupId }

    /// The MLS group ID from the Welcome.
    public let mlsGroupId: String

    /// Hex pubkey of the person who added us (gift-wrap sender).
    public let senderPubkeyHex: String

    /// The outer gift-wrap event ID (needed to re-process the Welcome).
    public let wrapperEventId: String

    /// When the Welcome was received.
    public let receivedAt: Date

    public init(
        mlsGroupId: String,
        senderPubkeyHex: String,
        wrapperEventId: String,
        receivedAt: Date = Date()
    ) {
        self.mlsGroupId = mlsGroupId
        self.senderPubkeyHex = senderPubkeyHex
        self.wrapperEventId = wrapperEventId
        self.receivedAt = receivedAt
    }
}
