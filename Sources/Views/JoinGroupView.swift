import SwiftUI
import CoreNFC

/// Sheet for joining a group via invite code.
/// Accepts a code via: paste, QR scan, NFC tag read, or deep link pre-fill.
struct JoinGroupView: View {
    @ObservedObject var viewModel: GroupListViewModel
    var initialCode: String?
    @Environment(\.dismiss) private var dismiss
    @State private var inviteCode = ""
    @State private var isJoining = false
    @State private var error: String?
    @State private var didJoin = false
    @State private var showScanner = false
    @StateObject private var nfcReader = NFCReadCoordinator()

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

                    // TODO: Restore to NFCNDEFReaderSession.readingAvailable once portal entitlement is approved.
                    if false {
                        Button {
                            nfcReader.start()
                        } label: {
                            Label(nfcReader.isReading ? "Scanning NFC…" : "Tap NFC Tag", systemImage: "wave.3.right")
                        }
                        .disabled(nfcReader.isReading)
                    }
                }

                if didJoin {
                    Section {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Key package published — waiting for the group admin to add you.")
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
                nfcReader.onScan = { scanned in
                    inviteCode = extractCode(from: scanned)
                    Task { await joinGroup() }
                }
            }
        }
    }

    /// Extract the raw base64 invite code from either a `famstr://` URL or a raw string.
    private func extractCode(from scanned: String) -> String {
        guard let url = URL(string: scanned),
              url.scheme == "famstr",
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
