import XCTest
import WhistleCore
@testable import Whistle

@MainActor
final class PendingWelcomeStoreTests: XCTestCase {

    private var store: PendingWelcomeStore!

    override func setUp() {
        store = PendingWelcomeStore(skipLoad: true)
    }

    // MARK: - Add

    func testAddWelcome() {
        let pw = PendingWelcome(
            mlsGroupId: "group-1",
            senderPubkeyHex: "aabb",
            wrapperEventId: "event-1"
        )
        store.add(pw)
        XCTAssertEqual(store.pendingWelcomes.count, 1)
        XCTAssertEqual(store.pendingWelcomes.first?.mlsGroupId, "group-1")
    }

    func testAddDuplicateIsIgnored() {
        let pw = PendingWelcome(
            mlsGroupId: "group-1",
            senderPubkeyHex: "aabb",
            wrapperEventId: "event-1"
        )
        store.add(pw)
        store.add(pw)
        XCTAssertEqual(store.pendingWelcomes.count, 1, "Duplicate should be ignored")
    }

    func testAddMultipleGroups() {
        store.add(PendingWelcome(mlsGroupId: "g1", senderPubkeyHex: "aa", wrapperEventId: "e1"))
        store.add(PendingWelcome(mlsGroupId: "g2", senderPubkeyHex: "bb", wrapperEventId: "e2"))
        store.add(PendingWelcome(mlsGroupId: "g3", senderPubkeyHex: "cc", wrapperEventId: "e3"))
        XCTAssertEqual(store.pendingWelcomes.count, 3)
    }

    // MARK: - Remove

    func testRemoveByGroupId() {
        store.add(PendingWelcome(mlsGroupId: "g1", senderPubkeyHex: "aa", wrapperEventId: "e1"))
        store.add(PendingWelcome(mlsGroupId: "g2", senderPubkeyHex: "bb", wrapperEventId: "e2"))
        store.remove(mlsGroupId: "g1")
        XCTAssertEqual(store.pendingWelcomes.count, 1)
        XCTAssertEqual(store.pendingWelcomes.first?.mlsGroupId, "g2")
    }

    func testRemoveNonExistentIsNoOp() {
        store.add(PendingWelcome(mlsGroupId: "g1", senderPubkeyHex: "aa", wrapperEventId: "e1"))
        store.remove(mlsGroupId: "g99")
        XCTAssertEqual(store.pendingWelcomes.count, 1)
    }

    func testRemoveAll() {
        store.add(PendingWelcome(mlsGroupId: "g1", senderPubkeyHex: "aa", wrapperEventId: "e1"))
        store.add(PendingWelcome(mlsGroupId: "g2", senderPubkeyHex: "bb", wrapperEventId: "e2"))
        store.removeAll()
        XCTAssertTrue(store.pendingWelcomes.isEmpty)
    }

    // MARK: - Empty state

    func testInitiallyEmpty() {
        XCTAssertTrue(store.pendingWelcomes.isEmpty)
    }
}
