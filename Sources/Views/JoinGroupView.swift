import SwiftUI
import WhistleCore

/// Sheet for joining a group via invite code.
/// Accepts a code via: paste, QR scan, or deep link pre-fill.
struct JoinGroupView: View {
    @ObservedObject var viewModel: GroupListViewModel
    var initialCode: String?
    @Environment(\.dismiss) private var dismiss
    @State private var inviteCode = ""
    @State private var isJoining = false
    @State private var error: String?
    @State private var didJoin = false
    @State private var showScanner = false

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
            // Compensates for WebSocket subscription gaps on any join path.
            .task(id: didJoin) {
                guard didJoin else { return }
                let rawCode = extractCode(from: inviteCode)
                guard let expectedGroupId = try? InviteCode.decode(from: rawCode).groupId else { return }

                WhistleLogger.marmot.info("⏳ Polling for Welcome to group \(expectedGroupId)...")

                // Poll every 2 seconds for up to 120 seconds.
                for _ in 0..<60 {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }

                    await viewModel.fetchMissedWelcomes()

                    // Check if the Welcome was processed and the group appeared.
                    if viewModel.groups.contains(where: { $0.id == expectedGroupId }) {
                        WhistleLogger.marmot.info("🎉 Welcome received! Auto-dismissing.")
                        dismiss()
                        return
                    }
                }
            }
        }
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
