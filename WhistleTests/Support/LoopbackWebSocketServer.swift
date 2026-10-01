import Foundation
import Network

/// A minimal WebSocket server bound to loopback, for tests.
///
/// Deliberately protocol-agnostic: it moves text frames and nothing else. The
/// NIP-01 relay semantics sit on top of this (see `LoopbackRelay`), so a
/// failure here is a transport failure and a failure there is a protocol one.
/// That separation matters because the whole harness rests on an unproven
/// assumption — that a Rust WebSocket client inside the simulator can reach an
/// `NWListener` in the same process.
///
/// Why a server at all: MarmotKit exposes no injectable transport (its entire
/// FFI surface has exactly two callback interfaces, neither of them a
/// transport), so the only way to control what a `Marmot` instance receives,
/// and in what order, is to be the relay it talks to. Upstream sanctions this
/// — `RelayPolicyFfi.allowLoopback` is an explicit development opt-in for
/// loopback relay endpoints.
final class LoopbackWebSocketServer {

    /// Text frame received from a client, with a reply handle for that client.
    struct Inbound {
        let text: String
        let client: Client
    }

    /// One connected client. Reply with `send`.
    final class Client {
        private let connection: NWConnection
        private let queue: DispatchQueue

        init(connection: NWConnection, queue: DispatchQueue) {
            self.connection = connection
            self.queue = queue
        }

        func send(_ text: String) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
            connection.send(
                content: Data(text.utf8),
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { _ in }
            )
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackWebSocketServer")
    private var clients: [Client] = []

    /// Called for every inbound text frame, on the server's own queue.
    var onText: ((Inbound) -> Void)?

    /// Port the listener actually bound to, once started.
    private(set) var port: UInt16?

    /// Last error a client connection reported — surfaced so a failing test
    /// can say *why* the transport broke instead of only that it did.
    private(set) var lastConnectionError: Error?

    /// Diagnostics: how many connections the listener accepted, and the state
    /// transitions each went through. Without these a handshake failure is
    /// indistinguishable from never accepting the connection at all.
    private(set) var acceptedCount = 0
    private(set) var stateLog: [String] = []
    /// Fired on every accepted connection state change, for test waiting.
    var onConnectionState: ((String) -> Void)?

    /// `ws://127.0.0.1:<port>` — what to hand a client as a relay URL.
    var url: String? {
        port.map { "ws://127.0.0.1:\($0)" }
    }

    init() throws {
        let parameters = NWParameters.tcp
        // Repeated test runs bind and unbind in quick succession; without this
        // a port in TIME_WAIT fails the next bind.
        parameters.allowLocalEndpointReuse = true
        // Deliberately NOT `acceptLocalOnly`: that restricts inbound
        // connections to the local *link*, which loopback traffic does not
        // qualify as, so the listener binds and reports .ready but its
        // newConnectionHandler never fires and the client only sees a bare
        // "network connection was lost".
        let websocket = NWProtocolWebSocket.Options(.version13)
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        // Port .any lets the OS pick a free one, so concurrent tests never
        // collide on a hardcoded port.
        listener = try NWListener(using: parameters, on: .any)
    }

    /// Start listening and wait until the port is known.
    func start(timeout: TimeInterval = 5) throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            self?.port = self?.listener.port?.rawValue
            ready.signal()
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + timeout) == .success else {
            throw Failure.didNotBind
        }
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
    }

    /// Send a text frame to every connected client.
    func broadcast(_ text: String) {
        queue.async { [weak self] in
            self?.clients.forEach { $0.send(text) }
        }
    }

    // MARK: - Private

    /// Accept a connection, but only start reading once it reports `.ready`.
    ///
    /// Reading before the WebSocket handshake completes drops the connection
    /// with a bare "network connection was lost" on the client and no
    /// explanation on the server, so connection state is observed rather than
    /// assumed. `newConnectionHandler` already runs on `queue`, so touching
    /// `clients` here needs no further hop.
    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection, queue: queue)
        clients.append(client)
        acceptedCount += 1
        note("accepted")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.note("ready")
                self.receive(on: connection, client: client)
            case .failed(let error):
                self.lastConnectionError = error
                self.note("failed: \(error)")
            case .waiting(let error):
                self.lastConnectionError = error
                self.note("waiting: \(error)")
            case .preparing:
                self.note("preparing")
            case .setup:
                self.note("setup")
            case .cancelled:
                self.note("cancelled")
            @unknown default:
                self.note("unknown")
            }
        }
        connection.start(queue: queue)
    }

    private func note(_ event: String) {
        stateLog.append(event)
        onConnectionState?(event)
    }

    private func receive(on connection: NWConnection, client: Client) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }

            if let data, !data.isEmpty,
               let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                   as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .text,
               let text = String(data: data, encoding: .utf8) {
                self.onText?(Inbound(text: text, client: client))
            }

            if error == nil {
                // Keep reading until the peer closes or errors; a single
                // receiveMessage only yields one frame.
                self.receive(on: connection, client: client)
            }
        }
    }

    enum Failure: Error {
        case didNotBind
    }
}
