import Foundation

/// JSON payload for chat messages sent inside kind-445 MLS application messages.
///
/// Schema (inner kind = `MarmotKind.chat` / 9):
/// ```json
/// { "type": "chat", "text": "Hello!", "ts": 1700000000, "v": 1 }
/// ```
struct ChatPayload: Codable, Equatable {

    /// Always `"chat"`.
    let type: String

    /// Message text.
    let text: String

    /// Unix timestamp (seconds since epoch).
    let ts: Int

    /// Schema version — always 1.
    let v: Int

    static let currentVersion = 1

    init(text: String, timestamp: Date = Date()) {
        self.type = "chat"
        self.text = text
        self.ts   = Int(timestamp.timeIntervalSince1970)
        self.v    = Self.currentVersion
    }

    /// Convert the Unix timestamp back to a `Date`.
    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(ts))
    }

    /// Encode to a JSON string for use as MLS message content.
    func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8)!
    }

    /// Decode from a JSON string received in an MLS message.
    static func from(jsonString: String) throws -> ChatPayload {
        let data = Data(jsonString.utf8)
        return try JSONDecoder().decode(ChatPayload.self, from: data)
    }
}
