import Foundation

/// JSON payload for member avatar broadcasts inside kind-445 MLS application messages.
///
/// Sent as an inner kind-9 message (same as chat and nickname) with its own
/// `type` field.
/// ```json
/// { "type": "avatar", "img": "<base64 JPEG>", "ts": 1700000000, "v": 1 }
/// ```
///
/// The image travels inline rather than as a blob reference. A family group is
/// small and the image is deliberately tiny, so inlining keeps the feature
/// fully end-to-end encrypted with no blob server and no new infrastructure —
/// consistent with the project's no-servers position. See `maxEncodedBytes`
/// for the size ceiling this relies on.
///
/// An empty `img` means "I removed my avatar" — receivers clear any stored
/// image for that member rather than ignoring the message.
public struct AvatarPayload: Codable, Equatable {

    /// Always `"avatar"`.
    public let type: String

    /// Base64-encoded JPEG, or `""` to clear a previously-set avatar.
    public let img: String

    /// Unix timestamp (seconds since epoch).
    public let ts: Int

    /// Schema version — always 1.
    public let v: Int

    public static let currentVersion = 1

    /// Ceiling on the base64 payload, in bytes.
    ///
    /// Nostr relays commonly cap event size somewhere between 64 KB and 256 KB,
    /// and the avatar shares that budget with MLS framing and NIP-44 overhead.
    /// 16 KB leaves generous headroom against the most restrictive relays while
    /// comfortably fitting the encoder's output at `targetEdge` — a 128×128
    /// JPEG at quality 0.7 lands around 4–8 KB base64.
    public static let maxEncodedBytes = 16 * 1024

    /// Edge length, in pixels, that avatars are downscaled to before encoding.
    /// Sized for a map pin and a member row, not a full-screen view.
    public static let targetEdge = 128

    public init(base64Image: String, timestamp: Date = Date()) {
        self.type = "avatar"
        self.img  = base64Image
        self.ts   = Int(timestamp.timeIntervalSince1970)
        self.v    = Self.currentVersion
    }

    /// `true` when this payload clears the sender's avatar rather than setting one.
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
    public static func from(jsonString: String) throws -> AvatarPayload {
        let data = Data(jsonString.utf8)
        return try JSONDecoder().decode(AvatarPayload.self, from: data)
    }
}
