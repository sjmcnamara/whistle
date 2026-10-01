import XCTest
@testable import Whistle

/// Exercises the relay's NIP-01 behaviour with a plain WebSocket client, so a
/// failure here is a protocol bug rather than anything to do with MarmotKit.
///
/// The order-control tests matter most: they are what step 3c's reordering
/// case depends on, and a harness that silently replayed in publication order
/// would make that test vacuously pass.
final class LoopbackRelayTests: XCTestCase {

    private var relay: LoopbackRelay!
    private var task: URLSessionWebSocketTask!

    override func tearDown() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        relay?.stop()
        relay = nil
        super.tearDown()
    }

    private func startRelay(order: LoopbackRelay.ReplayOrder = .asReceived) throws {
        relay = try LoopbackRelay(order: order)
        try relay.start()
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(relay.url)))
        task = URLSession.shared.webSocketTask(with: url)
        task.resume()
    }

    /// Minimal valid-looking event. The relay does not verify signatures —
    /// it is a test double, and signing would only couple these tests to a
    /// crypto implementation they are not testing.
    private func event(id: String, kind: UInt64 = 445, createdAt: UInt64, tags: [[String]] = []) -> [String: Any] {
        [
            "id": id,
            "pubkey": "aa".repeated(32),
            "created_at": createdAt,
            "kind": kind,
            "tags": tags,
            "content": "payload-\(id)",
            "sig": "bb".repeated(64)
        ]
    }

    private func send(_ message: [Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        let text = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        try await task.send(.string(text))
    }

    /// Next frame as a decoded JSON array.
    private func receive() async throws -> [Any] {
        let message = try await task.receive()
        guard case .string(let text) = message else {
            throw XCTSkip("expected a text frame, got \(message)")
        }
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(parsed as? [Any])
    }

    /// Publish, then collect the event ids a fresh subscription replays, in
    /// the order they arrive, stopping at EOSE.
    private func replayedIds(afterPublishing ids: [String]) async throws -> [String] {
        for (index, id) in ids.enumerated() {
            try await send(["EVENT", event(id: id, createdAt: 1_700_000_000 + UInt64(index))])
            _ = try await receive()  // OK
        }

        try await send(["REQ", "sub1", ["kinds": [445]]])
        var replayed: [String] = []
        while true {
            let frame = try await receive()
            guard let verb = frame.first as? String else { continue }
            if verb == "EOSE" { break }
            if verb == "EVENT", let object = frame.dropFirst(2).first as? [String: Any],
               let id = object["id"] as? String {
                replayed.append(id)
            }
        }
        return replayed
    }

    // MARK: - Basic protocol

    func testAcknowledgesAPublishedEvent() async throws {
        try startRelay()
        try await send(["EVENT", event(id: "e1", createdAt: 1_700_000_000)])

        let frame = try await receive()
        XCTAssertEqual(frame.first as? String, "OK")
        XCTAssertEqual(frame.dropFirst().first as? String, "e1")
        XCTAssertEqual(frame.dropFirst(2).first as? Bool, true)
        XCTAssertEqual(relay.storedEvents.count, 1)
    }

    func testReplaysStoredEventsThenSendsEose() async throws {
        try startRelay()
        let replayed = try await replayedIds(afterPublishing: ["e1", "e2"])
        XCTAssertEqual(replayed, ["e1", "e2"])
    }

    func testDeliversLiveEventsToAnOpenSubscription() async throws {
        try startRelay()
        try await send(["REQ", "live", ["kinds": [445]]])
        let eose = try await receive()
        XCTAssertEqual(eose.first as? String, "EOSE")

        try await send(["EVENT", event(id: "fresh", createdAt: 1_700_000_100)])

        // OK for the publish and the EVENT fan-out both arrive; order between
        // them is not guaranteed, so accept either sequence.
        var sawEvent = false
        for _ in 0..<2 {
            let frame = try await receive()
            if frame.first as? String == "EVENT",
               let object = frame.dropFirst(2).first as? [String: Any] {
                XCTAssertEqual(object["id"] as? String, "fresh")
                sawEvent = true
            }
        }
        XCTAssertTrue(sawEvent, "open subscription never received the live event")
    }

    func testStopsDeliveringAfterClose() async throws {
        try startRelay()
        try await send(["REQ", "live", ["kinds": [445]]])
        _ = try await receive()  // EOSE
        try await send(["CLOSE", "live"])

        try await send(["EVENT", event(id: "after-close", createdAt: 1_700_000_200)])
        let frame = try await receive()
        // Only the publish acknowledgement should come back.
        XCTAssertEqual(frame.first as? String, "OK")
    }

    // MARK: - Filtering

    func testFiltersByKind() async throws {
        try startRelay()
        try await send(["EVENT", event(id: "group", kind: 445, createdAt: 1)])
        _ = try await receive()
        try await send(["EVENT", event(id: "giftwrap", kind: 1059, createdAt: 2)])
        _ = try await receive()

        try await send(["REQ", "sub", ["kinds": [1059]]])
        let frame = try await receive()
        XCTAssertEqual(frame.first as? String, "EVENT")
        let object = try XCTUnwrap(frame.dropFirst(2).first as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "giftwrap")
        let eose = try await receive()
        XCTAssertEqual(eose.first as? String, "EOSE")
    }

    func testFiltersBySinceTimestamp() async throws {
        try startRelay()
        try await send(["EVENT", event(id: "old", createdAt: 100)])
        _ = try await receive()
        try await send(["EVENT", event(id: "new", createdAt: 500)])
        _ = try await receive()

        try await send(["REQ", "sub", ["since": 200]])
        let frame = try await receive()
        let object = try XCTUnwrap(frame.dropFirst(2).first as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "new")
        let eose = try await receive()
        XCTAssertEqual(eose.first as? String, "EOSE")
    }

    func testFiltersByTagQuery() async throws {
        try startRelay()
        try await send(["EVENT", event(id: "tagged", createdAt: 1, tags: [["e", "target"]])])
        _ = try await receive()
        try await send(["EVENT", event(id: "untagged", createdAt: 2, tags: [["e", "other"]])])
        _ = try await receive()

        try await send(["REQ", "sub", ["#e": ["target"]]])
        let frame = try await receive()
        let object = try XCTUnwrap(frame.dropFirst(2).first as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "tagged")
        let eose = try await receive()
        XCTAssertEqual(eose.first as? String, "EOSE")
    }

    // MARK: - Replay order — the reason this harness exists

    func testReplaysInPublicationOrderByDefault() async throws {
        try startRelay(order: .asReceived)
        let replayed = try await replayedIds(afterPublishing: ["first", "second", "third"])
        XCTAssertEqual(replayed, ["first", "second", "third"])
    }

    /// The adversarial case: a commit arriving before the commit it builds on.
    func testReplaysInReverseOrderWhenAsked() async throws {
        try startRelay(order: .reversed)
        let replayed = try await replayedIds(afterPublishing: ["first", "second", "third"])
        XCTAssertEqual(replayed, ["third", "second", "first"])
    }

    func testReplaysInCallerSuppliedOrder() async throws {
        try startRelay(order: .custom { $0.sorted { $0.id < $1.id } })
        let replayed = try await replayedIds(afterPublishing: ["charlie", "alpha", "bravo"])
        XCTAssertEqual(replayed, ["alpha", "bravo", "charlie"])
    }

    func testCreatedAtAscendingOrdersByTimestampNotArrival() async throws {
        try startRelay(order: .createdAtAscending)
        // Published newest-first, so arrival order and timestamp order differ.
        try await send(["EVENT", event(id: "later", createdAt: 900)])
        _ = try await receive()
        try await send(["EVENT", event(id: "earlier", createdAt: 100)])
        _ = try await receive()

        try await send(["REQ", "sub", ["kinds": [445]]])
        var replayed: [String] = []
        while true {
            let frame = try await receive()
            guard let verb = frame.first as? String else { continue }
            if verb == "EOSE" { break }
            if let object = frame.dropFirst(2).first as? [String: Any],
               let id = object["id"] as? String {
                replayed.append(id)
            }
        }
        XCTAssertEqual(replayed, ["earlier", "later"])
    }
}

private extension String {
    /// Builds filler hex of a given byte length for event fields the relay
    /// never inspects.
    func repeated(_ times: Int) -> String {
        String(repeating: self, count: times)
    }
}
