import Foundation
import CoreLocation

/// Latest known location for a group member, stored in `LocationCache`.
public struct MemberLocation: Identifiable, Equatable {

    /// Compound key: `"\(groupId):\(memberPubkeyHex)"`.
    public let id: String

    /// MLS group this location belongs to.
    public let groupId: String

    /// Hex-encoded public key of the member.
    public let memberPubkeyHex: String

    /// The decoded location payload.
    public let payload: LocationPayload

    /// When this location was processed locally.
    public let receivedAt: Date

    public init(groupId: String, memberPubkeyHex: String, payload: LocationPayload, receivedAt: Date = Date()) {
        self.id = "\(groupId):\(memberPubkeyHex)"
        self.groupId = groupId
        self.memberPubkeyHex = memberPubkeyHex
        self.payload = payload
        self.receivedAt = receivedAt
    }

    /// CoreLocation coordinate for MapKit.
    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: payload.lat, longitude: payload.lon)
    }

    /// True when the location is older than 2× the configured update interval.
    public func isStale(intervalSeconds: Int) -> Bool {
        let threshold = TimeInterval(intervalSeconds * 2)
        return Date().timeIntervalSince(payload.date) > threshold
    }

    /// Short display name (first 8 hex chars). Nicknames are added in v0.5.
    public var displayName: String {
        String(memberPubkeyHex.prefix(8)) + "…"
    }
}
