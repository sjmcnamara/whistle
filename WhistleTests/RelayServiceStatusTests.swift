import XCTest
import NostrSDK
import WhistleCore
@testable import Whistle

/// Tests for RelayService connection-status reporting.
///
/// The bug these guard against: `connect()` used to populate `connectedRelayURLs`
/// from the list of relays that were successfully *added* to the client. Adding a
/// relay only registers a URL — `Client.connect()` returns as soon as the
/// background connection tasks are spawned, so a relay that could never be
/// reached (a dead host, a typo, a `.onion` address with no Tor proxy) was
/// reported as connected: a green dot in settings, and `MarmotService` gating
/// publishes on a relay set that could not receive them.
///
/// Cases needing a live socket can't run in a unit test; what is covered here is
/// the no-client and no-reachable-relay behaviour, plus the contract that the
/// published list means "connected", not "registered".
@MainActor
final class RelayServiceStatusTests: XCTestCase {

    private var relay: RelayService!

    override func setUp() async throws {
        try await super.setUp()
        relay = RelayService()
    }

    override func tearDown() async throws {
        await relay.disconnect()
        relay = nil
        try await super.tearDown()
    }

    // MARK: - Initial state

    func testFreshServiceReportsNoConnectedRelays() {
        XCTAssertTrue(relay.connectedRelayURLs.isEmpty)
        XCTAssertEqual(relay.connectionState, .disconnected)
    }

    // MARK: - Refresh with no client

    func testRefreshWithoutClientReportsDisconnected() async {
        await relay.refreshConnectedRelays()

        XCTAssertTrue(relay.connectedRelayURLs.isEmpty)
        XCTAssertEqual(relay.connectionState, .disconnected)
    }

    // MARK: - Connect with nothing usable

    func testConnectWithEmptyRelayListLeavesStateDisconnected() async {
        let keys = Keys.generate()
        await relay.connect(keys: keys, relays: [])

        XCTAssertTrue(relay.connectedRelayURLs.isEmpty)
        XCTAssertEqual(relay.connectionState, .disconnected)
    }

    func testConnectWithOnlyDisabledRelaysReportsFailed() async {
        let keys = Keys.generate()
        let relays = [
            RelayConfig(url: "wss://relay.damus.io", isEnabled: false),
            RelayConfig(url: "wss://nos.lol", isEnabled: false)
        ]

        await relay.connect(keys: keys, relays: relays)

        XCTAssertTrue(relay.connectedRelayURLs.isEmpty)
        XCTAssertEqual(relay.connectionState, .failed("No relays connected"))
    }

    func testConnectWithUnparseableRelayReportsFailed() async {
        let keys = Keys.generate()
        // Not a relay URL — `RelayUrl.parse` rejects it, so nothing is registered.
        let relays = [RelayConfig(url: "not-a-url")]

        await relay.connect(keys: keys, relays: relays)

        XCTAssertTrue(relay.connectedRelayURLs.isEmpty)
        XCTAssertEqual(relay.connectionState, .failed("No relays connected"))
    }

    // MARK: - ensureRelay

    func testEnsureRelayWithoutClientIsNoOp() async {
        await relay.ensureRelay("wss://relay.damus.io")

        XCTAssertTrue(relay.connectedRelayURLs.isEmpty)
        XCTAssertEqual(relay.connectionState, .disconnected)
    }

    // MARK: - Disconnect

    /// Uses a disabled relay so a client is created without any socket being
    /// attempted — these tests must not touch the network.
    func testDisconnectClearsConnectedRelays() async {
        let keys = Keys.generate()
        await relay.connect(keys: keys, relays: [RelayConfig(url: "wss://relay.damus.io", isEnabled: false)])
        XCTAssertNotNil(relay.client)

        await relay.disconnect()

        XCTAssertNil(relay.client)
        XCTAssertTrue(relay.connectedRelayURLs.isEmpty)
        XCTAssertEqual(relay.connectionState, .disconnected)
    }
}

/// The consumer-facing contract, exercised through the mock: everything that
/// reads `connectedRelayURLs` must see reachability, not registration.
@MainActor
final class RelayConnectionContractTests: XCTestCase {

    func testUnreachableRelayIsNotReportedAsConnected() async {
        let mock = MockRelayService()
        mock.connectedRelayURLs = ["wss://registered-but-dead.example"]
        // Nothing is actually reachable.
        mock.reachableRelayURLs = []

        await mock.refreshConnectedRelays()

        XCTAssertTrue(mock.connectedRelayURLs.isEmpty,
                      "A registered but unreachable relay must not count as connected")
        XCTAssertEqual(mock.connectionState, .failed("No relays connected"))
    }

    func testOnlyReachableSubsetIsReported() async {
        let mock = MockRelayService()
        mock.connectedRelayURLs = ["wss://a.example", "wss://b.example"]
        mock.reachableRelayURLs = ["wss://a.example"]

        await mock.refreshConnectedRelays()

        XCTAssertEqual(mock.connectedRelayURLs, ["wss://a.example"])
        XCTAssertEqual(mock.connectionState, .connected)
    }

    func testDisconnectClearsConnectedRelays() async {
        let mock = MockRelayService()
        mock.connectedRelayURLs = ["wss://a.example"]

        await mock.disconnect()

        XCTAssertTrue(mock.connectedRelayURLs.isEmpty)
        XCTAssertEqual(mock.connectionState, .disconnected)
    }
}
