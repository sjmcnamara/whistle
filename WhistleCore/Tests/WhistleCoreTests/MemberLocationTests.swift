import XCTest
import CoreLocation
@testable import WhistleCore

final class MemberLocationTests: XCTestCase {

    /// `ageSeconds` controls `receivedAt` (the basis of staleness as of v1.2.1
    /// — see MemberLocation.isStale). The payload's own timestamp is held at
    /// `Date()` since it no longer drives the UI freshness decision.
    func makeLocation(ageSeconds: TimeInterval = 0) -> MemberLocation {
        let payload = LocationPayload(
            latitude: 51.5074,
            longitude: -0.1278,
            altitude: 0.0,
            accuracy: 10.0,
            timestamp: Date()
        )
        return MemberLocation(
            groupId: "groupAbc",
            memberPubkeyHex: "abcdefgh12345678",
            payload: payload,
            receivedAt: Date().addingTimeInterval(-ageSeconds)
        )
    }

    func testIdIsGroupIdColonMemberPubkeyHex() {
        let loc = makeLocation()
        XCTAssertEqual(loc.id, "groupAbc:abcdefgh12345678")
    }

    func testDisplayNameIsFirst8CharsWithEllipsis() {
        let loc = makeLocation()
        XCTAssertEqual(loc.displayName, "abcdefgh…")
    }

    func testIsStaleReturnsTrueWhenLocationIsOlderThan2xInterval() {
        // 3 hours old with 1 hour interval (threshold = 7200s)
        let loc = makeLocation(ageSeconds: 10800)
        XCTAssertTrue(loc.isStale(intervalSeconds: 3600))
    }

    func testIsStaleReturnsFalseWhenLocationIsRecent() {
        let loc = makeLocation(ageSeconds: 0)
        XCTAssertFalse(loc.isStale(intervalSeconds: 3600))
    }

    func testCoordinateMatchesPayloadLatLon() {
        let loc = makeLocation()
        XCTAssertEqual(loc.coordinate.latitude, 51.5074, accuracy: 0.0001)
        XCTAssertEqual(loc.coordinate.longitude, -0.1278, accuracy: 0.0001)
    }
}
