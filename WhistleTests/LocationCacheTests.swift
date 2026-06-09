import XCTest
import WhistleCore
@testable import Whistle

@MainActor
final class LocationCacheTests: XCTestCase {

    private var cache: LocationCache!
    private let group1 = "group-aaa"
    private let group2 = "group-bbb"
    private let alice = String(repeating: "a", count: 64)
    private let bob   = String(repeating: "b", count: 64)

    override func setUp() {
        cache = LocationCache()
    }

    // MARK: - Insert

    func testInsertNewLocation() {
        let payload = makePayload(lat: 37.77, lon: -122.42)
        cache.update(groupId: group1, memberPubkeyHex: alice, payload: payload)

        XCTAssertEqual(cache.allLocations.count, 1)
        XCTAssertEqual(cache.allLocations.first?.payload.lat, 37.77)
    }

    // MARK: - Update

    func testUpdateOverwritesExisting() {
        cache.update(groupId: group1, memberPubkeyHex: alice, payload: makePayload(lat: 10, lon: 20))
        cache.update(groupId: group1, memberPubkeyHex: alice, payload: makePayload(lat: 30, lon: 40))

        XCTAssertEqual(cache.allLocations.count, 1, "Same key should overwrite, not duplicate")
        XCTAssertEqual(cache.allLocations.first?.payload.lat, 30)
    }

    // MARK: - Group filtering

    func testLocationsForGroup() {
        cache.update(groupId: group1, memberPubkeyHex: alice, payload: makePayload(lat: 1, lon: 1))
        cache.update(groupId: group2, memberPubkeyHex: bob, payload: makePayload(lat: 2, lon: 2))

        let group1Locs = cache.locations(forGroup: group1)
        XCTAssertEqual(group1Locs.count, 1)
        XCTAssertEqual(group1Locs.first?.memberPubkeyHex, alice)

        let group2Locs = cache.locations(forGroup: group2)
        XCTAssertEqual(group2Locs.count, 1)
        XCTAssertEqual(group2Locs.first?.memberPubkeyHex, bob)
    }

    func testAllLocationsSpansGroups() {
        cache.update(groupId: group1, memberPubkeyHex: alice, payload: makePayload(lat: 1, lon: 1))
        cache.update(groupId: group2, memberPubkeyHex: bob, payload: makePayload(lat: 2, lon: 2))

        XCTAssertEqual(cache.allLocations.count, 2)
    }

    // MARK: - Stale detection
    //
    // All tests anchor on `receivedAt` (local clock) since the v1.2.1 fix for
    // cross-device clock skew. `payload.date` (the publisher's stamped time) is
    // no longer the basis — only the local "when did we last hear from them?"
    // matters for UI grey-out.

    func testStaleLocationDetected() {
        let payload = LocationPayload(latitude: 0, longitude: 0, altitude: 0, accuracy: 0, timestamp: Date())
        let loc = MemberLocation(
            groupId: group1, memberPubkeyHex: alice,
            payload: payload, receivedAt: Date(timeIntervalSinceNow: -7200) // received 2h ago
        )
        // With 1-hour interval, 2× = 2 hours → stale
        XCTAssertTrue(loc.isStale(intervalSeconds: 3600))
    }

    func testFreshLocationNotStale() {
        let payload = LocationPayload(latitude: 0, longitude: 0, altitude: 0, accuracy: 0, timestamp: Date())
        let loc = MemberLocation(
            groupId: group1, memberPubkeyHex: alice,
            payload: payload, receivedAt: Date() // received just now
        )
        XCTAssertFalse(loc.isStale(intervalSeconds: 3600))
    }

    func testPublisherIntervalPreferredOverLocal() {
        // Publisher is on a 1-hour cadence; local device polls every 10s.
        // Without payload.interval this would be marked stale within 20s;
        // with it, the threshold is 2 × 3600 = 2h. receivedAt = 1 min ago.
        let payload = LocationPayload(
            latitude: 0, longitude: 0, altitude: 0, accuracy: 0,
            timestamp: Date(), interval: 3600
        )
        let loc = MemberLocation(
            groupId: group1, memberPubkeyHex: alice,
            payload: payload, receivedAt: Date(timeIntervalSinceNow: -60)
        )
        XCTAssertFalse(loc.isStale(intervalSeconds: 10), "Publisher interval (3600s) must win over local (10s)")
    }

    func testFallbackToLocalIntervalWhenPayloadIntervalMissing() {
        // Pre-1.2.1 payload (no interval field) — should still grade against
        // the local interval. receivedAt = 25s ago, local threshold = 20s → stale.
        let payload = LocationPayload(
            latitude: 0, longitude: 0, altitude: 0, accuracy: 0,
            timestamp: Date(), interval: nil
        )
        let loc = MemberLocation(
            groupId: group1, memberPubkeyHex: alice,
            payload: payload, receivedAt: Date(timeIntervalSinceNow: -25)
        )
        XCTAssertTrue(loc.isStale(intervalSeconds: 10), "Should fall back to local 10s × 2 = 20s threshold")
    }

    func testStalenessUnaffectedByPublisherClockSkew() {
        // Regression: previously, isStale used payload.date, so a publisher
        // device whose clock was 30s behind would always show grey on the
        // receiver (apparent age 30s > 20s threshold) even if we'd just
        // received the message. After the fix, receivedAt drives everything.
        let publisherClockSkew: TimeInterval = -300 // publisher's clock is 5 min behind
        let payload = LocationPayload(
            latitude: 0, longitude: 0, altitude: 0, accuracy: 0,
            timestamp: Date(timeIntervalSinceNow: publisherClockSkew)
        )
        let loc = MemberLocation(
            groupId: group1, memberPubkeyHex: alice,
            payload: payload, receivedAt: Date() // we just got it
        )
        XCTAssertFalse(loc.isStale(intervalSeconds: 10), "Clock skew on the publisher side must not poison local staleness")
    }

    // MARK: - Empty state

    func testEmptyCacheReturnsEmpty() {
        XCTAssertTrue(cache.allLocations.isEmpty)
        XCTAssertTrue(cache.locations(forGroup: group1).isEmpty)
    }

    // MARK: - Clear

    func testClearRemovesAll() {
        cache.update(groupId: group1, memberPubkeyHex: alice, payload: makePayload(lat: 1, lon: 1))
        cache.clear()
        XCTAssertTrue(cache.allLocations.isEmpty)
    }

    // MARK: - Helpers

    private func makePayload(lat: Double, lon: Double) -> LocationPayload {
        LocationPayload(latitude: lat, longitude: lon, altitude: 0, accuracy: 10, timestamp: Date())
    }
}
