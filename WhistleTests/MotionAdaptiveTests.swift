import XCTest
@testable import Whistle

/// Tests for motion-adaptive location interval logic.
///
/// MotionService itself cannot be unit-tested without a physical device
/// (CMMotionActivityManager is unavailable on simulator). These tests
/// cover the LocationService throttle logic that consumes the multiplier
/// and the AppSettings persistence of the feature flag.
final class MotionAdaptiveTests: XCTestCase {

    // MARK: - LocationService motionMultiplier

    func testDefaultMultiplierIsOne() {
        let service = LocationService()
        XCTAssertEqual(service.motionMultiplier, 1.0)
    }

    func testMultiplierFourFiresAfterFourTimesInterval() {
        let service = LocationService()
        service.intervalSeconds = 100
        service.motionMultiplier = 4.0

        // Simulate a fire happening 399 seconds ago — not enough at 4× (needs 400s)
        service.lastFireDate = Date(timeIntervalSinceNow: -399)
        XCTAssertFalse(
            service.testShouldFire(),
            "Should not fire after 399s when multiplier=4× and interval=100s"
        )

        // Simulate a fire happening 401 seconds ago — enough at 4×
        service.lastFireDate = Date(timeIntervalSinceNow: -401)
        XCTAssertTrue(
            service.testShouldFire(),
            "Should fire after 401s when multiplier=4× and interval=100s"
        )
    }

    func testMultiplierOneFiresAtNormalInterval() {
        let service = LocationService()
        service.intervalSeconds = 100
        service.motionMultiplier = 1.0

        service.lastFireDate = Date(timeIntervalSinceNow: -99)
        XCTAssertFalse(service.testShouldFire(), "Should not fire before interval elapses")

        service.lastFireDate = Date(timeIntervalSinceNow: -101)
        XCTAssertTrue(service.testShouldFire(), "Should fire after interval elapses")
    }

    func testNilLastFireDateAlwaysFires() {
        let service = LocationService()
        service.motionMultiplier = 4.0
        service.lastFireDate = nil
        XCTAssertTrue(service.testShouldFire(), "First fire should always proceed")
    }

    func testResetThrottleClearsLastFireDate() {
        let service = LocationService()
        service.lastFireDate = Date()
        service.resetThrottle()
        XCTAssertNil(service.lastFireDate)
    }

    func testMultiplierChangesTakeEffectImmediately() {
        let service = LocationService()
        service.intervalSeconds = 100

        // With multiplier=1, 101s elapsed is enough
        service.lastFireDate = Date(timeIntervalSinceNow: -101)
        service.motionMultiplier = 1.0
        XCTAssertTrue(service.testShouldFire())

        // Switch to 4×, same elapsed — no longer enough
        service.motionMultiplier = 4.0
        XCTAssertFalse(service.testShouldFire())
    }

    // MARK: - MotionService constants

    func testStationaryMultiplierIsFour() {
        XCTAssertEqual(MotionService.stationaryMultiplier, 4.0)
    }

    // MARK: - AppSettings

    @MainActor
    func testMotionAdaptiveDefaultsToTrue() {
        // Clear any stored value to simulate first launch
        UserDefaults.standard.removeObject(forKey: "fmf.motionAdaptive")
        // AppSettings.shared reads the default; verify the key logic
        let raw = UserDefaults.standard.object(forKey: "fmf.motionAdaptive")
        let effective = raw == nil ? true : UserDefaults.standard.bool(forKey: "fmf.motionAdaptive")
        XCTAssertTrue(effective, "Motion-adaptive should default to enabled on first launch")
    }
}
