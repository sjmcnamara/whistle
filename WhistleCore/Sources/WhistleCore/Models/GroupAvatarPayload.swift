import Foundation

/// JSON payload for a group's shared photo, inside kind-445 MLS application messages.
///
/// Sent as an inner kind-9 message alongside chat, nickname, and member avatar,
/// distinguished by its `type`:
/// ```json
/// { "type": "group_avatar", "img": "<base64 JPEG>", "ts": 1700000000, "v": 1 }
/// ```
///
/// The group is implicit — the message travels inside that group's MLS session,
/// so no group id is carried and none can be spoofed.
///
/// Shares `AvatarPayload`'s size ceiling and target edge deliberately: both
/// travel the same way and must clear the same relay event limits, and a
/// divergence would mean one kind of avatar silently failing where the other
/// works.
///
/// **Admin-only, enforced on receive.** This rides as an MLS *application*
/// message, so MLS guarantees only that the sender is a group member — not that
/// they are an admin. Receivers must check the sender against the group's
/// `adminPubkeys` before applying. (Marmot's own group-image component lives in
/// GroupData and is changed by a commit, where admin policy is enforced at the
/// protocol layer; carrying the image inline trades that for app-layer
/// enforcement in exchange for needing no blob storage.)
///
/// An empty `img` means the admin cleared the group photo.
public struct GroupAvatarPayload: Codable, Equatable {

    /// Always `"group_avatar"`.
    public let type: String

    /// Base64-encoded JPEG, or `""` to clear the group's photo.
    public let img: String

    /// Unix timestamp (seconds since epoch).
    public let ts: Int

    /// Schema version — always 1.
    public let v: Int

    public static let currentVersion = 1

    /// Same ceiling as member avatars — see `AvatarPayload.maxEncodedBytes`.
    public static let maxEncodedBytes = AvatarPayload.maxEncodedBytes

    /// Same target edge as member avatars — see `AvatarPayload.targetEdge`.
    public static let targetEdge = AvatarPayload.targetEdge

    public init(base64Image: String, timestamp: Date = Date()) {
        self.type = "group_avatar"
        self.img  = base64Image
        self.ts   = Int(timestamp.timeIntervalSince1970)
        self.v    = Self.currentVersion
    }

    /// `true` when this payload clears the group photo rather than setting one.
    public var isRemoval: Bool { img.isEmpty }

    /// `true` when the encoded image is within the size ceiling. A payload that
    /// fails this must not be published — an oversized event is liable to be
    /// rejected by the relay, which would silently drop the broadcast.
    public var isWithinSizeLimit: Bool {
        img.utf8.count <= Self.maxEncodedBytes
    }

    /// Encode to a JSON string for use as MLS message content.
    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8)!
    }

    /// Decode from a JSON string received in an MLS message.
    public static func from(jsonString: String) throws -> GroupAvatarPayload {
        let data = Data(jsonString.utf8)
        return try JSONDecoder().decode(GroupAvatarPayload.self, from: data)
    }
}
