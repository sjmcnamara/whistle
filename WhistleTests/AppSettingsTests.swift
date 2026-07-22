import XCTest
import SwiftUI
import WhistleCore
@testable import Whistle

/// Tests for AppSettings' own logic: the key-rotation seconds conversion, the
/// appearance → ColorScheme mapping, and relay JSON persistence.
///
/// Partial parity with Android AppSettingsTest. Much of what the Android test
/// covers (processed-event/pending-leave/gift-wrap/unread bookkeeping) lives in
/// dedicated iOS stores — JoinRequestStore, PendingLeaveStore, PendingWelcomeStore —
/// which have their own tests; on iOS AppSettings those are plain stored
/// properties with no per-item method logic to exercise.
///
/// AppSettings is a UserDefaults-backed singleton, so touched keys are
/// snapshotted and restored to avoid leaking state across the suite.
@MainActor
final class AppSettingsTests: XCTestCase {

    private let settings = AppSettings.shared
    private let defaults = UserDefaults.standard

    private var savedRelays: [RelayConfig]!
    private var savedRotation: Int!
    private var savedAppearance: AppAppearance!
    private var savedInterval: Int!
    private var savedFuzz: Int!

    override func setUp() {
        savedRelays = settings.relays
        savedRotation = settings.keyRotationIntervalDays
        savedAppearance = settings.appearance
        savedInterval = settings.locationIntervalSeconds
        savedFuzz = settings.locationFuzzMeters
    }

    override func tearDown() {
        settings.relays = savedRelays
        settings.keyRotationIntervalDays = savedRotation
        settings.appearance = savedAppearance
        settings.locationIntervalSeconds = savedInterval
        settings.locationFuzzMeters = savedFuzz
    }

    // MARK: - Key rotation conversion (parity with Android keyRotationIntervalSecs)

    func testKeyRotationSecondsConversion() {
        settings.keyRotationIntervalDays = 3
        XCTAssertEqual(settings.keyRotationIntervalSecs, UInt64(3) * 24 * 3600)
    }

    func testKeyRotationSecondsForOneDay() {
        settings.keyRotationIntervalDays = 1
        XCTAssertEqual(settings.keyRotationIntervalSecs, 86_400)
    }

    // MARK: - Appearance → ColorScheme mapping

    func testAppearanceSystemMapsToNilScheme() {
        settings.appearance = .system
        XCTAssertNil(settings.colorScheme)
    }

    func testAppearanceLightMapsToLight() {
        settings.appearance = .light
        XCTAssertEqual(settings.colorScheme, .light)
    }

    func testAppearanceDarkMapsToDark() {
        settings.appearance = .dark
        XCTAssertEqual(settings.colorScheme, .dark)
    }

    // MARK: - Relay persistence (encode path)

    func testRelaysRoundTripThroughUserDefaults() throws {
        let custom = [
            RelayConfig(url: "wss://one.example.com", isEnabled: true),
            RelayConfig(url: "wss://two.example.com", isEnabled: false)
        ]
        settings.relays = custom

        // The setter persists JSON to UserDefaults — decode it back and compare.
        let data = try XCTUnwrap(defaults.data(forKey: AppDefaults.Keys.relays))
        let decoded = try JSONDecoder().decode([RelayConfig].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].url, "wss://one.example.com")
        XCTAssertTrue(decoded[0].isEnabled)
        XCTAssertEqual(decoded[1].url, "wss://two.example.com")
        XCTAssertFalse(decoded[1].isEnabled)
    }

    // MARK: - Scalar persistence

    func testLocationIntervalPersists() {
        settings.locationIntervalSeconds = 600
        XCTAssertEqual(settings.locationIntervalSeconds, 600)
        XCTAssertEqual(defaults.integer(forKey: AppDefaults.Keys.locationInterval), 600)
    }

    func testLocationFuzzPersists() {
        settings.locationFuzzMeters = 200
        XCTAssertEqual(settings.locationFuzzMeters, 200)
        XCTAssertEqual(defaults.integer(forKey: AppDefaults.Keys.locationFuzzMeters), 200)
    }
}
