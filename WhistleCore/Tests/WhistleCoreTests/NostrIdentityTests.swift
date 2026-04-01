import XCTest
@testable import WhistleCore

final class NostrIdentityTests: XCTestCase {

    func testShortNpubTruncatesLongNpubCorrectly() {
        let identity = NostrIdentity(npub: "npub1abc1234567890xyz", publicKeyHex: "aabbccddeeff")
        // length > 16: prefix(10)...suffix(6)
        XCTAssertEqual(identity.shortNpub, "npub1abc12...890xyz")
    }

    func testShortNpubReturnsFullNpubWhen16CharsOrFewer() {
        let identity = NostrIdentity(npub: "npub1short", publicKeyHex: "aabbccdd")
        XCTAssertEqual(identity.shortNpub, "npub1short")
    }

    func testShortNpubReturnsFullNpubAtExactly16Chars() {
        let npub = "npub1exactly16ch"
        XCTAssertEqual(npub.count, 16)
        let identity = NostrIdentity(npub: npub, publicKeyHex: "aabb")
        XCTAssertEqual(identity.shortNpub, npub)
    }
}
