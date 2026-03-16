import Foundation
import MDKBindings

// MARK: - Publish payload

/// Everything MLSService operations produce that must be sent to Nostr relays.
struct MLSPublishPayload {
    /// Complete, signed Nostr event JSON strings — publish directly to relays.
    let events: [String]

    /// Inner (unsigned) rumor JSON strings from group creation or member additions.
    /// Each must be NIP-59 gift-wrapped before publishing (handled in v0.3).
    let welcomeRumors: [String]

    /// Relay URLs these payloads should be broadcast to.
    let relayURLs: [String]

    var isEmpty: Bool { events.isEmpty && welcomeRumors.isEmpty }
}

extension CreateGroupResult {
    func publishPayload(relayURLs: [String]) -> MLSPublishPayload {
        MLSPublishPayload(
            events: [],
            welcomeRumors: welcomeRumorsJson,
            relayURLs: relayURLs
        )
    }
}

extension UpdateGroupResult {
    func publishPayload(relayURLs: [String]) -> MLSPublishPayload {
        MLSPublishPayload(
            events: [evolutionEventJson],
            welcomeRumors: welcomeRumorsJson ?? [],
            relayURLs: relayURLs
        )
    }
}

// MARK: - Message convenience

extension Message {
    /// Extracts the plaintext `content` field from the inner decrypted event JSON.
    var plaintextContent: String? {
        guard
            let data = eventJson.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["content"] as? String
    }

    /// Inner event kind.
    var innerKind: Int? {
        guard
            let data = eventJson.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["kind"] as? Int
    }
}

// MARK: - Group convenience

extension Group {
    var isActive: Bool { state == "active" }
}

// MARK: - Message sort order

/// Valid sort order strings for `MLSService.getMessages`.
enum MLSSortOrder {
    /// Sort by event creation timestamp, oldest first.
    static let createdAtFirst   = "created_at_first"
    /// Sort by local processing timestamp, oldest first.
    static let processedAtFirst = "processed_at_first"
}

// MARK: - Kind constants

/// Nostr event kinds used by the Marmot protocol.
enum MarmotKind {
    /// MLS KeyPackage — published by each user to advertise their MLS credentials.
    static let keyPackage:    UInt16 = 443
    /// Welcome — gift-wrapped invitation to join an MLS group.
    static let welcome:       UInt16 = 444
    /// Group event — all in-group traffic: Commits, location updates, chat.
    static let groupEvent:    UInt16 = 445
    /// KeyPackage relay list.
    static let keyPackageRelayList: UInt16 = 10051

    // Inner application message kinds (inside kind-445 payloads)
    static let chat:     UInt16 = 9
    static let location: UInt16 = 1
}
