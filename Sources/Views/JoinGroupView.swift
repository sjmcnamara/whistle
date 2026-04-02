import SwiftUI
import WhistleCore

/// Sheet for joining a group via invite code.
/// Accepts a code via: paste, QR scan, nearby share, or deep link pre-fill.
struct JoinGroupView: View {
    @ObservedObject var viewModel: GroupListViewModel
    var initialCode: String?
    /// The current user's pubkey hex — used to build the approval-request URL after joining.
    var myPubkeyHex: String?
    @Environment(\.dismiss) private var dismiss
    @State private var inviteCode = ""
    @State private var isJoining = false
    @State private var error: String?
    @State private var didJoin = false
    @State private var showScanner = false
    @State private var showNearbyShare = false
    @State private var joinedViaNearby = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Invite Code", text: $inviteCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } footer: {
                    Text("Paste a code, scan a QR code, or tap an NFC tag.")
                }

                // Quick-action buttons
                Section {
                    Button {
                        showNearbyShare = true
                    } label: {
                        Label("Join Nearby", systemImage: "wave.3.left.circle.fill")
                    }

                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    }
                }

                if didJoin {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Key package published. Ask the group admin to scan your public key QR or enter your npub to add you.")
                                .font(.caption)
                        }
                    }
                }

                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Join Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if didJoin {
                        Button("Done") { dismiss() }
                    } else {
                        Button("Join") {
                            Task { await joinGroup() }
                        }
                        .disabled(inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isJoining)
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                NavigationStack {
                    QRScannerView { scanned in
                        inviteCode = extractCode(from: scanned)
                        showScanner = false
                        Task { await joinGroup() }
                    }
                    .navigationTitle("Scan QR Code")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .onAppear {
                if let code = initialCode, !code.isEmpty {
                    inviteCode = code
                }
            }
            // Auto-dismiss once the MLS Welcome arrives and the group appears in the list.
            .onChange(of: viewModel.groups) { _, groups in
                guard didJoin else { return }
                let rawCode = extractCode(from: inviteCode)
                guard let groupId = try? InviteCode.decode(from: rawCode).groupId else { return }
                if groups.contains(where: { $0.id == groupId }) {
                    dismiss()
                }
            }
            // Poll for missed gift-wrap events while waiting for the Welcome.
            // Compensates for WebSocket subscription gaps during MPC sessions.
            .task(id: didJoin) {
                guard didJoin else { return }
                let rawCode = extractCode(from: inviteCode)
                guard let expectedGroupId = try? InviteCode.decode(from: rawCode).groupId else { return }

                FMFLogger.marmot.info("⏳ Polling for Welcome to group \(expectedGroupId)...")

                // Poll every 2 seconds for up to 120 seconds.
                for _ in 0..<60 {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }

                    await viewModel.fetchMissedWelcomes()

                    // Check if the Welcome was processed and the group appeared.
                    if viewModel.groups.contains(where: { $0.id == expectedGroupId }) {
                        FMFLogger.marmot.info("🎉 Welcome received! Auto-dismissing.")
                        dismiss()
                        return
                    }
                }
            }
            .sheet(isPresented: $showNearbyShare, onDismiss: {
                if joinedViaNearby && !didJoin {
                    Task {
                        await viewModel.forceReconnectRelays()
                        await joinGroup()
                    }
                }
            }) {
                NearbyShareView(role: .browser, onInviteReceived: { received in
                    let extracted = extractCode(from: received)
                    inviteCode = extracted
                    joinedViaNearby = true

                    do {
                        try await viewModel.joinGroup(inviteCode: extracted)
                        Task { @MainActor in
                            didJoin = true
                            error = nil
                        }
                    } catch {
                        let joinError = error
                        Task { @MainActor in
                            self.error = joinError.localizedDescription
                        }
                        return nil
                    }

                    guard let pubkey = myPubkeyHex,
                          let groupId = try? InviteCode.decode(from: extracted).groupId else {
                        return nil
                    }

                    return InviteCode.approvalURL(pubkeyHex: pubkey, groupId: groupId)
                })
            }
        }
    }

    /// Build the `whistle://addmember/` URL to share with the group admin for one-tap approval.
    private func approvalURL() -> URL? {
        guard let pubkey = myPubkeyHex else { return nil }
        // Decode the group ID from the accepted invite code
        let rawCode = extractCode(from: inviteCode)
        guard let groupId = try? InviteCode.decode(from: rawCode).groupId else { return nil }
        return InviteCode.approvalURL(pubkeyHex: pubkey, groupId: groupId)
    }

        /// Extract the raw base64 invite code from either a `whistle://` URL or a raw string.
    private func extractCode(from scanned: String) -> String {
        guard let url = URL(string: scanned),
                            url.scheme == "whistle",
              url.host == "invite",
              let code = url.pathComponents.dropFirst().first else {
            return scanned
        }
        return code
    }

    private func joinGroup() async {
        let code = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        isJoining = true
        defer { isJoining = false }

        do {
            try await viewModel.joinGroup(inviteCode: code)
            didJoin = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
