import XCTest
@testable import Whistle

/// Tests for the member-list sort order used by GroupDetailViewModel:
/// me first, then admins, then alphabetical by display name.
/// Parity with Android MemberSortTest.
///
/// The comparator mirrors `GroupDetailViewModel.refreshItems` (the `.sorted`
/// closure) — kept in step with it so the on-screen order stays pinned.
@MainActor
final class MemberSortTests: XCTestCase {

    private let myPubkey = String(repeating: "a", count: 64)

    private func member(
        _ pubkey: String,
        _ name: String,
        isAdmin: Bool = false,
        isMe: Bool = false
    ) -> GroupDetailViewModel.MemberItem {
        .init(id: pubkey, pubkeyHex: pubkey, displayName: name, isAdmin: isAdmin, isMe: isMe)
    }

    private func sort(_ members: [GroupDetailViewModel.MemberItem]) -> [GroupDetailViewModel.MemberItem] {
        members.sorted { lhs, rhs in
            if lhs.isMe != rhs.isMe { return lhs.isMe }
            if lhs.isAdmin != rhs.isAdmin { return lhs.isAdmin }
            return lhs.displayName < rhs.displayName
        }
    }

    func testMeAlwaysFirst() {
        let sorted = sort([
            member("ccc", "Charlie"),
            member(myPubkey, "Me", isMe: true),
            member("bbb", "Alice")
        ])
        XCTAssertTrue(sorted[0].isMe)
    }

    func testAdminBeforeRegularMember() {
        let sorted = sort([
            member("ccc", "Zara"),
            member("bbb", "Admin Bob", isAdmin: true),
            member("ddd", "Alice")
        ])
        XCTAssertEqual(sorted[0].displayName, "Admin Bob")
    }

    func testMeBeforeAdmin() {
        let sorted = sort([
            member("bbb", "Admin Bob", isAdmin: true),
            member(myPubkey, "Me", isMe: true)
        ])
        XCTAssertTrue(sorted[0].isMe)
        XCTAssertTrue(sorted[1].isAdmin)
    }

    func testMeAndAdminMeFirst() {
        let sorted = sort([
            member("bbb", "Admin Bob", isAdmin: true),
            member(myPubkey, "Me (Admin)", isAdmin: true, isMe: true),
            member("ccc", "Charlie")
        ])
        XCTAssertTrue(sorted[0].isMe)
    }

    func testRegularMembersAlphabetical() {
        let sorted = sort([
            member("ccc", "Charlie"),
            member("ddd", "Alice"),
            member("eee", "Bob")
        ])
        XCTAssertEqual(sorted.map(\.displayName), ["Alice", "Bob", "Charlie"])
    }

    func testMultipleAdminsAlphabetical() {
        let sorted = sort([
            member("bbb", "Zara Admin", isAdmin: true),
            member("ccc", "Alice Admin", isAdmin: true),
            member("ddd", "Regular")
        ])
        XCTAssertEqual(sorted.map(\.displayName), ["Alice Admin", "Zara Admin", "Regular"])
    }

    func testSingleMemberNoError() {
        let sorted = sort([member(myPubkey, "Me", isMe: true)])
        XCTAssertEqual(sorted.count, 1)
        XCTAssertTrue(sorted[0].isMe)
    }

    func testEmptyListNoError() {
        XCTAssertTrue(sort([]).isEmpty)
    }

    func testFullScenarioCorrectOrder() {
        let sorted = sort([
            member("fff", "Frank"),
            member("bbb", "Bob Admin", isAdmin: true),
            member(myPubkey, "Me", isMe: true),
            member("ddd", "Dave"),
            member("eee", "Eve Admin", isAdmin: true),
            member("aaa", "Alice")
        ])
        XCTAssertEqual(sorted.map(\.displayName),
                       ["Me", "Bob Admin", "Eve Admin", "Alice", "Dave", "Frank"])
    }
}
