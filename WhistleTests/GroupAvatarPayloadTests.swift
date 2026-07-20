import XCTest
@testable import Whistle
import WhistleCore

final class GroupAvatarPayloadTests: XCTestCase {

    private let sampleImage = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]).base64EncodedString()

    func testTypeFieldIsGroupAvatar() {
        XCTAssertEqual(GroupAvatarPayload(base64Image: sampleImage).type, "group_avatar")
    }

    func testTypeIsDistinctFromMemberAvatar() {
        // The two ride the same inner kind and are told apart only by `type`.
        // If these ever matched, a member photo would overwrite the group's.
        XCTAssertNotEqual(
            GroupAvatarPayload(base64Image: sampleImage).type,
            AvatarPayload(base64Image: sampleImage).type
        )
    }

    func testVersionFieldIsOne() {
        XCTAssertEqual(GroupAvatarPayload(base64Image: sampleImage).v, 1)
    }

    func testRoundTrip() throws {
        let original = GroupAvatarPayload(
            base64Image: sampleImage,
            timestamp: Date(timeIntervalSince1970: 1700000000)
        )
        let decoded = try GroupAvatarPayload.from(jsonString: original.jsonString())
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.img, sampleImage)
        XCTAssertEqual(decoded.ts, 1700000000)
    }

    // MARK: - Removal

    func testEmptyImageIsRemoval() {
        XCTAssertTrue(GroupAvatarPayload(base64Image: "").isRemoval)
    }

    func testRemovalSurvivesRoundTrip() throws {
        let removal = GroupAvatarPayload(base64Image: "")
        XCTAssertTrue(try GroupAvatarPayload.from(jsonString: removal.jsonString()).isRemoval)
    }

    // MARK: - Size ceiling

    func testOversizedPayloadFailsSizeLimit() {
        let payload = GroupAvatarPayload(
            base64Image: String(repeating: "A", count: GroupAvatarPayload.maxEncodedBytes + 1)
        )
        XCTAssertFalse(payload.isWithinSizeLimit)
    }

    func testSizeLimitBoundaryIsInclusive() {
        let payload = GroupAvatarPayload(
            base64Image: String(repeating: "A", count: GroupAvatarPayload.maxEncodedBytes)
        )
        XCTAssertTrue(payload.isWithinSizeLimit)
    }

    func testLimitsMatchMemberAvatar() {
        // Both travel the same way and must clear the same relay event limits.
        // A divergence would mean one kind of avatar silently failing to publish
        // where the other succeeds.
        XCTAssertEqual(GroupAvatarPayload.maxEncodedBytes, AvatarPayload.maxEncodedBytes)
        XCTAssertEqual(GroupAvatarPayload.targetEdge, AvatarPayload.targetEdge)
    }
}
