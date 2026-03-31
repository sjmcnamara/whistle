import Foundation
import NostrSDK
import FindMyFamCore
@testable import FindMyFam

/// In-memory relay service for unit tests.
///
/// Captures all published events and builders so tests can inspect them.
/// Returns pre-configured events from `fetchEvents`.
/// Gift-wrap operations store/return data without real crypto.
@MainActor
final class MockRelayService: RelayServiceProtocol {

    // MARK: - Captured outputs

    /// JSON strings of events published via `sendEvent(_:)`.
    var sentEvents: [String] = []

    /// (kind, content) pairs published via `publish(builder:)`.
    var publishedBuilders: [(kind: UInt16, content: String)] = []

    /// Gift-wrapped rumor JSONs, keyed by receiver hex pubkey.
    var giftWrappedRumors: [(receiverHex: String, rumorJson: String)] = []

    // MARK: - Configurable inputs

    /// Events to return from `fetchEvents`.
    var eventsToReturn: [Event] = []

    /// The subscription ID returned by `subscribe(filter:)`.
    var subscriptionIdToReturn: String = "mock-sub-001"

    /// Simulated unwrapped gift: set this before calling `unwrapGiftWrap`.
    var unwrappedGiftToReturn: UnwrappedGift?

    /// Captured filters used in fetchEvents calls for assertions.
    var fetchedFilters: [Filter] = []

    // MARK: - State

    var connectionState: RelayService.ConnectionState = .connected
    var connectedRelayURLs: [String] = ["wss://mock.relay"]

    // MARK: - Tracking

    var connectCallCount = 0
    var disconnectCallCount = 0
    var subscribeFilters: [Filter] = []
    var handleNotificationsCalled = false

    // MARK: - RelayServiceProtocol

    func connect(keys: Keys, relays: [RelayConfig]) async {
        connectCallCount += 1
        connectionState = .connected
    }

    func disconnect() async {
        disconnectCallCount += 1
        connectionState = .disconnected
    }

    @discardableResult
    func publish(builder: EventBuilder) async throws -> String {
        // We can't easily inspect EventBuilder internals without signing,
        // so we just record that it was called.
        publishedBuilders.append((kind: 0, content: "builder"))
        return "mock-event-id-\(publishedBuilders.count)"
    }

    @discardableResult
    func sendEvent(_ event: Event) async throws -> String {
        let json = try event.asJson()
        sentEvents.append(json)
        return event.id().toHex()
    }

    func fetchEvents(filter: Filter, timeout: TimeInterval) async throws -> [Event] {
        fetchedFilters.append(filter)
        return eventsToReturn
    }

    func subscribe(filter: Filter) async throws -> String {
        subscribeFilters.append(filter)
        return subscriptionIdToReturn
    }

    func handleNotifications(handler: HandleNotification) async throws {
        handleNotificationsCalled = true
        // In tests, notifications are delivered manually — this is a no-op.
    }

    func giftWrap(receiver: PublicKey, rumor: UnsignedEvent, extraTags: [Tag]) async throws {
        let receiverHex = receiver.toHex()
        let rumorJson = try rumor.asJson()
        giftWrappedRumors.append((receiverHex: receiverHex, rumorJson: rumorJson))
    }

    func unwrapGiftWrap(event: Event) async throws -> UnwrappedGift {
        guard let gift = unwrappedGiftToReturn else {
            fatalError("MockRelayService: unwrappedGiftToReturn not configured")
        }
        return gift
    }
}
