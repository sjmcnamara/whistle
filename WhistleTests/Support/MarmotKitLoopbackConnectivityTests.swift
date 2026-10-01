import XCTest
@testable import Whistle

/// Proves MarmotKit's own client can reach a relay we control.
///
/// `LoopbackWebSocketServerTests` established that an `NWListener` server is
/// reachable in-process — but with `URLSessionWebSocketTask` as the client.
/// MarmotKit dials from Rust, through a different WebSocket implementation,
/// and only when `RelayPolicyFfi.allowLoopback` permits a loopback endpoint.
/// Either could refuse, and the whole ordering harness depends on neither
/// doing so, which is why this is tested before any NIP-01 semantics are
/// built on top.
///
/// Scope is deliberately narrow: that a connection is accepted and MarmotKit
/// speaks first. Whether it gets a *useful* answer needs the relay to actually
/// implement NIP-01, which is the next layer.
final class MarmotKitLoopbackConnectivityTests: XCTestCase {

    /// Carries a result out of a Task that is never awaited, so a failing
    /// assertion can report why MarmotKit went quiet.
    private final class Outcome: @unchecked Sendable {
        var value: String?
    }

    private var server: LoopbackWebSocketServer!
    private var rootPath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = try LoopbackWebSocketServer()
        try server.start()
        rootPath = NSTemporaryDirectory()
            .appending("marmotkit-loopback-\(UUID().uuidString)")
    }

    override func tearDown() {
        server?.stop()
        server = nil
        if let rootPath { try? FileManager.default.removeItem(atPath: rootPath) }
        rootPath = nil
        super.tearDown()
    }

    @MainActor
    func testMarmotKitDialsTheLoopbackRelayAndSpeaksFirst() async throws {
        let relayUrl = try XCTUnwrap(server.url)

        let sawConnection = expectation(description: "relay accepted a MarmotKit connection")
        sawConnection.assertForOverFulfill = false
        server.onConnectionState = { event in
            if event == "ready" { sawConnection.fulfill() }
        }

        let sawFrame = expectation(description: "MarmotKit sent a frame")
        sawFrame.assertForOverFulfill = false
        var firstFrame: String?
        server.onText = { inbound in
            if firstFrame == nil { firstFrame = inbound.text }
            sawFrame.fulfill()
        }

        let service = try MarmotKitService(
            rootPath: rootPath,
            relayUrls: [relayUrl],
            allowLoopback: true,
            secretStore: InMemorySecretStore()
        )

        // Not awaited: this relay answers nothing yet, so identity creation
        // cannot complete, and awaiting it would just hang. But its outcome is
        // captured rather than discarded — if MarmotKit fails before it ever
        // reaches the network (a refused loopback endpoint, an unavailable
        // keystore) that error is the entire explanation for an empty relay,
        // and `try?` would throw it away.
        let outcome = Outcome()
        let work = Task {
            do {
                outcome.value = "returned: " + (try await service.startWithNewIdentity())
            } catch {
                outcome.value = "threw: \(error)"
            }
        }
        defer { work.cancel() }

        await fulfillment(of: [sawConnection, sawFrame], timeout: 20)

        XCTAssertGreaterThan(
            server.acceptedCount, 0,
            "MarmotKit never dialled the relay. startWithNewIdentity: \(outcome.value ?? "still in flight")"
        )
        let frame = try XCTUnwrap(firstFrame)
        // NIP-01 clients open with a JSON array — REQ to subscribe or EVENT to
        // publish. Asserting the shape rather than a specific verb keeps this
        // about connectivity instead of pinning MarmotKit's startup order.
        XCTAssertTrue(
            frame.hasPrefix("["),
            "expected a NIP-01 JSON array frame, got: \(frame.prefix(120))"
        )
    }
}
