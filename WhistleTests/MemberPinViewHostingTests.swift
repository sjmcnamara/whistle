import XCTest
import SwiftUI
import CoreLocation
@testable import Whistle

/// Guards `MemberPinView` against reading the SwiftUI environment.
///
/// MapKit hosts `Annotation` content in its own `_UIHostingView`
/// (`SwiftUIAnnotationView`), built from
/// `MKAnnotationManager.updateVisibleAnnotations` — a timer callback outside
/// SwiftUI's update pass, with none of the environment applied at the app root.
/// Any `@EnvironmentObject` reached during the pin's `body` therefore traps in
/// `EnvironmentObject.error()`, taking the app down while the map is panned or
/// zoomed. That shipped in 1.7.1 (via `MemberAvatarView`) and crashed in the
/// wild on 1.8.1.
///
/// These tests host the pin with a deliberately **empty** environment and force
/// a layout, which is the same sequence MapKit performs. A reintroduced
/// environment dependency fails here rather than on a user's phone.
///
/// Note this asserts by *not* trapping: `@EnvironmentObject` resolution failure
/// is a `fatalError`, so a regression aborts the test process rather than
/// reporting a normal failure. A hard crash in this file means exactly one
/// thing — something in the pin's subtree started reading the environment.
@MainActor
final class MemberPinViewHostingTests: XCTestCase {

    private func annotation(
        isStale: Bool = false,
        isStationary: Bool? = nil,
        nextUpdateDate: Date? = nil
    ) -> MemberAnnotation {
        MemberAnnotation(
            id: "member-1",
            memberPubkeyHex: String(repeating: "a", count: 64),
            coordinate: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12),
            displayName: "Jane Smith",
            isStale: isStale,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            isMe: false,
            nextUpdateDate: nextUpdateDate,
            isStationary: isStationary,
            intervalSeconds: 300
        )
    }

    /// Lays the pin out exactly as MapKit does — a bare hosting view with no
    /// environment — and returns the size it resolved to.
    private func hostedSize(_ pin: MemberPinView) -> CGSize {
        let host = UIHostingController(rootView: pin)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: 320, height: 320))
    }

    func testPinLaysOutWithNoEnvironment() {
        let size = hostedSize(MemberPinView(annotation: annotation(), avatarImage: nil))
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func testPinLaysOutWithAnAvatarImage() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in }
        let size = hostedSize(MemberPinView(annotation: annotation(), avatarImage: image))
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    /// The stale, stationary, and own-pin countdown branches each add subviews;
    /// covering them means no branch of the body can smuggle in an environment
    /// read unnoticed.
    func testEveryPinVariantLaysOutWithNoEnvironment() {
        let variants = [
            annotation(isStale: true),
            annotation(isStationary: true),
            annotation(isStationary: false),
            annotation(nextUpdateDate: Date(timeIntervalSince1970: 1_700_000_300))
        ]
        for annotation in variants {
            let size = hostedSize(MemberPinView(annotation: annotation, avatarImage: nil))
            XCTAssertGreaterThan(size.height, 0, "variant \(annotation.id) failed to lay out")
        }
    }
}
