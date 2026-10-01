import XCTest
@testable import Whistle

/// Proves the transport assumption the whole relay harness rests on: that an
/// `NWListener` WebSocket server inside the test process is reachable from a
/// client in that same process, on loopback, in the simulator.
///
/// Uses `URLSessionWebSocketTask` as the client rather than MarmotKit, so a
/// failure here is unambiguously the server's fault. Whether MarmotKit's own
/// Rust client can reach it is a separate question, tested separately.
final class LoopbackWebSocketServerTests: XCTestCase {

    private var server: LoopbackWebSocketServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = try LoopbackWebSocketServer()
        try server.start()
    }

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    func testBindsToALoopbackPort() throws {
        let port = try XCTUnwrap(server.port)
        XCTAssertGreaterThan(port, 0)
        XCTAssertEqual(server.url, "ws://127.0.0.1:\(port)")
    }

    /// Diagnostic: isolates *where* the transport fails — never accepting a
    /// connection is a different problem from accepting one that then fails
    /// its handshake, and the client-side "network connection was lost" says
    /// nothing about which.
    func testReportsConnectionAcceptanceAndState() async throws {
        let reachedTerminalState = expectation(description: "connection settled")
        reachedTerminalState.assertForOverFulfill = false
        server.onConnectionState = { event in
            if event == "ready" || event.hasPrefix("failed") { reachedTerminalState.fulfill() }
        }

        let url = try XCTUnwrap(URL(string: try XCTUnwrap(server.url)))
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        await fulfillment(of: [reachedTerminalState], timeout: 5)

        XCTAssertGreaterThan(server.acceptedCount, 0, "listener never accepted a connection")
        XCTAssertTrue(
            server.stateLog.contains("ready"),
            "connection never became ready — states: \(server.stateLog), error: \(String(describing: server.lastConnectionError))"
        )
    }

    func testEchoesATextFrameBackToTheClient() async throws {
        server.onText = { inbound in
            inbound.client.send("echo:" + inbound.text)
        }

        let url = try XCTUnwrap(URL(string: try XCTUnwrap(server.url)))
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        try await task.send(.string("hello"))
        let reply = try await task.receive()

        guard case .string(let text) = reply else {
            return XCTFail("expected a text frame, got \(reply)")
        }
        XCTAssertEqual(text, "echo:hello", "server error: \(String(describing: server.lastConnectionError))")
    }

    func testBroadcastReachesAConnectedClient() async throws {
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(server.url)))
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        // Send first so the server has definitely registered this client
        // before the broadcast goes out.
        let registered = expectation(description: "server saw the client")
        server.onText = { _ in registered.fulfill() }
        try await task.send(.string("ping"))
        await fulfillment(of: [registered], timeout: 5)

        server.broadcast("pushed")
        let reply = try await task.receive()

        guard case .string(let text) = reply else {
            return XCTFail("expected a text frame, got \(reply)")
        }
        XCTAssertEqual(text, "pushed")
    }
}
