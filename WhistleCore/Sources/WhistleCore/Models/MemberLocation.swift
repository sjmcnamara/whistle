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

    /// True when we haven't received a fresh location from this member in
    /// more than 2× their update interval.
    ///
    /// Anchors on `receivedAt` (local clock) rather than `payload.date`
    /// (publisher's clock) so cross-device clock skew doesn't corrupt the
    /// UI — semantically, "stale" means "we haven't heard from them in a
    /// while," which is what users actually care about.
    ///
    /// Prefers the publisher's own `payload.interval` (added in v1.2.1) so a
    /// member on a slow cadence isn't flagged stale just because the local
    /// device polls more often. Falls back to `intervalSeconds` for pre-1.2.1
    /// payloads that omit the field.
    public func isStale(intervalSeconds: Int) -> Bool {
        let basis = payload.interval ?? intervalSeconds
        let threshold = TimeInterval(basis * 2)
        return Date().timeIntervalSince(receivedAt) > threshold
    }

    /// Short display name (first 8 hex chars). Nicknames are added in v0.5.
    public var displayName: String {
        String(memberPubkeyHex.prefix(8)) + "…"
    }
}
