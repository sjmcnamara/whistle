import XCTest
import UIKit
@testable import Whistle
import WhistleCore

@MainActor
final class MemberAvatarStoreTests: XCTestCase {

    private var store: MemberAvatarStore!
    private let pubkey = String(repeating: "a", count: 64)

    override func setUp() async throws {
        // Isolated directory per test run so cases can't see each other's files.
        store = MemberAvatarStore(directoryName: "MemberAvatarsTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        store.removeAll()
        store = nil
    }

    /// Solid-colour image of a given edge, as PNG data (deliberately not JPEG,
    /// so the encoder has to do real work).
    private func imageData(edge: CGFloat) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge))
        let img = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
        }
        return img.pngData()!
    }

    // MARK: - Encoding

    func testEncodeProducesPayloadWithinWireCap() throws {
        // A large source must still come out under the cap — this is the check
        // that stops us publishing an event a relay may reject.
        let encoded = try XCTUnwrap(MemberAvatarStore.encodeForWire(imageData(edge: 2000)))
        XCTAssertLessThanOrEqual(
            encoded.base64EncodedString().utf8.count,
            AvatarPayload.maxEncodedBytes
        )
    }

    func testEncodeDownscalesToTargetEdge() throws {
        let encoded = try XCTUnwrap(MemberAvatarStore.encodeForWire(imageData(edge: 2000)))
        let img = try XCTUnwrap(UIImage(data: encoded))
        XCTAssertLessThanOrEqual(max(img.size.width, img.size.height), CGFloat(AvatarPayload.targetEdge))
    }

    func testEncodeRejectsNonImageData() {
        XCTAssertNil(MemberAvatarStore.encodeForWire(Data("not an image".utf8)))
    }

    // MARK: - Own avatar

    func testSetOwnImageStoresAndReturnsBroadcastablePayload() throws {
        let payload = try XCTUnwrap(store.setOwnImage(data: imageData(edge: 400), pubkeyHex: pubkey))
        XCTAssertFalse(payload.isRemoval)
        XCTAssertTrue(payload.isWithinSizeLimit)
        XCTAssertTrue(store.hasImage(for: pubkey))
        XCTAssertNotNil(store.image(for: pubkey))
    }

    func testOwnPayloadRoundTripsWhatWasStored() throws {
        let set = try XCTUnwrap(store.setOwnImage(data: imageData(edge: 400), pubkeyHex: pubkey))
        // Re-reading for a join broadcast must yield the same bytes we stored,
        // so a newly joined group sees the same face as everyone else.
        let reread = try XCTUnwrap(store.ownPayload(pubkeyHex: pubkey))
        XCTAssertEqual(set.img, reread.img)
    }

    func testOwnPayloadIsNilWhenNoAvatarSet() {
        XCTAssertNil(store.ownPayload(pubkeyHex: pubkey))
    }

    func testRemoveOwnImageClearsAndYieldsRemovalPayload() throws {
        _ = store.setOwnImage(data: imageData(edge: 400), pubkeyHex: pubkey)
        let payload = store.removeOwnImage(pubkeyHex: pubkey)
        XCTAssertTrue(payload.isRemoval)
        XCTAssertFalse(store.hasImage(for: pubkey))
        XCTAssertNil(store.image(for: pubkey))
    }

    // MARK: - Inbound

    func testApplyStoresReceivedAvatar() throws {
        let other = String(repeating: "b", count: 64)
        let encoded = try XCTUnwrap(MemberAvatarStore.encodeForWire(imageData(edge: 400)))
        store.apply(AvatarPayload(base64Image: encoded.base64EncodedString()), from: other)
        XCTAssertTrue(store.hasImage(for: other))
    }

    func testApplyRemovalClearsStoredAvatar() throws {
        let other = String(repeating: "b", count: 64)
        let encoded = try XCTUnwrap(MemberAvatarStore.encodeForWire(imageData(edge: 400)))
        store.apply(AvatarPayload(base64Image: encoded.base64EncodedString()), from: other)
        XCTAssertTrue(store.hasImage(for: other))

        // A removal must actually clear, not be ignored — otherwise a deleted
        // avatar lingers on every other member's map indefinitely.
        store.apply(AvatarPayload(base64Image: ""), from: other)
        XCTAssertFalse(store.hasImage(for: other))
    }

    func testApplyIgnoresUndecodableImage() {
        let other = String(repeating: "b", count: 64)
        store.apply(AvatarPayload(base64Image: "!!!not base64!!!"), from: other)
        XCTAssertFalse(store.hasImage(for: other))
    }

    func testApplyDoesNotAffectOtherMembers() throws {
        let other = String(repeating: "b", count: 64)
        let encoded = try XCTUnwrap(MemberAvatarStore.encodeForWire(imageData(edge: 400)))
        _ = store.setOwnImage(data: imageData(edge: 400), pubkeyHex: pubkey)
        store.apply(AvatarPayload(base64Image: encoded.base64EncodedString()), from: other)
        store.apply(AvatarPayload(base64Image: ""), from: other)

        XCTAssertFalse(store.hasImage(for: other))
        XCTAssertTrue(store.hasImage(for: pubkey), "Clearing one member must not disturb another")
    }

    // MARK: - Bulk clear

    func testRemoveAllClearsEveryAvatar() throws {
        let other = String(repeating: "b", count: 64)
        let encoded = try XCTUnwrap(MemberAvatarStore.encodeForWire(imageData(edge: 400)))
        _ = store.setOwnImage(data: imageData(edge: 400), pubkeyHex: pubkey)
        store.apply(AvatarPayload(base64Image: encoded.base64EncodedString()), from: other)

        store.removeAll()

        XCTAssertFalse(store.hasImage(for: pubkey))
        XCTAssertFalse(store.hasImage(for: other))
    }
}
