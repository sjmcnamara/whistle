import XCTest
@testable import FindMyFamCore

final class PendingInviteTests: XCTestCase {

    func testIdEqualsGroupHint() {
        let invite = PendingInvite(groupHint: "group123", inviterNpub: "npub1test")
        XCTAssertEqual(invite.id, "group123")
    }

    func testCreatedAtDefaultsToNowWithin5Seconds() {
        let before = Date()
        let invite = PendingInvite(groupHint: "g", inviterNpub: "npub1x")
        let after = Date().addingTimeInterval(5)
        XCTAssertTrue(invite.createdAt >= before)
        XCTAssertTrue(invite.createdAt <= after)
    }
}
