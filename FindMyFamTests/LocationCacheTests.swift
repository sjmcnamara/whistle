import XCTest
@testable import FindMyFam

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

    func testStaleLocationDetected() {
        let oldDate = Date(timeIntervalSinceNow: -7200) // 2 hours ago
        let payload = LocationPayload(latitude: 0, longitude: 0, altitude: 0, accuracy: 0, timestamp: oldDate)
        let loc = MemberLocation(
            id: "test", groupId: group1, memberPubkeyHex: alice,
            payload: payload, receivedAt: Date()
        )
        // With 1-hour interval, 2× = 2 hours → stale
        XCTAssertTrue(loc.isStale(intervalSeconds: 3600))
    }

    func testFreshLocationNotStale() {
        let recentDate = Date()
        let payload = LocationPayload(latitude: 0, longitude: 0, altitude: 0, accuracy: 0, timestamp: recentDate)
        let loc = MemberLocation(
            id: "test", groupId: group1, memberPubkeyHex: alice,
            payload: payload, receivedAt: Date()
        )
        XCTAssertFalse(loc.isStale(intervalSeconds: 3600))
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
