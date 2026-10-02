import XCTest
@testable import Whistle

/// Ordering of the chat thread.
///
/// Exists because of a device failure: promoting a member and then leaving
/// produces three commits inside one second, and the thread showed them as
/// "Member left / Admin removed / Admin added" — the exact reverse of what
/// happened. `timestamp` has one-second resolution, so all three tied, and the
/// tiebreaker was message id, which is a hash.
@MainActor
final class ChatOrderTests: XCTestCase {

    private func item(
        id: String,
        secondsSinceEpoch: TimeInterval,
        mlsEpoch: UInt64? = nil,
        text: String = ""
    ) -> ChatViewModel.ChatMessageItem {
        ChatViewModel.ChatMessageItem(
            id: id,
            senderPubkeyHex: "sender",
            senderDisplayName: "Sender",
            text: text,
            timestamp: Date(timeIntervalSince1970: secondsSinceEpoch),
            isMe: false,
            sourceEpoch: mlsEpoch
        )
    }

    private func ordered(_ items: [ChatViewModel.ChatMessageItem]) -> [String] {
        items.sorted(by: ChatViewModel.inChatOrder).map(\.id)
    }

    func testTimeOrdersWhenTimestampsDiffer() {
        let first = item(id: "a", secondsSinceEpoch: 100)
        let second = item(id: "b", secondsSinceEpoch: 200)
        XCTAssertEqual(ordered([second, first]), ["a", "b"])
    }

    /// The reported bug. Three commits in the same second, supplied in the
    /// wrong order, must come out in epoch order — promote, demote, leave.
    func testEpochOrdersCommitsThatShareASecond() {
        let promote = item(id: "zzz-promote", secondsSinceEpoch: 100, mlsEpoch: 7)
        let demote = item(id: "mmm-demote", secondsSinceEpoch: 100, mlsEpoch: 8)
        let leave = item(id: "aaa-leave", secondsSinceEpoch: 100, mlsEpoch: 9)

        // Ids are deliberately reverse-alphabetical to the intended order, so
        // an id-only tiebreak would produce exactly the inverted sequence seen
        // on device.
        XCTAssertEqual(
            ordered([leave, demote, promote]),
            ["zzz-promote", "mmm-demote", "aaa-leave"]
        )
    }

    /// Timestamp still wins over epoch: a later second is later, whatever the
    /// epoch happens to be.
    func testTimestampTakesPrecedenceOverEpoch() {
        let earlierSecondLaterEpoch = item(id: "a", secondsSinceEpoch: 100, mlsEpoch: 99)
        let laterSecondEarlierEpoch = item(id: "b", secondsSinceEpoch: 200, mlsEpoch: 1)
        XCTAssertEqual(ordered([laterSecondEarlierEpoch, earlierSecondLaterEpoch]), ["a", "b"])
    }

    /// Chat messages carry no meaningful epoch, so same-second chat falls back
    /// to id — arbitrary but **stable**, which is what matters: an unstable
    /// comparator would reshuffle the thread on every merge.
    func testSameSecondWithoutEpochsFallsBackToIdStably() {
        let one = item(id: "a", secondsSinceEpoch: 100)
        let two = item(id: "b", secondsSinceEpoch: 100)
        XCTAssertEqual(ordered([two, one]), ["a", "b"])
        XCTAssertEqual(ordered([one, two]), ["a", "b"])
    }

    /// A mix of one message with an epoch and one without must not crash or
    /// flip depending on argument order.
    func testOneSidedEpochFallsBackToId() {
        let withEpoch = item(id: "b", secondsSinceEpoch: 100, mlsEpoch: 5)
        let without = item(id: "a", secondsSinceEpoch: 100)
        XCTAssertEqual(ordered([withEpoch, without]), ["a", "b"])
        XCTAssertEqual(ordered([without, withEpoch]), ["a", "b"])
    }

    /// Equal epochs in the same second behave like no epoch at all.
    func testEqualEpochsFallBackToId() {
        let one = item(id: "a", secondsSinceEpoch: 100, mlsEpoch: 4)
        let two = item(id: "b", secondsSinceEpoch: 100, mlsEpoch: 4)
        XCTAssertEqual(ordered([two, one]), ["a", "b"])
    }
}
