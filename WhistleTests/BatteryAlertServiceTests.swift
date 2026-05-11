import XCTest
@testable import Whistle

@MainActor
final class BatteryAlertServiceTests: XCTestCase {

    private let me    = String(repeating: "0", count: 64)
    private let alice = String(repeating: "a", count: 64)
    private let bob   = String(repeating: "b", count: 64)

    private func makeService() -> (BatteryAlertService, alerts: AlertSpy) {
        let spy = AlertSpy()
        let svc = BatteryAlertService(myPubkeyHex: me, nicknameStore: nil)
        svc.deliver = { name, battery, pubkeyHex in
            spy.record(name: name, battery: battery, pubkeyHex: pubkeyHex)
        }
        return (svc, spy)
    }

    // MARK: - Threshold crossing

    func testFiresOnFirstUpdateBelowThreshold() {
        let (svc, spy) = makeService()
        svc.check(pubkeyHex: alice, battery: 15)
        XCTAssertEqual(spy.count, 1)
        XCTAssertEqual(spy.last?.battery, 15)
    }

    func testFiresWhenCrossingFromAboveToBelow() {
        let (svc, spy) = makeService()
        svc.check(pubkeyHex: alice, battery: 25)
        svc.check(pubkeyHex: alice, battery: 19)
        XCTAssertEqual(spy.count, 1)
        XCTAssertEqual(spy.last?.battery, 19)
    }

    func testDoesNotFireAtExactThreshold() {
        let (svc, spy) = makeService()
        svc.check(pubkeyHex: alice, battery: BatteryAlertService.threshold)
        XCTAssertEqual(spy.count, 0)
    }

    func testDoesNotFireAboveThreshold() {
        let (svc, spy) = makeService()
        svc.check(pubkeyHex: alice, battery: 80)
        XCTAssertEqual(spy.count, 0)
    }

    // MARK: - No repeated firing

    func testDoesNotRefireWhileStillLow() {
        let (svc, spy) = makeService()
        svc.check(pubkeyHex: alice, battery: 15)
        svc.check(pubkeyHex: alice, battery: 12)
        svc.check(pubkeyHex: alice, battery: 5)
        XCTAssertEqual(spy.count, 1, "Should only fire once while battery stays below threshold")
    }

    func testRefiresAfterRecoveryAndDropAgain() {
        let (svc, spy) = makeService()
        svc.check(pubkeyHex: alice, battery: 15)   // fires
        svc.check(pubkeyHex: alice, battery: 50)   // recovery
        svc.check(pubkeyHex: alice, battery: 10)   // fires again
        XCTAssertEqual(spy.count, 2)
    }

    func testNoRefiringIfRecoveryIsExactlyAtThreshold() {
        let (svc, spy) = makeService()
        svc.check(pubkeyHex: alice, battery: 15)
        svc.check(pubkeyHex: alice, battery: BatteryAlertService.threshold) // at threshold, no alert
        svc.check(pubkeyHex: alice, battery: 10)   // should fire again
        XCTAssertEqual(spy.count, 2)
    }

    // MARK: - Own pubkey

    func testDoesNotFireForOwnPubkey() {
        let (svc, spy) = makeService()
        svc.check(pubkeyHex: me, battery: 5)
        XCTAssertEqual(spy.count, 0)
    }

    // MARK: - Nil battery

    func testIgnoresNilBattery() {
        let (svc, spy) = makeService()
        svc.check(pubkeyHex: alice, battery: nil)
        XCTAssertEqual(spy.count, 0)
    }

    // MARK: - Multiple members tracked independently

    func testTracksEachMemberIndependently() {
        let (svc, spy) = makeService()
        svc.check(pubkeyHex: alice, battery: 15)
        svc.check(pubkeyHex: bob, battery: 10)
        XCTAssertEqual(spy.count, 2)
    }

    func testAliceDoesNotSuppressBobAlert() {
        let (svc, spy) = makeService()
        svc.check(pubkeyHex: alice, battery: 15)   // alice fires
        svc.check(pubkeyHex: alice, battery: 12)   // alice suppressed
        svc.check(pubkeyHex: bob, battery: 18)     // bob fires independently
        XCTAssertEqual(spy.count, 2)
        XCTAssertEqual(spy.alerts.map { $0.pubkeyHex }, [alice, bob])
    }

    // MARK: - Display name

    func testUsesShortPubkeyWhenNoNicknameStore() {
        let (svc, spy) = makeService()
        svc.check(pubkeyHex: alice, battery: 10)
        XCTAssertEqual(spy.last?.name, String(alice.prefix(8)))
    }
}

// MARK: - Spy

private final class AlertSpy {
    struct Alert { let name: String; let battery: Int; let pubkeyHex: String }
    private(set) var alerts: [Alert] = []
    var count: Int { alerts.count }
    var last: Alert? { alerts.last }
    func record(name: String, battery: Int, pubkeyHex: String) {
        alerts.append(Alert(name: name, battery: battery, pubkeyHex: pubkeyHex))
    }
}
