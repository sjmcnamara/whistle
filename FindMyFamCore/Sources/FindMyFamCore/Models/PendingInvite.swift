import Foundation

/// Represents a group invite that has been accepted (key package published)
/// but the Welcome event has not yet been received.
public struct PendingInvite: Codable, Identifiable, Equatable {
    /// Unique identifier — uses the group ID hint from the invite code.
    public var id: String { groupHint }

    /// Group ID from the invite code (used to match against incoming Welcomes).
    public let groupHint: String

    /// Bech32 npub of the person who created the invite.
    public let inviterNpub: String

    /// When the invite was accepted locally.
    public let createdAt: Date

    public init(groupHint: String, inviterNpub: String, createdAt: Date = Date()) {
        self.groupHint = groupHint
        self.inviterNpub = inviterNpub
        self.createdAt = createdAt
    }
}
