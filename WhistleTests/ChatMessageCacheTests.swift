import XCTest
@testable import Whistle

@MainActor
final class ChatMessageCacheTests: XCTestCase {

    private var cache: ChatMessageCache!
    private let group1 = "group-aaa"
    private let group2 = "group-bbb"
    private let alice = String(repeating: "a", count: 64)
    private let bob   = String(repeating: "b", count: 64)

    override func setUp() {
        cache = ChatMessageCache()
    }

    private func item(
        id: String,
        text: String = "hi",
        sender: String = String(repeating: "a", count: 64),
        isMe: Bool = false,
        ts: TimeInterval = 1_000
    ) -> ChatViewModel.ChatMessageItem {
        ChatViewModel.ChatMessageItem(
            id: id,
            senderPubkeyHex: sender,
            senderDisplayName: isMe ? "Me" : "Alice",
            text: text,
            timestamp: Date(timeIntervalSince1970: ts),
            isMe: isMe
        )
    }

    // MARK: - Empty state

    func testThreadIsNilWhenNothingStored() {
        XCTAssertNil(cache.thread(for: group1))
    }

    // MARK: - Store / retrieve round-trip

    func testStoreThenThreadReturnsSameMessages() {
        let messages = [item(id: "m1"), item(id: "m2", sender: bob)]
        cache.store(groupId: group1, messages: messages, offset: 5, hasMore: true)

        let thread = cache.thread(for: group1)
        XCTAssertEqual(thread?.messages, messages)
        XCTAssertEqual(thread?.offset, 5)
        XCTAssertEqual(thread?.hasMore, true)
    }

    func testStorePreservesPaginationCursor() {
        cache.store(groupId: group1, messages: [item(id: "m1")], offset: 42, hasMore: false)

        let thread = cache.thread(for: group1)
        XCTAssertEqual(thread?.offset, 42)
        XCTAssertEqual(thread?.hasMore, false)
    }

    func testStoreReplacesExistingThread() {
        cache.store(groupId: group1, messages: [item(id: "m1")], offset: 1, hasMore: true)
        cache.store(groupId: group1, messages: [item(id: "m2"), item(id: "m3")], offset: 9, hasMore: false)

        let thread = cache.thread(for: group1)
        XCTAssertEqual(thread?.messages.map(\.id), ["m2", "m3"])
        XCTAssertEqual(thread?.offset, 9)
        XCTAssertEqual(thread?.hasMore, false)
    }

    // MARK: - Isolation between groups

    func testGroupsAreIsolated() {
        cache.store(groupId: group1, messages: [item(id: "a1")], offset: 1, hasMore: true)
        cache.store(groupId: group2, messages: [item(id: "b1")], offset: 2, hasMore: false)

        XCTAssertEqual(cache.thread(for: group1)?.messages.map(\.id), ["a1"])
        XCTAssertEqual(cache.thread(for: group2)?.messages.map(\.id), ["b1"])
    }

    // MARK: - Clear single group

    func testClearGroupDropsOnlyThatGroup() {
        cache.store(groupId: group1, messages: [item(id: "a1")], offset: 1, hasMore: true)
        cache.store(groupId: group2, messages: [item(id: "b1")], offset: 2, hasMore: false)

        cache.clear(groupId: group1)

        XCTAssertNil(cache.thread(for: group1))
        XCTAssertNotNil(cache.thread(for: group2))
    }

    func testClearGroupIsNoOpForUnknownGroup() {
        cache.store(groupId: group1, messages: [item(id: "a1")], offset: 1, hasMore: true)
        cache.clear(groupId: "does-not-exist")
        XCTAssertNotNil(cache.thread(for: group1))
    }

    // MARK: - Clear all

    func testClearAllDropsEveryThread() {
        cache.store(groupId: group1, messages: [item(id: "a1")], offset: 1, hasMore: true)
        cache.store(groupId: group2, messages: [item(id: "b1")], offset: 2, hasMore: false)

        cache.clear()

        XCTAssertNil(cache.thread(for: group1))
        XCTAssertNil(cache.thread(for: group2))
    }

    // MARK: - Empty messages are still a valid cached state

    func testStoreEmptyMessagesIsDistinctFromUnstored() {
        cache.store(groupId: group1, messages: [], offset: 0, hasMore: false)
        let thread = cache.thread(for: group1)
        XCTAssertNotNil(thread, "an empty-but-loaded thread must be cached, not treated as absent")
        XCTAssertEqual(thread?.messages.count, 0)
    }
}
