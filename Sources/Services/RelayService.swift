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

    /// Relays with a live socket right now, as the original URL strings from
    /// settings. Derived from the SDK's per-relay status — never from the fact
    /// that a relay was successfully *added*, which says nothing about reachability.
    @Published private(set) var connectedRelayURLs: [String] = []

    // MARK: - Private

    private(set) var client: Client?

    /// Registered relays, mapping the SDK's normalised `RelayUrl` back to the
    /// exact string held in settings. `RelayUrl.parse` normalises (it can append
    /// a trailing slash), so status lookups must be translated back through this
    /// map or callers comparing against their own settings strings never match.
    private var registeredRelays: [RelayUrl: String] = [:]

    /// How long `connect` waits for sockets to open before reporting status.
    /// `Client.connect()` returns as soon as the background connection tasks are
    /// spawned, so without this wait every relay would still be `.connecting`.
    private static let connectionWaitTimeout: TimeInterval = 5

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
        var registered: [RelayUrl: String] = [:]

        for relay in relays where relay.isEnabled {
            do {
                let url = try RelayUrl.parse(url: relay.url)
                _ = try await newClient.addRelay(url: url)
                registered[url] = relay.url
                WhistleLogger.relay.debug("Added relay: \(relay.url)")
            } catch {
                WhistleLogger.relay.warning("Skipping relay \(relay.url): \(error)")
            }
        }

        self.client           = newClient
        self.registeredRelays = registered

        guard !registered.isEmpty else {
            connectedRelayURLs = []
            connectionState    = .failed("No relays connected")
            WhistleLogger.relay.warning("No relays could be registered")
            return
        }

        // `connect()` spawns a retrying background task per relay and returns
        // immediately. We deliberately do not use `tryConnect`, which reports
        // failures synchronously but schedules no retries — bad for a phone that
        // moves between networks.
        await newClient.connect()
        await newClient.waitForConnection(timeout: Self.connectionWaitTimeout)
        await refreshConnectedRelays()
    }

    /// Re-read live socket status from the SDK and republish `connectedRelayURLs`.
    ///
    /// Relays drop and reconnect in the background long after `connect` returns,
    /// so anything showing connection state to the user (settings, diagnostics)
    /// should call this rather than trusting a value cached at connect time.
    func refreshConnectedRelays() async {
        guard let client else {
            connectedRelayURLs = []
            connectionState    = .disconnected
            return
        }

        let relays = await client.relays()
        let connected = relays
            .filter { $0.value.isConnected() }
            .compactMap { registeredRelays[$0.key] ?? $0.key.description }
            .sorted()

        connectedRelayURLs = connected
        connectionState    = connected.isEmpty
            ? .failed("No relays connected")
            : .connected

        WhistleLogger.relay.info("Connected to \(connected.count)/\(relays.count) relay(s)")
    }

    /// Whether any relay currently has a live socket.
    ///
    /// Callers gating network work should use this rather than reading
    /// `connectedRelayURLs.isEmpty` directly: that list is a snapshot from the
    /// last refresh, and relays reconnect in the background between refreshes.
    /// A stale-empty snapshot would otherwise fail an operation that could in
    /// fact have succeeded.
    func hasConnectedRelays() async -> Bool {
        if !connectedRelayURLs.isEmpty { return true }
        await refreshConnectedRelays()
        return !connectedRelayURLs.isEmpty
    }

    /// Disconnect from all relays.
    func disconnect() async {
        await client?.disconnect()
        client             = nil
        registeredRelays   = [:]
        connectedRelayURLs = []
        connectionState    = .disconnected
        WhistleLogger.relay.info("Disconnected from all relays")
    }

    /// Add and connect a single relay (e.g. an invite's relay hint) to the
    /// existing client so subsequent publishes and gift-wraps reach it. No-op if
    /// already registered or if we have no client yet. `addRelay` is idempotent.
    func ensureRelay(_ url: String) async {
        guard let client else {
            WhistleLogger.relay.warning("ensureRelay(\(url)) skipped — not connected")
            return
        }
        do {
            let relayUrl = try RelayUrl.parse(url: url)
            // Guard on registration, not on connection: a relay that is added but
            // currently unreachable must not be re-added on every call.
            guard registeredRelays[relayUrl] == nil else { return }

            _ = try await client.addRelay(url: relayUrl)
            registeredRelays[relayUrl] = url
            try await client.connectRelay(url: relayUrl)
            // `connectRelay` also returns before the socket is up.
            await client.waitForConnection(timeout: Self.connectionWaitTimeout)
            await refreshConnectedRelays()
            WhistleLogger.relay.info("Ensured relay registered: \(url)")
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
