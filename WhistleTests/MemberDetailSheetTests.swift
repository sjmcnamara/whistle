import XCTest
@testable import Whistle

/// Tests for the cadence formatter used by the member detail sheet
/// (iOS v1.3.0 — surfaces `LocationPayload.interval` on pin tap).
final class MemberDetailSheetTests: XCTestCase {

    func testSubMinuteRendersAsSeconds() {
        XCTAssertEqual(MemberDetailSheet.formatCadence(seconds: 10), "10 sec")
        XCTAssertEqual(MemberDetailSheet.formatCadence(seconds: 1), "1 sec")
        XCTAssertEqual(MemberDetailSheet.formatCadence(seconds: 59), "59 sec")
    }

    func testWholeMinutesRenderAsMinutes() {
        XCTAssertEqual(MemberDetailSheet.formatCadence(seconds: 60), "1 min")
        XCTAssertEqual(MemberDetailSheet.formatCadence(seconds: 300), "5 min")
        XCTAssertEqual(MemberDetailSheet.formatCadence(seconds: 59 * 60), "59 min")
    }

    func testWholeHoursRenderAsHours() {
        XCTAssertEqual(MemberDetailSheet.formatCadence(seconds: 3600), "1 hour")
        XCTAssertEqual(MemberDetailSheet.formatCadence(seconds: 7200), "2 hours")
    }

    func testMixedHoursAndMinutesRenderTogether() {
        XCTAssertEqual(MemberDetailSheet.formatCadence(seconds: 5400), "1 hr 30 min")
        XCTAssertEqual(MemberDetailSheet.formatCadence(seconds: 2 * 3600 + 15 * 60), "2 hr 15 min")
    }

    func testZeroSecondsRendersAsZeroSeconds() {
        // Edge case — interval=0 shouldn't happen in practice but should not crash.
        XCTAssertEqual(MemberDetailSheet.formatCadence(seconds: 0), "0 sec")
    }
}
