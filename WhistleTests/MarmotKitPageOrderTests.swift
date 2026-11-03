import XCTest
import WhistleCore
@testable import Whistle

/// `timelineMessages` returns a page oldest-first, but the chat view models and
/// the "load earlier" cursor (`last` is the oldest row) assume newest-first.
/// Trusting that showed a cold chat load upside down. The order is enforced
/// where the page is read; these pin the comparator that does it.
final class MarmotKitPageOrderTests: XCTestCase {

    private func message(_ id: String, at: UInt64) -> WhistleMessage {
        WhistleMessage(
            id: id, mlsGroupId: "group-1", senderPubkey: "sender",
            kind: 3, content: "hi", createdAt: at
        )
    }

    func testPageIsNewestFirstWhateverOrderTheStoreReturns() {
        let oldestFirst = [message("a", at: 100), message("b", at: 200), message("c", at: 300)]

        let sorted = MarmotKitService.sortedNewestFirst(oldestFirst)

        XCTAssertEqual(sorted.map(\.id), ["c", "b", "a"])
        // The cursor for "load earlier" is the last row, so that must be the oldest.
        XCTAssertEqual(sorted.last?.id, "a")
    }

    func testAlreadyNewestFirstIsUnchanged() {
        let newestFirst = [message("c", at: 300), message("b", at: 200), message("a", at: 100)]
        XCTAssertEqual(MarmotKitService.sortedNewestFirst(newestFirst).map(\.id), ["c", "b", "a"])
    }

    func testMessagesInTheSameSecondAreOrderedByIdNewestFirst() {
        let page = [message("m1", at: 100), message("m3", at: 100), message("m2", at: 100)]
        XCTAssertEqual(MarmotKitService.sortedNewestFirst(page).map(\.id), ["m3", "m2", "m1"])
    }

    func testEmptyPage() {
        XCTAssertEqual(MarmotKitService.sortedNewestFirst([]), [])
    }
}
