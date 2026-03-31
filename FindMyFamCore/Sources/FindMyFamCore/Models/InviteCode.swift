import Foundation

/// Self-contained invite token for joining a Marmot group.
///
/// An invite encodes the relay URL, inviter's npub, and MLS group ID into
/// a compact base64-URL string that can be shared via iMessage, QR code, etc.
public struct InviteCode: Codable, Equatable {

    /// Relay URL the invitee should connect to (e.g. "wss://relay.damus.io").
    public let relay: String

    /// Bech32 npub of the person who created the invite.
    public let inviterNpub: String

    /// MLS group identifier the invite is for.
    public let groupId: String

    public init(relay: String, inviterNpub: String, groupId: String) {
        self.relay = relay
        self.inviterNpub = inviterNpub
        self.groupId = groupId
    }

    // MARK: - Encoding

    /// Encode the invite as a URL-safe base64 string.
    public func encode() -> String {
        let data = try! JSONEncoder().encode(self)
        return data.base64EncodedString()
    }

    /// Wrap the invite in a `famstr://invite/<code>` deep-link URL.
    public func asURL() -> URL {
        URL(string: "famstr://invite/\(encode())")!
    }

    /// Decode an invite from a base64-encoded string.
    public static func decode(from encoded: String) throws -> InviteCode {
        guard let data = Data(base64Encoded: encoded) else {
            throw InviteError.invalidBase64
        }
        return try JSONDecoder().decode(InviteCode.self, from: data)
    }

    /// Extract an invite from a `famstr://invite/<code>` URL.
    /// Also accepts a raw base64 string for backwards compatibility.
    public static func from(url: URL) throws -> InviteCode {
        if url.scheme == "famstr", url.host == "invite",
           let code = url.pathComponents.dropFirst().first {
            return try decode(from: code)
        }
        return try decode(from: url.absoluteString)
    }

    // MARK: - Approval URL

    /// Build a `famstr://addmember/<pubkeyHex>/<groupId>` URL that the
    /// invitee shares back with the inviter to request group admission.
    public static func approvalURL(pubkeyHex: String, groupId: String) -> URL? {
        // groupId may contain characters that are invalid in a URL path component
        guard let encodedGroup = groupId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "famstr://addmember/\(pubkeyHex)/\(encodedGroup)")
    }

    // MARK: - Errors

    public enum InviteError: LocalizedError {
        case invalidBase64

        public var errorDescription: String? {
            switch self {
            case .invalidBase64: return "Invalid invite code: not valid base64"
            }
        }
    }
}
