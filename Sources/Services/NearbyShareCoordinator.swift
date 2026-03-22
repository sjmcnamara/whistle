import Foundation
import MultipeerConnectivity

/// Coordinates phone-to-phone invite sharing via MultipeerConnectivity.
///
/// **Inviter flow**: call `startAdvertising(inviteCode:)` — the coordinator
/// advertises the device, auto-accepts incoming connections, and immediately
/// sends the invite code to any peer that connects.
///
/// **Invitee flow**: call `startBrowsing()` — the coordinator scans for nearby
/// advertisers. When a peer appears, call `connect(to:)` to initiate the
/// handshake. On success, `onInviteReceived` is called with the code.
@MainActor
final class NearbyShareCoordinator: NSObject, ObservableObject {

    // MARK: - State

    enum ConnectionState: Equatable {
        case idle
        case advertising    // inviter: waiting for a nearby browser
        case scanning       // invitee: looking for a nearby advertiser
        case found          // invitee: at least one peer is visible
        case connecting     // handshake in progress
        case joining        // invitee: joinGroup() running, approval URL being sent
        case success        // invite code transferred successfully
        case failed(String)
    }

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var nearbyPeers: [MCPeerID] = []

    /// Called on the invitee side when an invite code is received.
    /// The async closure should join the group and return the approval URL
    /// to send back to the admin through the same MPC channel.
    var onInviteReceived: ((String) async -> URL?)?

    /// Called on the admin side when the invitee's approval URL arrives
    /// through the same MPC channel after they have joined.
    var onApprovalReceived: ((String) -> Void)?

    // MARK: - Private

    /// MultipeerConnectivity service type — must be ≤15 chars, lowercase/numbers/hyphens.
    private static let serviceType = "famstr"

    private let myPeerID: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var inviteCodeToSend: String?

    // MARK: - Init

    init(displayName: String = UIDevice.current.name) {
        myPeerID = MCPeerID(displayName: displayName)
        super.init()
    }

    // MARK: - Public API

    /// Start advertising so nearby browsers can find and connect to this device.
    func startAdvertising(inviteCode: String) {
        stop()
        inviteCodeToSend = inviteCode
        session = makeSession()

        let adv = MCNearbyServiceAdvertiser(
            peer: myPeerID,
            discoveryInfo: nil,
            serviceType: Self.serviceType
        )
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv
        state = .advertising
    }

    /// Start browsing for nearby advertisers.
    func startBrowsing() {
        stop()
        session = makeSession()

        let b = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
        state = .scanning
    }

    /// Invite a found peer to connect. Only meaningful in browser mode.
    func connect(to peer: MCPeerID) {
        guard let session else { return }
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 30)
        state = .connecting
    }

    /// Tear down all sessions and reset state.
    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        nearbyPeers = []
        inviteCodeToSend = nil
        state = .idle
    }

    // MARK: - Private helpers

    private func makeSession() -> MCSession {
        let s = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        return s
    }
}

// MARK: - MCSessionDelegate

extension NearbyShareCoordinator: MCSessionDelegate {

    nonisolated func session(_ session: MCSession,
                              peer peerID: MCPeerID,
                              didChange peerState: MCSessionState) {
        Task { @MainActor in
            switch peerState {
            case .connected:
                // Advertiser side: push the invite code to the connected peer immediately.
                if let code = inviteCodeToSend, let data = code.data(using: .utf8) {
                    try? session.send(data, toPeers: [peerID], with: .reliable)
                    // FIX: We do NOT set state = .success here. We wait for the invitee to reply.
                }
            case .connecting:
                state = .connecting
            case .notConnected:
                // Don't clobber a .success state — peer may disconnect after transfer.
                if case .success = state { return }
                if case .connecting = state { state = .failed("Connection lost.") }
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession,
                              didReceive data: Data,
                              fromPeer peerID: MCPeerID) {
        guard let str = String(data: data, encoding: .utf8) else { return }
        Task { @MainActor in
            if str.hasPrefix("famstr://addmember/") {
                // Admin side: invitee's npub returned after joining the group.
                onApprovalReceived?(str)
                // FIX: Admin session is completely successful now
                state = .success 
            } else {
                // Invitee side: invite code received from admin.
                // Join the group and send the approval URL back BEFORE flagging
                // success — this keeps the session alive for the full round-trip.
                state = .joining
                let approvalURL = await onInviteReceived?(str)
                if let url = approvalURL,
                   let responseData = url.absoluteString.data(using: .utf8) {
                    try? session.send(responseData, toPeers: [peerID], with: .reliable)
                }
                state = .success    // triggers auto-dismiss only after send completes
            }
        }
    }

    nonisolated func session(_ session: MCSession,
                              didReceive stream: InputStream,
                              withName streamName: String,
                              fromPeer peerID: MCPeerID) {}

    nonisolated func session(_ session: MCSession,
                              didStartReceivingResourceWithName resourceName: String,
                              fromPeer peerID: MCPeerID,
                              with progress: Progress) {}

    nonisolated func session(_ session: MCSession,
                              didFinishReceivingResourceWithName resourceName: String,
                              fromPeer peerID: MCPeerID,
                              at localURL: URL?,
                              withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension NearbyShareCoordinator: MCNearbyServiceAdvertiserDelegate {

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                 didReceiveInvitationFromPeer peerID: MCPeerID,
                                 withContext context: Data?,
                                 invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            // Auto-accept: the inviter doesn't manually approve each connection.
            invitationHandler(true, session)
            state = .connecting
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                 didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            state = .failed(error.localizedDescription)
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension NearbyShareCoordinator: MCNearbyServiceBrowserDelegate {

    nonisolated func browser(_ browser: MCNearbyServiceBrowser,
                              foundPeer peerID: MCPeerID,
                              withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            if !nearbyPeers.contains(peerID) {
                nearbyPeers.append(peerID)
            }
            if case .scanning = state { state = .found }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser,
                              lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            nearbyPeers.removeAll { $0 == peerID }
            if nearbyPeers.isEmpty, case .found = state { state = .scanning }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser,
                              didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            state = .failed(error.localizedDescription)
        }
    }
}