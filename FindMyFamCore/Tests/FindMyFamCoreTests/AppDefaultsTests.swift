import XCTest
@testable import FindMyFamCore

final class AppDefaultsTests: XCTestCase {

    func testDefaultRelaysContainsExactly3Entries() {
        XCTAssertEqual(AppDefaults.defaultRelays.count, 3)
    }

    func testAllDefaultRelaysStartWithWss() {
        for relay in AppDefaults.defaultRelays {
            XCTAssertTrue(relay.hasPrefix("wss://"), "Expected wss:// prefix but got: \(relay)")
        }
    }

    func testFirstDefaultRelayIsRelayDamusIo() {
        XCTAssertEqual(AppDefaults.defaultRelays[0], "wss://relay.damus.io")
    }

    func testDefaultLocationIntervalSecondsIs3600() {
        XCTAssertEqual(AppDefaults.defaultLocationIntervalSeconds, 3600)
    }

    func testDefaultKeyRotationIntervalDaysIs7() {
        XCTAssertEqual(AppDefaults.defaultKeyRotationIntervalDays, 7)
    }

    func testAllPrefKeysStartWithFmfDot() {
        let keys = [
            AppDefaults.Keys.relays,
            AppDefaults.Keys.displayName,
            AppDefaults.Keys.locationInterval,
            AppDefaults.Keys.locationPaused,
            AppDefaults.Keys.appLockEnabled,
            AppDefaults.Keys.appLockReauthOnForeground,
            AppDefaults.Keys.lastEventTimestamp,
            AppDefaults.Keys.processedEventIds,
            AppDefaults.Keys.pendingLeaveRequests,
            AppDefaults.Keys.pendingGiftWrapEventIds,
            AppDefaults.Keys.keyRotationIntervalDays
        ]
        for key in keys {
            XCTAssertTrue(key.hasPrefix("fmf."), "Expected fmf. prefix but got: \(key)")
        }
    }
}
