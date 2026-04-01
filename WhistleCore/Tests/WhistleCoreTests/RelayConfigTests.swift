import XCTest
@testable import WhistleCore

final class RelayConfigTests: XCTestCase {

    func testDefaultIsEnabledIsTrue() {
        let relay = RelayConfig(url: "wss://relay.damus.io")
        XCTAssertTrue(relay.isEnabled)
    }

    func testTwoInstancesWithSameUrlButDifferentUUIDsAreNotEqual() {
        let a = RelayConfig(url: "wss://relay.damus.io")
        let b = RelayConfig(url: "wss://relay.damus.io")
        // RelayConfig uses UUID for id, so two inits produce different identities
        XCTAssertNotEqual(a.id, b.id)
    }

    func testCanSetIsEnabledToFalse() {
        let relay = RelayConfig(url: "wss://nos.lol", isEnabled: false)
        XCTAssertFalse(relay.isEnabled)
    }
}
