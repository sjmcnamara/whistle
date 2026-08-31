import XCTest
import UIKit
@testable import Whistle
import WhistleCore

@MainActor
final class SharedGroupAvatarStoreTests: XCTestCase {

    private var store: SharedGroupAvatarStore!
    private var local: LocalGroupAvatarStore!
    private let group = "abc123group"
    private let otherGroup = "def456group"

    override func setUp() async throws {
        // Isolated directory per test run so cases can't see each other's files.
        store = SharedGroupAvatarStore(directoryName: "SharedGroupAvatarsTests-\(UUID().uuidString)")
        local = LocalGroupAvatarStore()
    }

    override func tearDown() async throws {
        store.removeAll()
        local.removeAll()
        store = nil
        local = nil
    }

    /// Solid-colour JPEG bytes of a given edge.
    private func imageData(edge: CGFloat = 200) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge))
        let img = renderer.image { ctx in
            UIColor.systemIndigo.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
        }
        return img.jpegData(compressionQuality: 0.9)!
    }

    private func payload(_ data: Data) -> GroupAvatarPayload {
        GroupAvatarPayload(base64Image: data.base64EncodedString())
    }

    // MARK: - Empty state

    func testEmptyStoreHasNoImage() {
        XCTAssertNil(store.image(for: group))
        XCTAssertFalse(store.hasImage(for: group))
    }

    // MARK: - apply (inbound)

    func testApplyValidPayloadStoresImage() {
        let before = store.revision
        store.apply(payload(imageData()), for: group)

        XCTAssertTrue(store.hasImage(for: group))
        XCTAssertNotNil(store.image(for: group))
        XCTAssertGreaterThan(store.revision, before, "applying an avatar must bump revision so views re-read")
    }

    func testApplyRemovalPayloadClearsImage() {
        store.apply(payload(imageData()), for: group)
        XCTAssertTrue(store.hasImage(for: group))

        store.apply(GroupAvatarPayload(base64Image: ""), for: group)  // isRemoval
        XCTAssertFalse(store.hasImage(for: group))
        XCTAssertNil(store.image(for: group))
    }

    func testApplyUndecodableBase64IsIgnored() {
        let before = store.revision
        store.apply(GroupAvatarPayload(base64Image: "!!!not base64!!!"), for: group)

        XCTAssertFalse(store.hasImage(for: group))
        XCTAssertEqual(store.revision, before, "an undecodable payload must not bump revision")
    }

    func testApplyIsScopedToGroup() {
        store.apply(payload(imageData()), for: group)
        XCTAssertTrue(store.hasImage(for: group))
        XCTAssertFalse(store.hasImage(for: otherGroup))
    }

    // MARK: - setImage (outbound)

    func testSetImageStoresAndReturnsBroadcastablePayload() async throws {
        let result = await store.setImage(data: imageData(edge: 400), for: group)
        let broadcast = try XCTUnwrap(result)

        XCTAssertFalse(broadcast.isRemoval)
        XCTAssertTrue(broadcast.isWithinSizeLimit)
        XCTAssertTrue(store.hasImage(for: group))
        XCTAssertNotNil(store.image(for: group))
    }

    func testSetImageRejectsNonImageData() async {
        let result = await store.setImage(data: Data("not an image".utf8), for: group)
        XCTAssertNil(result)
        XCTAssertFalse(store.hasImage(for: group))
    }

    // MARK: - payload(for:) re-broadcast

    func testPayloadIsNilWhenNothingStored() {
        XCTAssertNil(store.payload(for: group))
    }

    func testPayloadRoundTripsStoredImage() async throws {
        // `await` cannot live inside XCTUnwrap's autoclosure — hoist it out.
        let result = await store.setImage(data: imageData(edge: 300), for: group)
        let stored = try XCTUnwrap(result)
        let reread = try XCTUnwrap(store.payload(for: group))
        // Re-reading for a join re-announce must yield the same bytes we stored.
        XCTAssertEqual(reread.img, stored.img)
        XCTAssertFalse(reread.isRemoval)
    }

    // MARK: - removeImagePayload

    func testRemoveImagePayloadClearsAndAnnouncesRemoval() {
        store.apply(payload(imageData()), for: group)
        let removal = store.removeImagePayload(for: group)

        XCTAssertTrue(removal.isRemoval)
        XCTAssertFalse(store.hasImage(for: group))
    }

    // MARK: - remove / removeAll

    func testRemoveClearsSingleGroup() {
        store.apply(payload(imageData()), for: group)
        store.apply(payload(imageData()), for: otherGroup)

        store.remove(for: group)

        XCTAssertFalse(store.hasImage(for: group))
        XCTAssertTrue(store.hasImage(for: otherGroup))
    }

    func testRemoveAllClearsEveryGroup() {
        store.apply(payload(imageData()), for: group)
        store.apply(payload(imageData()), for: otherGroup)

        store.removeAll()

        XCTAssertFalse(store.hasImage(for: group))
        XCTAssertFalse(store.hasImage(for: otherGroup))
    }

    // MARK: - resolvedImage precedence

    func testResolvedImagePrefersLocalOverShared() {
        store.apply(payload(imageData()), for: group)
        local.setImage(data: imageData(), for: group)

        let resolved = SharedGroupAvatarStore.resolvedImage(for: group, local: local, shared: store)
        XCTAssertNotNil(resolved)
        // Local wins: the resolved image must be the local one.
        XCTAssertEqual(resolved?.pngData(), local.image(for: group)?.pngData())
    }

    func testResolvedImageFallsBackToSharedWhenNoLocal() {
        store.apply(payload(imageData()), for: group)

        let resolved = SharedGroupAvatarStore.resolvedImage(for: group, local: local, shared: store)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.pngData(), store.image(for: group)?.pngData())
    }

    func testResolvedImageNilWhenNeitherSet() {
        XCTAssertNil(SharedGroupAvatarStore.resolvedImage(for: group, local: local, shared: store))
    }
}
