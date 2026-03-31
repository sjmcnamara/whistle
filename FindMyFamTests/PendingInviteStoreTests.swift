import XCTest
import FindMyFamCore
@testable import FindMyFam

@MainActor
final class PendingInviteStoreTests: XCTestCase {

    private var store: PendingInviteStore!

    override func setUp() {
        store = PendingInviteStore(skipLoad: true)
    }

    // MARK: - Add / Remove

    func testAddInvite() {
        let invite = PendingInvite(groupHint: "group-1", inviterNpub: "npub1abc")
        store.add(invite)
        XCTAssertEqual(store.pendingInvites.count, 1)
        XCTAssertEqual(store.pendingInvites.first?.groupHint, "group-1")
    }

    func testAddDuplicateIsIgnored() {
        let invite = PendingInvite(groupHint: "group-1", inviterNpub: "npub1abc")
        store.add(invite)
        store.add(invite)
        XCTAssertEqual(store.pendingInvites.count, 1, "Duplicate should be ignored")
    }

    func testRemoveByGroupHint() {
        store.add(PendingInvite(groupHint: "group-1", inviterNpub: "npub1abc"))
        store.add(PendingInvite(groupHint: "group-2", inviterNpub: "npub1def"))
        store.remove(groupHint: "group-1")
        XCTAssertEqual(store.pendingInvites.count, 1)
        XCTAssertEqual(store.pendingInvites.first?.groupHint, "group-2")
    }

    func testRemoveAll() {
        store.add(PendingInvite(groupHint: "group-1", inviterNpub: "npub1abc"))
        store.add(PendingInvite(groupHint: "group-2", inviterNpub: "npub1def"))
        store.removeAll()
        XCTAssertTrue(store.pendingInvites.isEmpty)
    }

    // MARK: - Resolved cleanup

    func testRemoveResolvedClearsMatchingInvites() {
        store.add(PendingInvite(groupHint: "group-1", inviterNpub: "npub1abc"))
        store.add(PendingInvite(groupHint: "group-2", inviterNpub: "npub1def"))
        store.add(PendingInvite(groupHint: "group-3", inviterNpub: "npub1ghi"))

        store.removeResolved(activeGroupIds: Set(["group-1", "group-3"]))
        XCTAssertEqual(store.pendingInvites.count, 1)
        XCTAssertEqual(store.pendingInvites.first?.groupHint, "group-2")
    }

    func testRemoveResolvedNoOpWhenNoMatch() {
        store.add(PendingInvite(groupHint: "group-1", inviterNpub: "npub1abc"))
        store.removeResolved(activeGroupIds: Set(["group-99"]))
        XCTAssertEqual(store.pendingInvites.count, 1, "Non-matching IDs should not remove anything")
    }

    // MARK: - Model

    func testPendingInviteIdentifiable() {
        let invite = PendingInvite(groupHint: "group-1", inviterNpub: "npub1abc")
        XCTAssertEqual(invite.id, "group-1", "id should be the groupHint")
    }

    func testPendingInviteCodable() throws {
        let invite = PendingInvite(groupHint: "group-1", inviterNpub: "npub1abc", createdAt: Date(timeIntervalSince1970: 1700000000))
        let data = try JSONEncoder().encode(invite)
        let decoded = try JSONDecoder().decode(PendingInvite.self, from: data)
        XCTAssertEqual(decoded.groupHint, invite.groupHint)
        XCTAssertEqual(decoded.inviterNpub, invite.inviterNpub)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, invite.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }
}
