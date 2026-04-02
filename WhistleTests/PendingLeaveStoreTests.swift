import XCTest
@testable import Whistle

@MainActor
final class PendingLeaveStoreTests: XCTestCase {

    private var store: PendingLeaveStore!

    override func setUp() {
        store = PendingLeaveStore(skipLoad: true)
    }

    // MARK: - Add / Contains

    func testAddAndContains() {
        store.add("group-1")
        XCTAssertTrue(store.contains("group-1"))
        XCTAssertFalse(store.contains("group-2"))
    }

    func testAddDuplicateIsIgnored() {
        store.add("group-1")
        store.add("group-1")
        XCTAssertEqual(store.pendingLeaves.count, 1)
    }

    func testAddMultiple() {
        store.add("g1")
        store.add("g2")
        store.add("g3")
        XCTAssertEqual(store.pendingLeaves.count, 3)
        XCTAssertTrue(store.contains("g1"))
        XCTAssertTrue(store.contains("g2"))
        XCTAssertTrue(store.contains("g3"))
    }

    // MARK: - Remove

    func testRemove() {
        store.add("g1")
        store.add("g2")
        store.remove("g1")
        XCTAssertFalse(store.contains("g1"))
        XCTAssertTrue(store.contains("g2"))
    }

    func testRemoveNonExistentIsNoOp() {
        store.add("g1")
        store.remove("g99")
        XCTAssertEqual(store.pendingLeaves.count, 1)
    }

    func testRemoveAll() {
        store.add("g1")
        store.add("g2")
        store.removeAll()
        XCTAssertTrue(store.pendingLeaves.isEmpty)
    }

    // MARK: - Resolved cleanup

    func testRemoveResolvedClearsGroupsNotInActiveList() {
        store.add("g1")
        store.add("g2")
        store.add("g3")
        // g1 and g3 are still in the active list — they haven't been removed yet.
        // g2 is NOT in the active list — admin processed the removal.
        // removeResolved removes pending leaves whose groups are no longer active.
        store.removeResolved(activeGroupIds: Set(["g1", "g3"]))
        XCTAssertEqual(store.pendingLeaves.count, 2, "g1 and g3 still pending; g2 resolved")
        XCTAssertFalse(store.contains("g2"), "g2 should be cleared — not in active list")
        XCTAssertTrue(store.contains("g1"), "g1 still pending — group is still active")
        XCTAssertTrue(store.contains("g3"), "g3 still pending — group is still active")
    }

    func testRemoveResolvedNoOpWhenAllStillActive() {
        store.add("g1")
        store.add("g2")
        store.removeResolved(activeGroupIds: Set(["g1", "g2", "g3"]))
        XCTAssertEqual(store.pendingLeaves.count, 2, "All pending groups still in active list")
    }

    func testRemoveResolvedClearsAllWhenNoneActive() {
        store.add("g1")
        store.add("g2")
        store.removeResolved(activeGroupIds: Set())
        XCTAssertTrue(store.pendingLeaves.isEmpty, "All should be resolved when no active groups")
    }

    // MARK: - Empty state

    func testInitiallyEmpty() {
        XCTAssertTrue(store.pendingLeaves.isEmpty)
        XCTAssertFalse(store.contains("anything"))
    }
}
