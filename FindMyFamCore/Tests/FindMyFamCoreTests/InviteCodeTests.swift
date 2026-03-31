import XCTest
@testable import FindMyFamCore

final class InviteCodeTests: XCTestCase {

    func makeSample() -> InviteCode {
        InviteCode(relay: "wss://relay.damus.io", inviterNpub: "npub1testabcdef", groupId: "group123")
    }

    func testEncodeDecodRoundTripPreservesAllFields() throws {
        let original = makeSample()
        let encoded = original.encode()
        let decoded = try InviteCode.decode(from: encoded)

        XCTAssertEqual(original.relay, decoded.relay)
        XCTAssertEqual(original.inviterNpub, decoded.inviterNpub)
        XCTAssertEqual(original.groupId, decoded.groupId)
    }

    func testAsURLProducesWhistleInvitePrefix() {
        let url = makeSample().asURL()
        XCTAssertTrue(url.absoluteString.hasPrefix("whistle://invite/"))
    }

    func testFromURLParsesWhistleInviteURLCorrectly() throws {
        let original = makeSample()
        let url = original.asURL()
        let decoded = try InviteCode.from(url: url)

        XCTAssertEqual(original.relay, decoded.relay)
        XCTAssertEqual(original.inviterNpub, decoded.inviterNpub)
        XCTAssertEqual(original.groupId, decoded.groupId)
    }

    func testApprovalURLProducesWhistleAddmember() {
        let url = InviteCode.approvalURL(pubkeyHex: "abcdef1234", groupId: "group456")
        XCTAssertEqual(url?.absoluteString, "whistle://addmember/abcdef1234/group456")
    }

    func testFromURLWithRawBase64WorksForBackwardCompat() throws {
        let original = makeSample()
        let rawBase64 = original.encode()
        // Pass raw base64 as a URL (no whistle:// prefix)
        let fakeURL = URL(string: rawBase64)!
        let decoded = try InviteCode.from(url: fakeURL)

        XCTAssertEqual(original.relay, decoded.relay)
        XCTAssertEqual(original.inviterNpub, decoded.inviterNpub)
        XCTAssertEqual(original.groupId, decoded.groupId)
    }
}
