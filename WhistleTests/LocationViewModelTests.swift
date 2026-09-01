import XCTest
import CoreLocation
import WhistleCore
@testable import Whistle

/// Tests for LocationViewModel's derivation of `[MemberAnnotation]` from the
/// LocationCache, and the group filter. Parity with Android LocationViewModelTest
/// (and folds in the MemberAnnotation coverage — iOS's MemberAnnotation is a
/// non-Equatable view model, exercised here through the annotations it produces).
///
/// `refresh()` is driven directly so derivation is deterministic; the live
/// Combine subscription to the cache is an async main-queue hop unsuited to a
/// synchronous assertion.
@MainActor
final class LocationViewModelTests: XCTestCase {

    private var cache: LocationCache!
    private let myPubkey = String(repeating: "a", count: 64)
    private let otherPubkey = String(repeating: "b", count: 64)
    private let group1 = "group-aaa"
    private let group2 = "group-bbb"

    override func setUp() {
        cache = LocationCache()
    }

    private func makePayload(lat: Double = 53.35, lon: Double = -6.26) -> LocationPayload {
        LocationPayload(latitude: lat, longitude: lon, altitude: 10, accuracy: 5, timestamp: Date())
    }

    private func makeVM(nextFire: Date? = nil) -> LocationViewModel {
        LocationViewModel(
            locationCache: cache,
            nicknameStore: nil,
            intervalSeconds: { 60 },
            myPubkeyHex: { self.myPubkey },
            nextFireDate: { nextFire }
        )
    }

    func testAnnotationsEmptyByDefault() {
        let vm = makeVM()
        vm.refresh()
        XCTAssertTrue(vm.annotations.isEmpty)
    }

    func testAnnotationsReflectCacheUpdates() {
        cache.update(groupId: group1, memberPubkeyHex: myPubkey, payload: makePayload())
        let vm = makeVM()
        vm.refresh()
        XCTAssertEqual(vm.annotations.count, 1)
        XCTAssertTrue(vm.annotations[0].isMe)
    }

    func testAnnotationsMultipleMembers() {
        cache.update(groupId: group1, memberPubkeyHex: myPubkey, payload: makePayload())
        cache.update(groupId: group1, memberPubkeyHex: otherPubkey, payload: makePayload())
        let vm = makeVM()
        vm.refresh()
        XCTAssertEqual(vm.annotations.count, 2)
    }

    func testFreshCacheUpdateIsNotStale() {
        cache.update(groupId: group1, memberPubkeyHex: otherPubkey, payload: makePayload())
        let vm = makeVM()
        vm.refresh()
        XCTAssertFalse(vm.annotations.first!.isStale, "Just-cached payload should not be stale")
    }

    func testSelectedGroupFiltersToOneGroup() {
        cache.update(groupId: group1, memberPubkeyHex: myPubkey, payload: makePayload())
        cache.update(groupId: group2, memberPubkeyHex: otherPubkey, payload: makePayload())
        let vm = makeVM()
        vm.refresh()
        XCTAssertEqual(vm.annotations.count, 2)

        vm.selectedGroupId = group1   // didSet triggers refresh
        XCTAssertEqual(vm.annotations.count, 1)
        XCTAssertTrue(vm.annotations[0].isMe)
    }

    func testSelectedGroupNilShowsAll() {
        cache.update(groupId: group1, memberPubkeyHex: myPubkey, payload: makePayload())
        cache.update(groupId: group2, memberPubkeyHex: otherPubkey, payload: makePayload())
        let vm = makeVM()
        vm.selectedGroupId = group1
        XCTAssertEqual(vm.annotations.count, 1)

        vm.selectedGroupId = nil
        XCTAssertEqual(vm.annotations.count, 2)
    }

