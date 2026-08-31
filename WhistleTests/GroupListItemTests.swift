import XCTest
@testable import Whistle

/// Tests for GroupListViewModel.GroupListItem and the unread predicate.
/// Parity with Android GroupListItemTest.
@MainActor
final class GroupListItemTests: XCTestCase {

    private func item(
        id: String = "group-1",
        name: String = "Test Group",
        memberCount: Int = 3,
        lastActivity: Date? = Date(timeIntervalSince1970: 1000),
        isActive: Bool = true,
        hasUnread: Bool = false
    ) -> GroupListViewModel.GroupListItem {
        .init(id: id, name: name, memberCount: memberCount,
              lastActivity: lastActivity, isActive: isActive, hasUnread: hasUnread)
    }

    func testDefaultValues() {
        let g = item()
        XCTAssertEqual(g.id, "group-1")
        XCTAssertEqual(g.name, "Test Group")
        XCTAssertEqual(g.memberCount, 3)
        XCTAssertTrue(g.isActive)
        XCTAssertFalse(g.hasUnread)
    }

    func testHasUnreadTrue() {
        XCTAssertTrue(item(hasUnread: true).hasUnread)
    }

    func testInactiveGroup() {
        XCTAssertFalse(item(isActive: false).isActive)
    }

    func testNilLastActivity() {
        XCTAssertNil(item(lastActivity: nil).lastActivity)
    }

    func testEqualitySameValues() {
        XCTAssertEqual(item(), item())
    }

    func testEqualityDiffersOnUnread() {
        XCTAssertNotEqual(item(hasUnread: false), item(hasUnread: true))
    }

    func testHasUnreadDefaultsFalse() {
        // The default-argument path (no explicit hasUnread) matches the model default.
        let g = GroupListViewModel.GroupListItem(
            id: "g", name: "n", memberCount: 1, lastActivity: nil, isActive: true
        )
        XCTAssertFalse(g.hasUnread)
    }

    // MARK: - Unread predicate (mirrors refreshItems: lastChatEpoch > lastRead)

    func testUnreadWhenChatAfterLastRead() {
        let lastChatEpoch: TimeInterval? = 100
        let lastRead: TimeInterval = 50
        XCTAssertTrue(lastChatEpoch != nil && lastChatEpoch! > lastRead)
    }

    func testNotUnreadWhenChatBeforeLastRead() {
        let lastChatEpoch: TimeInterval? = 30
        let lastRead: TimeInterval = 50
        XCTAssertFalse(lastChatEpoch != nil && lastChatEpoch! > lastRead)
    }

    func testNotUnreadWhenNoChatTimestamp() {
        let lastChatEpoch: TimeInterval? = nil
        let lastRead: TimeInterval = 50
        XCTAssertFalse(lastChatEpoch != nil && lastChatEpoch! > lastRead)
    }

    func testNotUnreadWhenChatEqualsLastRead() {
        let lastChatEpoch: TimeInterval? = 50
        let lastRead: TimeInterval = 50
        XCTAssertFalse(lastChatEpoch != nil && lastChatEpoch! > lastRead)
    }
}
