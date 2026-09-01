import XCTest
import UIKit
@testable import Whistle

@MainActor
final class LocalGroupAvatarStoreTests: XCTestCase {

    private var store: LocalGroupAvatarStore!
    private let group = "grouplocal-\(UUID().uuidString.prefix(8))"
    private let otherGroup = "grouplocal-other-\(UUID().uuidString.prefix(8))"

    override func setUp() async throws {
        store = LocalGroupAvatarStore()
        // Start from a clean slate — the on-disk dir is shared (fixed name).
        store.removeImage(for: group)
        store.removeImage(for: otherGroup)
    }

    override func tearDown() async throws {
        store.removeImage(for: group)
        store.removeImage(for: otherGroup)
        store = nil
    }

    private func imageData(edge: CGFloat = 200) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge))
        let img = renderer.image { ctx in
            UIColor.systemPink.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
        }
        return img.jpegData(compressionQuality: 0.9)!
    }

    // MARK: - Empty state

    func testEmptyStoreHasNoImage() {
        XCTAssertNil(store.image(for: group))
        XCTAssertFalse(store.hasImage(for: group))
    }

    // MARK: - Set / persist

    func testSetImageStoresAndBumpsRevision() {
        let before = store.revision
        store.setImage(data: imageData(), for: group)

        XCTAssertTrue(store.hasImage(for: group))
        XCTAssertNotNil(store.image(for: group))
        XCTAssertGreaterThan(store.revision, before)
    }

    func testSetImageRejectsNonImageData() {
        let before = store.revision
        store.setImage(data: Data("not an image".utf8), for: group)

        XCTAssertFalse(store.hasImage(for: group))
        XCTAssertEqual(store.revision, before, "non-image data must not bump revision")
    }

    func testSetImageDownscalesLargeSource() {
        store.setImage(data: imageData(edge: 1024), for: group)
        let img = store.image(for: group)
        XCTAssertNotNil(img)
        // Longest edge is capped at 256 for local thumbnails.
        XCTAssertLessThanOrEqual(max(img!.size.width, img!.size.height), 256)
    }

    func testSetImagePersistsAcrossFreshInstance() {
        store.setImage(data: imageData(), for: group)
        // A new instance reads the same on-disk dir — the picture survives.
        let reloaded = LocalGroupAvatarStore()
        XCTAssertTrue(reloaded.hasImage(for: group))
        XCTAssertNotNil(reloaded.image(for: group))
    }

    // MARK: - Isolation

    func testGroupsAreIsolated() {
        store.setImage(data: imageData(), for: group)
        XCTAssertTrue(store.hasImage(for: group))
        XCTAssertFalse(store.hasImage(for: otherGroup))
    }

    // MARK: - Remove

    func testRemoveImageClearsGroup() {
        store.setImage(data: imageData(), for: group)
        store.removeImage(for: group)

        XCTAssertFalse(store.hasImage(for: group))
        XCTAssertNil(store.image(for: group))
    }

    func testRemoveAllClearsEveryGroup() {
        store.setImage(data: imageData(), for: group)
        store.setImage(data: imageData(), for: otherGroup)

        store.removeAll()

        XCTAssertFalse(store.hasImage(for: group))
        XCTAssertFalse(store.hasImage(for: otherGroup))
    }
}
