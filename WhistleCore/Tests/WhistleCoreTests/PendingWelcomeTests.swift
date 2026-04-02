import XCTest
@testable import WhistleCore

final class PendingWelcomeTests: XCTestCase {

    func testIdIsMlsGroupId() {
        let pw = PendingWelcome(
            mlsGroupId: "group-abc",
            senderPubkeyHex: "aabbcc",
            wrapperEventId: "event-1"
        )
        XCTAssertEqual(pw.id, "group-abc")
    }

    func testReceivedAtDefaultsToNow() {
        let before = Date()
        let pw = PendingWelcome(
            mlsGroupId: "g",
            senderPubkeyHex: "aa",
            wrapperEventId: "e"
        )
        XCTAssertTrue(pw.receivedAt >= before)
        XCTAssertTrue(pw.receivedAt <= Date().addingTimeInterval(5))
    }

    func testCodableRoundTrip() throws {
        let original = PendingWelcome(
            mlsGroupId: "group-1",
            senderPubkeyHex: "deadbeef",
            wrapperEventId: "event-42",
            receivedAt: Date(timeIntervalSince1970: 1700000000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PendingWelcome.self, from: data)
        XCTAssertEqual(decoded.mlsGroupId, original.mlsGroupId)
        XCTAssertEqual(decoded.senderPubkeyHex, original.senderPubkeyHex)
        XCTAssertEqual(decoded.wrapperEventId, original.wrapperEventId)
        XCTAssertEqual(decoded.receivedAt.timeIntervalSince1970,
                       original.receivedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testEquality() {
        let a = PendingWelcome(
            mlsGroupId: "g1",
            senderPubkeyHex: "aa",
            wrapperEventId: "e1",
            receivedAt: Date(timeIntervalSince1970: 1000)
        )
        let b = PendingWelcome(
            mlsGroupId: "g1",
            senderPubkeyHex: "aa",
            wrapperEventId: "e1",
            receivedAt: Date(timeIntervalSince1970: 1000)
        )
        XCTAssertEqual(a, b)
    }

    func testInequalityDifferentGroup() {
        let a = PendingWelcome(mlsGroupId: "g1", senderPubkeyHex: "aa", wrapperEventId: "e1")
        let b = PendingWelcome(mlsGroupId: "g2", senderPubkeyHex: "aa", wrapperEventId: "e1")
        XCTAssertNotEqual(a, b)
    }
}
