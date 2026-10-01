import Foundation

/// A minimal NIP-01 relay for tests, with control over replay order.
///
/// Exists for one reason: step 3c has to prove whether MarmotKit still needs
/// Whistle's v1.11.2 relay-delivery-order buffer, and that means delivering a
/// commit *before* its predecessor on purpose. No stock relay lets a client
/// dictate the order in which stored events come back, so the harness has to
/// be the relay. See `LoopbackWebSocketServer` for the transport underneath
/// and why MarmotKit can be pointed at it at all.
///
/// Scope is "enough NIP-01 that MarmotKit works", not a conformant relay:
/// `EVENT`, `REQ`, `CLOSE`, with `OK` and `EOSE` replies, filter matching on
/// the fields clients actually send, and live fan-out to open subscriptions.
/// Absent: `AUTH`, `COUNT`, NIP-50 search, ephemeral/replaceable-event
/// semantics, and persistence across a run.
final class LoopbackRelay {

    /// Order in which stored events are replayed for a `REQ`.
    ///
    /// The whole point of the harness. `asReceived` is the benign case;
    /// `reversed` is the adversarial one that reproduces a commit arriving
    /// before the commit it builds on.
    enum ReplayOrder {
        /// Publication order — what a well-behaved relay approximates.
        case asReceived
        /// Exact reverse of publication order.
        case reversed
        /// Oldest-first by `created_at`, ties broken by arrival.
        case createdAtAscending
        /// Caller decides. Receives the matching events in arrival order.
        case custom(@Sendable ([StoredEvent]) -> [StoredEvent])
    }

    /// An event the relay accepted, kept with its original JSON so it can be
    /// echoed back byte-for-byte rather than re-serialised.
    struct StoredEvent {
        let id: String
        let pubkey: String
        let createdAt: UInt64
        let kind: UInt64
        let tags: [[String]]
        /// The event object exactly as received.
        let object: [String: Any]
    }

    /// NIP-01 subscription filter, limited to the fields clients send in
    /// practice. An absent field matches everything, per the spec.
    struct RequestFilter {
        var ids: Set<String>?
        var authors: Set<String>?
        var kinds: Set<UInt64>?
        var since: UInt64?
        var until: UInt64?
        var limit: Int?
        /// Single-letter tag queries (`#e`, `#p`, …) keyed without the `#`.
        var tagQueries: [String: Set<String>] = [:]

        init(json: [String: Any]) {
            ids = (json["ids"] as? [String]).map(Set.init)
            authors = (json["authors"] as? [String]).map(Set.init)
            kinds = (json["kinds"] as? [NSNumber]).map { Set($0.map(\.uint64Value)) }
            since = (json["since"] as? NSNumber)?.uint64Value
            until = (json["until"] as? NSNumber)?.uint64Value
            limit = (json["limit"] as? NSNumber)?.intValue
            for (key, value) in json where key.hasPrefix("#") {
                if let values = value as? [String] {
                    tagQueries[String(key.dropFirst())] = Set(values)
                }
            }
        }

        func matches(_ event: StoredEvent) -> Bool {
            if let ids, !ids.contains(event.id) { return false }
            if let authors, !authors.contains(event.pubkey) { return false }
            if let kinds, !kinds.contains(event.kind) { return false }
            if let since, event.createdAt < since { return false }
            if let until, event.createdAt > until { return false }
            for (name, wanted) in tagQueries {
                let present = event.tags
                    .filter { $0.count >= 2 && $0[0] == name }
                    .map { $0[1] }
                if present.allSatisfy({ !wanted.contains($0) }) { return false }
            }
            return true
        }
    }

    private let server: LoopbackWebSocketServer
    private let lock = NSLock()
    private var events: [StoredEvent] = []
    private var subscriptions: [SubscriptionKey: [RequestFilter]] = [:]
    private var order: ReplayOrder

    private struct SubscriptionKey: Hashable {
        let id: String
        let client: ObjectIdentifier
    }
    private var clientsBySubscription: [SubscriptionKey: LoopbackWebSocketServer.Client] = [:]

    /// A fan-out deferred by `holdLiveDelivery`.
    private struct HeldDelivery {
        let client: LoopbackWebSocketServer.Client
        let subscriptionId: String
        let event: StoredEvent
    }
    private var isHoldingLiveDelivery = false
    private var heldDeliveries: [HeldDelivery] = []

    /// `ws://127.0.0.1:<port>`, once started.
    var url: String? { server.url }

    /// Events the relay has accepted, in publication order.
    var storedEvents: [StoredEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    init(order: ReplayOrder = .asReceived) throws {
        self.order = order
        self.server = try LoopbackWebSocketServer()
        server.onText = { [weak self] inbound in
            self?.handle(text: inbound.text, from: inbound.client)
        }
    }

    func start() throws {
        try server.start()
    }

    func stop() {
        server.stop()
    }

    /// Change the replay order mid-run, so one test can seed events benignly
    /// and then force an adverse replay for a second subscriber.
    func setReplayOrder(_ newOrder: ReplayOrder) {
        lock.lock(); defer { lock.unlock() }
        order = newOrder
    }

    // MARK: - Live delivery control

    /// Stop delivering to open subscriptions, queueing instead.
    ///
    /// This is how the v1.11.2 failure is reproduced. That bug was not about
    /// backlog replay alone: NIP-01 gives no ordering guarantee and several
    /// relays fan into one subscription, so either can hand a client a commit
    /// ahead of the commit it builds on — to a *live* subscriber, with no
    /// reconnect involved. Holding delivery and releasing in a chosen order
    /// reproduces that directly, without needing to restart a client or
    /// resume its account.
    ///
    /// Publishers still get their `OK`, so the sender cannot tell.
    func holdLiveDelivery() {
        lock.lock(); defer { lock.unlock() }
        isHoldingLiveDelivery = true
    }

    /// Deliver everything queued since `holdLiveDelivery`, in `order`, and
    /// resume immediate delivery.
    func releaseLiveDelivery(order releaseOrder: ReplayOrder = .asReceived) {
        lock.lock()
        isHoldingLiveDelivery = false
        let queued = heldDeliveries
        heldDeliveries = []
        let ordered = apply(order: releaseOrder, to: queued.map(\.event))
        // Re-pair the reordered events with their destinations. Identity is by
        // event id plus subscription, since one event can be held for several
        // subscriptions.
        var pending: [(LoopbackWebSocketServer.Client, String, StoredEvent)] = []
        for event in ordered {
            for held in queued where held.event.id == event.id {
                pending.append((held.client, held.subscriptionId, held.event))
            }
        }
        lock.unlock()

        // Outside the lock: sending re-enters the socket layer.
        for (client, subId, event) in pending {
            send(event: event, subscriptionId: subId, to: client)
        }
    }

    /// Number of deliveries currently held back.
    var heldDeliveryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return heldDeliveries.count
    }

