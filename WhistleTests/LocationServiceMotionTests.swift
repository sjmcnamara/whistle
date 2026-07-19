import XCTest
@testable import Whistle

/// Tests for `LocationService.effectiveIntervalSeconds` — the value reported
/// in `LocationPayload.interval` so receivers can grade pin staleness against
/// the publisher's *actual* cadence (motion multiplier applied) rather than
/// the user's configured value.
final class LocationServiceMotionTests: XCTestCase {

    func testOneXMultiplierEqualsConfigured() {
        XCTAssertEqual(LocationService.effectiveIntervalSeconds(configured: 10, multiplier: 1.0), 10)
        XCTAssertEqual(LocationService.effectiveIntervalSeconds(configured: 3600, multiplier: 1.0), 3600)
    }

    func testStationaryFourXMultiplierMultipliesConfigured() {
        // Regression: 1.2.1 originally shipped interval=settings.locationIntervalSeconds,
        // ignoring the motion multiplier — a stationary device on a 10s setting
        // published every 40s but stamped interval=10, and iOS receivers marked
        // it stale within 20s of every send.
        XCTAssertEqual(LocationService.effectiveIntervalSeconds(configured: 10, multiplier: MotionService.stationaryMultiplier), 40)
        XCTAssertEqual(LocationService.effectiveIntervalSeconds(configured: 3600, multiplier: MotionService.stationaryMultiplier), 14400)
    }

    func testRoundsNonIntegerProducts() {
        // Future-proofing: if a non-integer multiplier is ever introduced,
        // round-to-nearest is the right semantic (truncation would bias slow).
        XCTAssertEqual(LocationService.effectiveIntervalSeconds(configured: 10, multiplier: 1.5), 15)
        XCTAssertEqual(LocationService.effectiveIntervalSeconds(configured: 10, multiplier: 1.49), 15) // 14.9 → 15
        XCTAssertEqual(LocationService.effectiveIntervalSeconds(configured: 10, multiplier: 1.44), 14) // 14.4 → 14
    }
}
