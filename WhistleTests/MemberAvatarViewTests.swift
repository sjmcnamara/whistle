import XCTest
@testable import Whistle

final class MemberAvatarViewTests: XCTestCase {

    // MARK: - Initials

    func testSingleWordNameTakesFirstLetter() {
        XCTAssertEqual(MemberAvatarView.initials(from: "Dad"), "D")
    }

    func testTwoWordNameTakesBothInitials() {
        XCTAssertEqual(MemberAvatarView.initials(from: "Jane Smith"), "JS")
    }

    func testLongNameTakesOnlyFirstTwo() {
        XCTAssertEqual(MemberAvatarView.initials(from: "Mary Jane Watson Parker"), "MJ")
    }

    func testInitialsAreUppercased() {
        XCTAssertEqual(MemberAvatarView.initials(from: "jane smith"), "JS")
    }

    func testExtraWhitespaceIsIgnored() {
        XCTAssertEqual(MemberAvatarView.initials(from: "  Jane   Smith  "), "JS")
    }

    func testNameWithNoLettersFallsBackToQuestionMark() {
        // Nicknames are free-form — an emoji-only or punctuation-only name must
        // not produce an empty circle.
        XCTAssertEqual(MemberAvatarView.initials(from: "🎉"), "?")
        XCTAssertEqual(MemberAvatarView.initials(from: "!!!"), "?")
        XCTAssertEqual(MemberAvatarView.initials(from: ""), "?")
    }

    func testLeadingNonLetterIsSkippedWithinWord() {
        XCTAssertEqual(MemberAvatarView.initials(from: "@dave"), "D")
    }

    // MARK: - Colour

    func testColourIsStableForSameKey() {
        let key = String(repeating: "a", count: 64)
        XCTAssertEqual(MemberAvatarView.colour(for: key), MemberAvatarView.colour(for: key))
    }

    /// A realistic-looking distinct 64-character hex pubkey.
    private func pubkey(_ i: Int) -> String {
        String(repeating: String(format: "%04x", i), count: 16)
    }

    func testColourSpreadsAcrossPalette() {
        // The earlier version of this test built keys by repeating "\(i)", which
        // for i >= 10 produced 128-character strings — so it passed on length
        // variation rather than on the hash actually mixing. With uniform-length
        // keys, both a byte-sum and an FNV low-bit reduction collapse to a
        // single colour for every member.
        let indices = Set((0..<60).map { MemberAvatarView.colourIndex(for: pubkey($0)) })
        XCTAssertGreaterThanOrEqual(indices.count, 4, "poor palette spread: \(indices.sorted())")
    }

    func testUniformKeysDoNotAllCollide() {
        // The exact degeneracy a plain byte-sum had: 64 identical characters.
        let indices = Set("0123456789abcdef".map {
            MemberAvatarView.colourIndex(for: String(repeating: $0, count: 64))
        })
        XCTAssertGreaterThan(indices.count, 1, "uniform keys all collide")
    }

    func testColourIndexIsAlwaysWithinPalette() {
        for i in 0..<50 {
            let index = MemberAvatarView.colourIndex(for: pubkey(i))
            XCTAssertTrue((0..<MemberAvatarView.palette.count).contains(index))
        }
    }

    func testColourIndexMatchesFNV1aReference() {
        // Pinned so iOS and Android cannot drift apart — the same member must
        // get the same colour on both platforms. Mirrors the Kotlin test.
        let key = "deadbeef" + String(repeating: "0", count: 56)
        var hash: UInt32 = 2166136261
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        XCTAssertEqual(MemberAvatarView.colourIndex(for: key), Int((hash >> 24) % 8))
    }
}