    func testIsMeFlagDistinguishesOwnPin() {
        cache.update(groupId: group1, memberPubkeyHex: myPubkey, payload: makePayload())
        cache.update(groupId: group1, memberPubkeyHex: otherPubkey, payload: makePayload())
        let vm = makeVM()
        vm.refresh()

        XCTAssertNotNil(vm.annotations.first { $0.isMe })
        XCTAssertNotNil(vm.annotations.first { !$0.isMe })
        XCTAssertEqual(vm.annotations.filter { $0.isMe }.count, 1)
    }

    func testPositionMatchesPayload() {
        cache.update(groupId: group1, memberPubkeyHex: myPubkey, payload: makePayload(lat: 53.3498, lon: -6.2603))
        let vm = makeVM()
        vm.refresh()
        let ann = vm.annotations.first!
        XCTAssertEqual(ann.coordinate.latitude, 53.3498, accuracy: 1e-9)
        XCTAssertEqual(ann.coordinate.longitude, -6.2603, accuracy: 1e-9)
    }

    func testOwnPinCarriesNextUpdateOthersNil() {
        let nextFire = Date(timeIntervalSince1970: 9_999_999)
        cache.update(groupId: group1, memberPubkeyHex: myPubkey, payload: makePayload())
        cache.update(groupId: group1, memberPubkeyHex: otherPubkey, payload: makePayload())
        let vm = makeVM(nextFire: nextFire)
        vm.refresh()

        let me = vm.annotations.first { $0.isMe }
        let other = vm.annotations.first { !$0.isMe }
        XCTAssertEqual(me?.nextUpdateDate, nextFire, "Own pin drives the count-down")
        XCTAssertNil(other?.nextUpdateDate, "Other members do not carry a next-update date")
    }

    func testNextUpdateNilWhenNoFireYet() {
        cache.update(groupId: group1, memberPubkeyHex: myPubkey, payload: makePayload())
        let vm = makeVM(nextFire: nil)
        vm.refresh()
        XCTAssertNil(vm.annotations.first { $0.isMe }?.nextUpdateDate)
    }

    // MARK: - Self pin dedup across groups
    //
    // LocationCache keys on "groupId:pubkeyHex", so a member of two groups has
    // two separate cache entries for themself. The "all groups" map view must
    // collapse those to a single pin rather than showing the device twice at
    // slightly different coordinates.

    func testSelfPinDedupedAcrossGroups() {
        cache.update(groupId: group1, memberPubkeyHex: myPubkey, payload: makePayload(lat: 1, lon: 1))
        cache.update(groupId: group2, memberPubkeyHex: myPubkey, payload: makePayload(lat: 2, lon: 2))
        cache.update(groupId: group1, memberPubkeyHex: otherPubkey, payload: makePayload())
        let vm = makeVM()
        vm.refresh()

        XCTAssertEqual(vm.annotations.filter { $0.isMe }.count, 1, "Own pin should appear once, not once per group")
        XCTAssertEqual(vm.annotations.count, 2, "Own pin (deduped) + the other member")
    }

    func testSelfPinDedupePicksFreshestEntry() {
        cache.update(groupId: group1, memberPubkeyHex: myPubkey, payload: makePayload(lat: 1, lon: 1))
        cache.update(groupId: group2, memberPubkeyHex: myPubkey, payload: makePayload(lat: 2, lon: 2))
        let vm = makeVM()
        vm.refresh()

        let me = vm.annotations.first { $0.isMe }
        XCTAssertEqual(me?.coordinate.latitude, 2, "The later cache write should win, not group iteration order")
    }

    func testSelfPinNotDedupedWhenFilteredToOneGroup() {
        cache.update(groupId: group1, memberPubkeyHex: myPubkey, payload: makePayload(lat: 1, lon: 1))
        cache.update(groupId: group2, memberPubkeyHex: myPubkey, payload: makePayload(lat: 2, lon: 2))
        let vm = makeVM()
        vm.selectedGroupId = group1

        XCTAssertEqual(vm.annotations.filter { $0.isMe }.count, 1)
        XCTAssertEqual(vm.annotations.first { $0.isMe }?.coordinate.latitude, 1, "Filtering to group1 shows group1's own entry, not group2's")
    }
}
