import Foundation

/// JSON payload an invitee gift-wraps to the inviter (NIP-59, rumor kind
/// `MarmotKind.joinRequest`) right after accepting an invite.
///
/// It carries the invitee's KeyPackage **inline** so the admin can batch-add
/// joiners in a single MLS commit without a manual npub exchange. It stays
/// private because it rides inside a kind-1059 gift-wrap rather than any public
/// event — membership intent never touches a relay in the clear.
///
/// Schema (rumor content):
/// ```json
/// { "type": "join-request", "v": 1,
///   "groupId": "<mlsGroupId hex>",
///   "pubkey": "<invitee pubkey hex>",
///   "keyPackage": "<kind-30443 event JSON>",
///   "name": "Alice" }
/// ```
public struct JoinRequest: Codable, Equatable {

    /// Always `"join-request"`.
    public let type: String

    /// Schema version — always 1.
    public let v: Int

    /// Target MLS group id (hex). Lets an admin of several groups route the request.
    public let groupId: String

    /// Invitee's Nostr public key (hex). Redundant with the rumor author, but
    /// explicit so the admin never has to crack open the unwrap internals.
    public let pubkey: String

    /// The invitee's KeyPackage as a kind-30443 event JSON string — added to the
    /// group directly, with no relay fetch (kills the "key package not found" race).
    public let keyPackage: String

    /// Optional display name to show in the admin's pending-joiners list.
    public let name: String?

    public static let currentVersion = 1

    public init(groupId: String, pubkey: String, keyPackage: String, name: String? = nil) {
        self.type = "join-request"
        self.v = Self.currentVersion
        self.groupId = groupId
        self.pubkey = pubkey
        self.keyPackage = keyPackage
        self.name = name
    }

    /// Encode to a JSON string for use as the gift-wrapped rumor content.
    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8)!
    }

    /// Decode from a gift-wrapped rumor's JSON content.
    public static func from(jsonString: String) throws -> JoinRequest {
        let data = Data(jsonString.utf8)
        try JSONNestingGuard.validate(data)
        return try JSONDecoder().decode(JoinRequest.self, from: data)
    }
}
