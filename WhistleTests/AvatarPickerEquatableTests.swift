import XCTest
import UIKit
@testable import Whistle

/// Guards the `Equatable` conformances that keep the two photo pickers from
/// reloading mid-presentation.
///
/// Both screens hosting a `PhotosPicker` observe `AppViewModel`, which
/// republishes on every relay event. The pickers only survive those re-renders
/// because SwiftUI can prove the view is unchanged — which requires `==` to
/// compare the value inputs and *ignore* the closures. If someone adds a stored
/// closure to the comparison (or drops `.equatable()` at the call site), the
/// picker starts reloading again. That regression is invisible in a build and
/// annoying to catch by hand, so it is pinned here.
@MainActor
final class AvatarPickerEquatableTests: XCTestCase {

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    }

    // MARK: - GroupAvatarPickerButton

    private func groupButton(
        groupId: String = "abc",
        isAdmin: Bool = true,
        hasSharedImage: Bool = false,
        hasLocalImage: Bool = false,
        image: UIImage? = nil
    ) -> GroupAvatarPickerButton {
        GroupAvatarPickerButton(
            groupId: groupId,
            isAdmin: isAdmin,
            hasSharedImage: hasSharedImage,
            hasLocalImage: hasLocalImage,
            image: image,
            onPickedGroup: { _ in .updated },
            onRemoveGroup: {},
            onPickedLocal: { _ in },
            onRemoveLocal: {}
        )
    }

    func testGroupButtonsWithEqualValuesAreEqualDespiteDistinctClosures() {
        // The regression: distinct closure instances must not make the view
        // look changed, or the presented picker is torn down and reloaded.
        XCTAssertEqual(groupButton(), groupButton())
    }

    func testGroupButtonSameImageInstanceIsEqual() {
        let img = image()
        XCTAssertEqual(groupButton(image: img), groupButton(image: img))
    }

    func testGroupButtonDiffersWhenImageInstanceChanges() {
        XCTAssertNotEqual(groupButton(image: image()), groupButton(image: image()))
    }

    func testGroupButtonDiffersWhenImageAppears() {
        XCTAssertNotEqual(groupButton(image: nil), groupButton(image: image()))
    }

    func testGroupButtonDiffersOnEachValueInput() {
        let base = groupButton()
        XCTAssertNotEqual(base, groupButton(groupId: "other"))
        XCTAssertNotEqual(base, groupButton(isAdmin: false))
        XCTAssertNotEqual(base, groupButton(hasSharedImage: true))
        XCTAssertNotEqual(base, groupButton(hasLocalImage: true))
    }

    // MARK: - AvatarPickerRow

    private func row(
        pubkeyHex: String = "abc",
        displayName: String = "Jane",
        image: UIImage? = nil
    ) -> AvatarPickerRow {
        AvatarPickerRow(
            pubkeyHex: pubkeyHex,
            displayName: displayName,
            image: image,
            onPicked: { _ in true },
            onRemove: {}
        )
    }

    func testRowsWithEqualValuesAreEqualDespiteDistinctClosures() {
        XCTAssertEqual(row(), row())
    }

    func testRowDiffersOnEachValueInput() {
        let base = row()
        XCTAssertNotEqual(base, row(pubkeyHex: "other"))
        XCTAssertNotEqual(base, row(displayName: "Bob"))
        XCTAssertNotEqual(base, row(image: image()))
    }

    func testRowSameImageInstanceIsEqual() {
        let img = image()
        XCTAssertEqual(row(image: img), row(image: img))
    }
}
