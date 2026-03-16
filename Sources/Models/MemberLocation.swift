import Foundation
import CoreLocation

/// Latest known location for a group member, stored in `LocationCache`.
struct MemberLocation: Identifiable, Equatable {

    /// Compound key: `"\(groupId):\(memberPubkeyHex)"`.
    let id: String

    /// MLS group this location belongs to.
    let groupId: String

    /// Hex-encoded public key of the member.
    let memberPubkeyHex: String

    /// The decoded location payload.
    let payload: LocationPayload

    /// When this location was processed locally.
    let receivedAt: Date

    /// CoreLocation coordinate for MapKit.
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: payload.lat, longitude: payload.lon)
    }

    /// True when the location is older than 2× the configured update interval.
    func isStale(intervalSeconds: Int) -> Bool {
        let threshold = TimeInterval(intervalSeconds * 2)
        return Date().timeIntervalSince(payload.date) > threshold
    }

    /// Short display name (first 8 hex chars). Nicknames are added in v0.5.
    var displayName: String {
        String(memberPubkeyHex.prefix(8)) + "…"
    }
}
