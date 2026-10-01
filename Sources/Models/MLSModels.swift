import Foundation
import MDKBindings
import WhistleCore

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

// MARK: - Mapping to app-owned types

// The boundary between MDK's types and the app's own. ViewModels and Views
// consume `WhistleGroup`/`WhistleMessage` (declared in WhistleCore, which
// cannot import MDKBindings) so that replacing the MLS backend — see the
// MDK 2.0 / MarmotKit migration in ROADMAP.md — does not reach past the
// service layer. These two functions are the only place MDK's shapes are
// translated, and they go away with the rest of this file at the cutover.

extension Group {
    var snapshot: WhistleGroup {
        WhistleGroup(
            mlsGroupId: mlsGroupId,
            name: name,
            isActive: isActive,
            epoch: epoch,
            adminPubkeys: adminPubkeys,
            lastMessageAt: lastMessageAt
        )
    }
}

extension Message {
    /// `nil` when the inner plaintext cannot be read, which is the same
    /// condition every existing caller already treats as "skip this message".
    var snapshot: WhistleMessage? {
        guard let content = plaintextContent else { return nil }
        return WhistleMessage(
            id: id,
            mlsGroupId: mlsGroupId,
            senderPubkey: senderPubkey,
            kind: kind,
            content: content,
            createdAt: createdAt
        )
    }
}

// MARK: - Message sort order

/// Valid sort order strings for `MLSService.getMessages`.
enum MLSSortOrder {
    /// Sort by event creation timestamp, oldest first.
    static let createdAtFirst   = "created_at_first"
    /// Sort by local processing timestamp, oldest first.
    static let processedAtFirst = "processed_at_first"
}

// MarmotKind is now provided by WhistleCore
