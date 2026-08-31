import XCTest
@testable import Whistle

/// Tests for ChatViewModel.ChatMessageItem (the display-ready chat bubble model).
/// Parity with Android ChatMessageItemTest. ChatPayload wire encoding is covered
/// by WhistleCore's ChatPayloadTests.
@MainActor
final class ChatMessageItemTests: XCTestCase {

    private let myPubkey = String(repeating: "a", count: 64)
    private let otherPubkey = String(repeating: "b", count: 64)

    private func item(
        id: String = "msg-1",
        sender: String = String(repeating: "b", count: 64),
        text: String = "Hello",
        isMe: Bool = false,
        ts: TimeInterval = 1000
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

    func testIsMeWhenSenderIsMyPubkey() {
        XCTAssertTrue(item(sender: myPubkey, isMe: true).isMe)
    }

    func testIsNotMeWhenSenderIsDifferent() {
        XCTAssertFalse(item(sender: otherPubkey, isMe: false).isMe)
    }

    func testFieldsAreCarriedThrough() {
        let m = item(id: "abc", sender: otherPubkey, text: "hi there", ts: 4242)
        XCTAssertEqual(m.id, "abc")
        XCTAssertEqual(m.senderPubkeyHex, otherPubkey)
        XCTAssertEqual(m.text, "hi there")
        XCTAssertEqual(m.timestamp, Date(timeIntervalSince1970: 4242))
    }

    func testEqualitySameValues() {
        XCTAssertEqual(item(), item())
    }

    func testInequalityDifferentText() {
        XCTAssertNotEqual(item(text: "one"), item(text: "two"))
    }

    func testInequalityDifferentSender() {
        XCTAssertNotEqual(item(sender: myPubkey, isMe: true), item(sender: otherPubkey, isMe: false))
    }
}
