import Foundation
import WhistleCore
import NostrSDK

/// Abstraction over Nostr relay I/O.
/// Production code uses `RelayService`; tests inject `MockRelayService`.
@MainActor
protocol RelayServiceProtocol: AnyObject {

    var connectionState: RelayService.ConnectionState { get }
    var connectedRelayURLs: [String] { get }

    // MARK: - Connection

    func connect(keys: Keys, relays: [RelayConfig]) async
    func disconnect() async

    /// Re-read live per-relay socket status and republish `connectedRelayURLs`.
    /// Call before showing connection state to the user — relays drop and
    /// reconnect in the background after `connect` returns.
    func refreshConnectedRelays() async

    /// Whether any relay currently has a live socket, re-reading status when the
    /// cached list is empty. Prefer this over `connectedRelayURLs.isEmpty` when
    /// gating network work.
    func hasConnectedRelays() async -> Bool

    /// Add and connect a single relay (e.g. an invite's relay hint) to the existing client.
    func ensureRelay(_ url: String) async

    // MARK: - Publishing

    /// Build, sign, and publish an event to all connected relays.
    @discardableResult
    func publish(builder: EventBuilder) async throws -> String

    /// Publish a pre-signed event to all connected relays.
    @discardableResult
    func sendEvent(_ event: Event) async throws -> String

    // MARK: - Fetching

    /// One-shot fetch: returns events matching the filter.
    func fetchEvents(filter: Filter, timeout: TimeInterval) async throws -> [Event]

    // MARK: - Subscriptions

    /// Open a persistent subscription for events matching the filter.
    func subscribe(filter: Filter) async throws -> String  // returns subscription ID

    /// Register a handler for incoming subscription events.
    func handleNotifications(handler: HandleNotification) async throws

    // MARK: - NIP-59 Gift Wrap

    /// Gift-wrap a rumor (unsigned event) and publish to the receiver.
    func giftWrap(receiver: PublicKey, rumor: UnsignedEvent, extraTags: [Tag]) async throws

    /// Unwrap a received gift-wrap event.
    func unwrapGiftWrap(event: Event) async throws -> UnwrappedGift
}