    // MARK: - Message handling

    private func handle(text: String, from client: LoopbackWebSocketServer.Client) {
        guard
            let data = text.data(using: .utf8),
            let message = try? JSONSerialization.jsonObject(with: data) as? [Any],
            let verb = message.first as? String
        else { return }

        switch verb {
        case "EVENT":
            guard let object = message.dropFirst().first as? [String: Any] else { return }
            accept(object, from: client)
        case "REQ":
            guard let subId = message.dropFirst().first as? String else { return }
            let filters = message.dropFirst(2).compactMap { $0 as? [String: Any] }.map(RequestFilter.init)
            // A REQ with no filter matches everything, per NIP-01.
            open(subscription: subId, filters: filters.isEmpty ? [RequestFilter(json: [:])] : filters, for: client)
        case "CLOSE":
            guard let subId = message.dropFirst().first as? String else { return }
            close(subscription: subId, for: client)
        default:
            break
        }
    }

    private func accept(_ object: [String: Any], from client: LoopbackWebSocketServer.Client) {
        guard let id = object["id"] as? String else { return }
        let event = StoredEvent(
            id: id,
            pubkey: object["pubkey"] as? String ?? "",
            createdAt: (object["created_at"] as? NSNumber)?.uint64Value ?? 0,
            kind: (object["kind"] as? NSNumber)?.uint64Value ?? 0,
            tags: object["tags"] as? [[String]] ?? [],
            object: object
        )

        lock.lock()
        events.append(event)
        // Snapshot the subscribers that want this event while holding the
        // lock, then send outside it — sending re-enters the socket layer and
        // holding a lock across that invites deadlock.
        let targets = subscriptions.compactMap { key, filters -> (LoopbackWebSocketServer.Client, String)? in
            guard filters.contains(where: { $0.matches(event) }),
                  let client = clientsBySubscription[key] else { return nil }
            return (client, key.id)
        }
        let holding = isHoldingLiveDelivery
        if holding {
            heldDeliveries.append(contentsOf: targets.map {
                HeldDelivery(client: $0.0, subscriptionId: $0.1, event: event)
            })
        }
        lock.unlock()

        // The publisher is acknowledged either way: a relay that reorders
        // delivery to other subscribers still accepts the write, so the sender
        // has no way to detect it.
        client.send(encode(["OK", id, true, ""]))
        guard !holding else { return }
        for (target, subId) in targets {
            send(event: event, subscriptionId: subId, to: target)
        }
    }

    private func open(
        subscription subId: String,
        filters: [RequestFilter],
        for client: LoopbackWebSocketServer.Client
    ) {
        let key = SubscriptionKey(id: subId, client: ObjectIdentifier(client))

        lock.lock()
        subscriptions[key] = filters
        clientsBySubscription[key] = client
        let matching = events.filter { event in filters.contains { $0.matches(event) } }
        let ordered = apply(order: order, to: matching)
        // NIP-01 limit applies to the stored-event replay only.
        let limit = filters.compactMap(\.limit).min()
        let replay = limit.map { Array(ordered.prefix($0)) } ?? ordered
        lock.unlock()

        for event in replay {
            send(event: event, subscriptionId: subId, to: client)
        }
        client.send(encode(["EOSE", subId]))
    }

    private func close(subscription subId: String, for client: LoopbackWebSocketServer.Client) {
        let key = SubscriptionKey(id: subId, client: ObjectIdentifier(client))
        lock.lock(); defer { lock.unlock() }
        subscriptions[key] = nil
        clientsBySubscription[key] = nil
    }

    private func apply(order: ReplayOrder, to matching: [StoredEvent]) -> [StoredEvent] {
        switch order {
        case .asReceived:
            return matching
        case .reversed:
            return matching.reversed()
        case .createdAtAscending:
            // `created_at` has one-second resolution, so a burst ties on it;
            // arrival index breaks ties rather than leaving it to sort
            // stability, which Swift does not guarantee.
            return matching.enumerated()
                .sorted { lhs, rhs in
                    lhs.element.createdAt == rhs.element.createdAt
                        ? lhs.offset < rhs.offset
                        : lhs.element.createdAt < rhs.element.createdAt
                }
                .map(\.element)
        case .custom(let reorder):
            return reorder(matching)
        }
    }

    private func send(
        event: StoredEvent,
        subscriptionId: String,
        to client: LoopbackWebSocketServer.Client
    ) {
        client.send(encode(["EVENT", subscriptionId, event.object]))
    }

    private func encode(_ message: [Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: message),
            let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }
}
