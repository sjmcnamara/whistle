import Foundation
import WhistleCore

/// In-memory cache of the latest location for each group member.
///
/// `MarmotService` writes to this cache when it receives location messages.
/// The map UI observes it to display member pins.
@MainActor
final class LocationCache: ObservableObject {

    /// Latest location per member, keyed by `"\(groupId):\(pubkeyHex)"`.
    @Published private(set) var locations: [String: MemberLocation] = [:]

    /// Update or insert a member's location.
    func update(groupId: String, memberPubkeyHex: String, payload: LocationPayload) {
        let key = "\(groupId):\(memberPubkeyHex)"
        locations[key] = MemberLocation(
            groupId: groupId,
            memberPubkeyHex: memberPubkeyHex,
            payload: payload,
            receivedAt: Date()
        )
    }

    /// All locations for a specific group.
    func locations(forGroup groupId: String) -> [MemberLocation] {
        locations.values.filter { $0.groupId == groupId }
    }

    /// All locations across all groups.
    var allLocations: [MemberLocation] {
        Array(locations.values)
    }

    /// Remove a specific member's location from a group.
    func removeLocation(groupId: String, memberPubkeyHex: String) {
        let key = "\(groupId):\(memberPubkeyHex)"
        locations.removeValue(forKey: key)
    }

    /// Remove all cached locations for a specific group.
    func clearLocations(forGroup groupId: String) {
        locations = locations.filter { $0.value.groupId != groupId }
    }

    /// Remove all cached locations.
    func clear() {
        locations.removeAll()
    }
}
