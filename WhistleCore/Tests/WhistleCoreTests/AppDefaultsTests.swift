import XCTest
@testable import WhistleCore

final class AppDefaultsTests: XCTestCase {

    func testDefaultRelaysIsNotEmpty() {
        // Deliberately not an exact count. The previous version of this test
        // pinned it at 3 and named `wss://relay.damus.io` as the first entry,
        // which turned a necessary v2.0 change into a test failure that said
        // nothing about what was actually wrong. What matters about this list
        // is that it is non-empty, well-formed, and dialable — the last of
        // which only MarmotKit can answer, so it is asserted in
        // `MarmotKitRelayPolicyTests` rather than here.
        XCTAssertFalse(AppDefaults.defaultRelays.isEmpty)
    }

    func testAllDefaultRelaysStartWithWss() {
        for relay in AppDefaults.defaultRelays {
            XCTAssertTrue(relay.hasPrefix("wss://"), "Expected wss:// prefix but got: \(relay)")
        }
    }

    /// MarmotKit classifies this host as retired and refuses to dial it, and a
    /// relay-list declaration naming one fails the *entire* relay directory
    /// fetch rather than just that endpoint — so shipping it as a default
    /// broke startup outright on device.
    func testRetiredRelayIsNotADefault() {
        XCTAssertFalse(
            AppDefaults.defaultRelays.contains { $0.contains("relay.damus.io") },
            "relay.damus.io is retired — MarmotKit refuses it and the whole directory fetch fails"
        )
    }

    func testDefaultRelaysHasNoDuplicates() {
        XCTAssertEqual(
            Set(AppDefaults.defaultRelays).count, AppDefaults.defaultRelays.count,
            "a duplicated default relay would be dialled twice"
        )
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
            AppDefaults.Keys.pendingGiftWrapEventIds,
            AppDefaults.Keys.keyRotationIntervalDays
        ]
        for key in keys {
            XCTAssertTrue(key.hasPrefix("fmf."), "Expected fmf. prefix but got: \(key)")
        }
    }
}
