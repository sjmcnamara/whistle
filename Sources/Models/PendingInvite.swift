import Foundation

/// Represents a group invite that has been accepted (key package published)
/// but the Welcome event has not yet been received.
struct PendingInvite: Codable, Identifiable, Equatable {
    /// Unique identifier — uses the group ID hint from the invite code.
    var id: String { groupHint }

    /// Group ID from the invite code (used to match against incoming Welcomes).
    let groupHint: String

    /// Bech32 npub of the person who created the invite.
    let inviterNpub: String

    /// When the invite was accepted locally.
    let createdAt: Date

    init(groupHint: String, inviterNpub: String, createdAt: Date = Date()) {
        self.groupHint = groupHint
        self.inviterNpub = inviterNpub
        self.createdAt = createdAt
    }
}
