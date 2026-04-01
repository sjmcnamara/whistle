import Foundation

/// JSON payload for nickname broadcasts inside kind-445 MLS application messages.
///
/// Sent as an inner kind-9 message (same as chat) with a different `type` field.
/// ```json
/// { "type": "nickname", "name": "Dad", "ts": 1700000000, "v": 1 }
/// ```
public struct NicknamePayload: Codable, Equatable {

    /// Always `"nickname"`.
    public let type: String

    /// The display name the sender wants to use.
    public let name: String

    /// Unix timestamp (seconds since epoch).
    public let ts: Int

    /// Schema version — always 1.
    public let v: Int

    public static let currentVersion = 1

    public init(name: String, timestamp: Date = Date()) {
        self.type = "nickname"
        self.name = name
        self.ts   = Int(timestamp.timeIntervalSince1970)
        self.v    = Self.currentVersion
    }

    /// Encode to a JSON string for use as MLS message content.
    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8)!
    }

    /// Decode from a JSON string received in an MLS message.
    public static func from(jsonString: String) throws -> NicknamePayload {
        let data = Data(jsonString.utf8)
        return try JSONDecoder().decode(NicknamePayload.self, from: data)
    }
}
