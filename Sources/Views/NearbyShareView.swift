import SwiftUI
import MultipeerConnectivity

/// Sheet for phone-to-phone invite sharing via MultipeerConnectivity.
///
/// Open in `.advertiser` mode from `InviteShareView` (the inviter's side).
/// Open in `.browser` mode from `JoinGroupView` (the invitee's side).
struct NearbyShareView: View {

    enum Role {
        case advertiser(inviteCode: String)
        case browser

        var title: String {
            switch self {
            case .advertiser: return "Share Nearby"
            case .browser:    return "Join Nearby"
            }
        }
    }

    let role: Role
    /// Invitee side: called with the received invite code.
    /// Join the group inside the closure and return the approval URL to
    /// send back to the admin automatically through the same MPC session.
    var onInviteReceived: ((String) async -> URL?)?
    /// Admin side: called with the raw `famstr://addmember/` URL string
    /// after the invitee has joined and sent their npub back.
    var onApprovalReceived: ((String) -> Void)?

    @StateObject private var coordinator: NearbyShareCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var animating = false

    init(role: Role,
         displayName: String = UIDevice.current.name,
         onInviteReceived: ((String) async -> URL?)? = nil,
         onApprovalReceived: ((String) -> Void)? = nil) {
        self.role = role
        self.onInviteReceived = onInviteReceived
        self.onApprovalReceived = onApprovalReceived
        _coordinator = StateObject(wrappedValue: NearbyShareCoordinator(displayName: displayName))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 36) {
                Spacer()
                radarView
                statusSection
                if case .browser = role {
                    peerListSection
                }
                Spacer()
            }
            .padding()
            .navigationTitle(role.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        coordinator.stop()
                        dismiss()
                    }
                }
            }
            .onAppear {
                animating = true
                coordinator.onInviteReceived = onInviteReceived
                // Wrap the approval callback so this sheet auto-dismisses once
                // the admin has received the invitee's npub.
                let d = dismiss
                coordinator.onApprovalReceived = { url in
                    onApprovalReceived?(url)
                    d()
                }
                switch role {
                case .advertiser(let code): coordinator.startAdvertising(inviteCode: code)
                case .browser:             coordinator.startBrowsing()
                }
            }
            .onDisappear {
                coordinator.stop()
            }
            .onChange(of: coordinator.state) { _, newState in
                // Auto-dismiss the browser (invitee) side after a brief success pause.
                if case .success = newState, case .browser = role {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
                }
            }
        }
    }

    // MARK: - Radar Animation

    private var radarView: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(ringColor.opacity(0.4), lineWidth: 1.5)
                    .frame(width: ringSize(i), height: ringSize(i))
                    .scaleEffect(animating ? 2.2 : 1)
                    .opacity(animating ? 0 : 1)
                    .animation(
                        ringAnimation(delay: Double(i) * 0.55),
                        value: animating
                    )
            }
            // Centre icon
            Image(systemName: centreIcon)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(ringColor)
                .symbolEffect(.pulse, isActive: isPulsing)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 220, height: 220)
    }

    private func ringSize(_ index: Int) -> CGFloat { 60 + CGFloat(index) * 40 }

    private func ringAnimation(delay: Double) -> Animation {
        guard isPulsing else { return .default }
        return .easeOut(duration: 1.6)
            .repeatForever(autoreverses: false)
            .delay(delay)
    }

    private var isPulsing: Bool {
        switch coordinator.state {
        case .advertising, .scanning, .found, .connecting, .joining: return true
        default: return false
        }
    }

    private var ringColor: Color {
        switch coordinator.state {
        case .success:      return .green
        case .failed:       return .red
        default:            return .accentColor
        }
    }

    private var centreIcon: String {
        switch coordinator.state {
        case .success:      return "checkmark.circle.fill"
        case .failed:       return "xmark.circle.fill"
        case .connecting:   return "antenna.radiowaves.left.and.right"
        default:
            switch role {
            case .advertiser: return "wave.3.right"
            case .browser:    return "wave.3.left"
            }
        }
    }

    // MARK: - Status Text

    private var statusSection: some View {
        VStack(spacing: 8) {
            Text(statusTitle)
                .font(.title3.weight(.semibold))
            Text(statusSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusTitle: String {
        switch coordinator.state {
        case .idle:         return "Starting…"
        case .advertising:  return "Ready to Share"
        case .scanning:     return "Looking for Devices…"
        case .found:        return "Device Found"
        case .connecting:   return "Connecting…"
        case .joining:      return "Joining Group…"
        case .success:
            switch role {
            case .advertiser: return "Invite Sent!"
            case .browser:    return "Invite Received!"
            }
        case .failed:       return "Connection Failed"
        }
    }

    private var statusSubtitle: String {
        switch coordinator.state {
        case .idle:         return ""
        case .advertising:  return "Hold your phone close to the family member who's joining."
        case .scanning:     return "Hold your phone close to the group admin's phone."
        case .found:        return "Tap a device below to receive the invite."
        case .connecting:   return "Establishing a secure connection…"
        case .joining:      return "Setting up encryption. This will only take a moment."
        case .success:
            switch role {
            case .advertiser: return "Invite delivered. Waiting for member to join…"
            case .browser:    return "Joining the group now…"
            }
        case .failed(let msg): return msg
        }
    }

    // MARK: - Peer List (browser only)

    @ViewBuilder
    private var peerListSection: some View {
        if !coordinator.nearbyPeers.isEmpty {
            VStack(spacing: 10) {
                ForEach(coordinator.nearbyPeers, id: \.displayName) { peer in
                    Button {
                        coordinator.connect(to: peer)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .foregroundStyle(Color(UIColor.tintColor))
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Admin: \(peer.displayName)")
                                    .fontWeight(.medium)
                                Text("Tap to connect")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(coordinator.state == .connecting || coordinator.state == .success)
                }
            }
            .padding(.horizontal)
        }
    }
}
