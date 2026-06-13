import Foundation
import WhistleCore
import NostrSDK

/// Manages connections to Nostr relays.
@MainActor
final class RelayService: ObservableObject, RelayServiceProtocol {

    // MARK: - Connection state

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var connectedRelayURLs: [String] = []

    // MARK: - Private

    private(set) var client: Client?

    // MARK: - Public API

    /// Connect to the given relays using the provided signing keys.
    func connect(keys: Keys, relays: [RelayConfig]) async {
        guard !relays.isEmpty else {
            WhistleLogger.relay.warning("No relays configured — skipping connect")
            return
        }

        connectionState = .connecting

        let signer    = NostrSigner.keys(keys: keys)
        let newClient = Client(signer: signer)
        var added: [String] = []

        for relay in relays where relay.isEnabled {
            do {
                let url = try RelayUrl.parse(url: relay.url)
                _ = try await newClient.addRelay(url: url)
                added.append(relay.url)
                WhistleLogger.relay.debug("Added relay: \(relay.url)")
            } catch {
                WhistleLogger.relay.warning("Skipping relay \(relay.url): \(error)")
            }
        }

        await newClient.connect()

        self.client            = newClient
        self.connectedRelayURLs = added
        self.connectionState   = added.isEmpty ? .failed("No relays connected") : .connected

        WhistleLogger.relay.info("Connected to \(added.count) relay(s)")
    }

    /// Disconnect from all relays.
    func disconnect() async {
        await client?.disconnect()
        client             = nil
        connectedRelayURLs = []
        connectionState    = .disconnected
        WhistleLogger.relay.info("Disconnected from all relays")
    }

    /// Add and connect a single relay (e.g. an invite's relay hint) to the
    /// existing client so subsequent publishes and gift-wraps reach it. No-op if
    /// already connected or if we have no client yet. `addRelay` is idempotent.
    func ensureRelay(_ url: String) async {
        guard let client else {
            WhistleLogger.relay.warning("ensureRelay(\(url)) skipped — not connected")
            return
        }
        guard !connectedRelayURLs.contains(url) else { return }
        do {
            let relayUrl = try RelayUrl.parse(url: url)
            _ = try await client.addRelay(url: relayUrl)
            try await client.connectRelay(url: relayUrl)
            connectedRelayURLs.append(url)
            WhistleLogger.relay.info("Ensured relay connected: \(url)")
        } catch {
            WhistleLogger.relay.warning("ensureRelay(\(url)) failed: \(error)")
        }
    }

    /// Publish a pre-built event to all connected relays.
    /// - Returns: The event ID on success.
    @discardableResult
    func publish(builder: EventBuilder) async throws -> String {
        guard let client else {
            throw RelayError.notConnected
        }
        let output = try await client.sendEventBuilder(builder: builder)
        return try output.id.toBech32()
    }

    // MARK: - Send pre-signed event

    /// Publish a pre-signed Event object to all connected relays.
    @discardableResult
    func sendEvent(_ event: Event) async throws -> String {
        guard let client else { throw RelayError.notConnected }
        let output = try await client.sendEvent(event: event)
        return output.id.toHex()
    }

    // MARK: - Fetching

    /// One-shot fetch of events matching the filter.
    func fetchEvents(filter: Filter, timeout: TimeInterval) async throws -> [Event] {
        guard let client else { throw RelayError.notConnected }
        let events = try await client.fetchEvents(filter: filter, timeout: timeout)
        return try events.toVec()
    }

    // MARK: - Subscriptions

    /// Open a persistent subscription, returns the subscription ID.
    func subscribe(filter: Filter) async throws -> String {
        guard let client else { throw RelayError.notConnected }
        let output = try await client.subscribe(filter: filter, opts: nil)
        return output.id
    }

    /// Register a handler for incoming events from active subscriptions.
    func handleNotifications(handler: HandleNotification) async throws {
        guard let client else { throw RelayError.notConnected }
        try await client.handleNotifications(handler: handler)
    }

    // MARK: - NIP-59 Gift Wrap

    /// Gift-wrap an unsigned rumor event and publish to the receiver.
    func giftWrap(receiver: PublicKey, rumor: UnsignedEvent, extraTags: [Tag]) async throws {
        guard let client else { throw RelayError.notConnected }
        _ = try await client.giftWrap(receiver: receiver, rumor: rumor, extraTags: extraTags)
    }

    /// Unwrap a received NIP-59 gift-wrap event.
    func unwrapGiftWrap(event: Event) async throws -> UnwrappedGift {
        guard let client else { throw RelayError.notConnected }
        return try await client.unwrapGiftWrap(giftWrap: event)
    }

    // MARK: - Errors

    enum RelayError: LocalizedError {
        case notConnected

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to any relay"
            }
        }
    }
}
