import XCTest
@testable import Whistle

/// Covers `AppDelegate.isLocationRelaunch(_:)` — the one piece of logic in
/// `AppDelegate` that isn't a direct pass-through to logging, and the only
/// part that's meaningfully testable without a real `UIApplication` launch.
final class AppDelegateTests: XCTestCase {

    func testNilLaunchOptionsIsNotALocationRelaunch() {
        XCTAssertFalse(AppDelegate.isLocationRelaunch(nil))
    }

    func testEmptyLaunchOptionsIsNotALocationRelaunch() {
        XCTAssertFalse(AppDelegate.isLocationRelaunch([:]))
    }

    func testUnrelatedLaunchOptionKeyIsNotALocationRelaunch() {
        // e.g. a URL-triggered launch — some other key present, but not .location.
        XCTAssertFalse(AppDelegate.isLocationRelaunch([.url: "whistle://invite/abc"]))
    }

    func testLocationKeyPresentIsALocationRelaunch() {
        // The actual value CoreLocation puts here isn't meaningful to us —
        // only the key's presence signals "the OS relaunched us for this."
        XCTAssertTrue(AppDelegate.isLocationRelaunch([.location: NSNumber(value: true)]))
    }
}
