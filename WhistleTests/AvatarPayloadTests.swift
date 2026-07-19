import XCTest
@testable import Whistle
import WhistleCore

final class AvatarPayloadTests: XCTestCase {

    private let sampleImage = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]).base64EncodedString()

    func testTypeFieldIsAvatar() {
        XCTAssertEqual(AvatarPayload(base64Image: sampleImage).type, "avatar")
    }

    func testVersionFieldIsOne() {
        XCTAssertEqual(AvatarPayload(base64Image: sampleImage).v, 1)
    }

    func testRoundTrip() throws {
        let original = AvatarPayload(
            base64Image: sampleImage,
            timestamp: Date(timeIntervalSince1970: 1700000000)
        )
        let decoded = try AvatarPayload.from(jsonString: original.jsonString())
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.img, sampleImage)
        XCTAssertEqual(decoded.ts, 1700000000)
    }

    // MARK: - Removal sentinel

    func testEmptyImageIsRemoval() {
        XCTAssertTrue(AvatarPayload(base64Image: "").isRemoval)
    }

    func testNonEmptyImageIsNotRemoval() {
        XCTAssertFalse(AvatarPayload(base64Image: sampleImage).isRemoval)
    }

    func testRemovalSurvivesRoundTrip() throws {
        // A removal must stay distinguishable from a set — receivers clear the
        // stored image on this rather than ignoring the message.
        let removal = AvatarPayload(base64Image: "")
        let decoded = try AvatarPayload.from(jsonString: removal.jsonString())
        XCTAssertTrue(decoded.isRemoval)
    }

    // MARK: - Size ceiling

    func testTypicalAvatarIsWithinSizeLimit() {
        // ~6 KB base64 — representative of a 128x128 JPEG at quality 0.7.
        let payload = AvatarPayload(base64Image: String(repeating: "A", count: 6 * 1024))
        XCTAssertTrue(payload.isWithinSizeLimit)
    }

    func testOversizedAvatarFailsSizeLimit() {
        let payload = AvatarPayload(
            base64Image: String(repeating: "A", count: AvatarPayload.maxEncodedBytes + 1)
        )
        XCTAssertFalse(payload.isWithinSizeLimit)
    }

    func testSizeLimitBoundaryIsInclusive() {
        let payload = AvatarPayload(
            base64Image: String(repeating: "A", count: AvatarPayload.maxEncodedBytes)
        )
        XCTAssertTrue(payload.isWithinSizeLimit)
    }

    func testRemovalIsAlwaysWithinSizeLimit() {
        XCTAssertTrue(AvatarPayload(base64Image: "").isWithinSizeLimit)
    }
}
