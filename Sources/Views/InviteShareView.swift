import SwiftUI
import FindMyFamCore

/// Sheet showing sharing options for a group invite.
struct InviteShareView: View {
    let inviteCode: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appViewModel: AppViewModel
    @State private var copied = false
    @State private var showNearbyShare = false

    /// The `famstr://` URL for this invite (preferred share target).
    private var inviteURL: URL? { try? InviteCode.decode(from: inviteCode).asURL() }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Share this invite with a family member.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                // QR encodes the deep-link URL so scanning opens the app directly
                QRCodeView(content: inviteURL?.absoluteString ?? inviteCode)
                    .frame(width: 200, height: 200)
                    .padding()

                // Share Nearby — phone-to-phone via MultipeerConnectivity
                Button {
                    showNearbyShare = true
                } label: {
                    Label("Share Nearby", systemImage: "wave.3.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40)

                // Share via AirDrop / Messages / etc. — shares the famstr:// URL
                if let url = inviteURL {
                    ShareLink(item: url) {
                        Label("Share via AirDrop / Messages…", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, 40)
                }

                // Copy raw code as fallback
                Button {
                    UIPasteboard.general.string = inviteCode
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Label(copied ? "Copied!" : "Copy Code (Legacy)", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 40)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Invite Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showNearbyShare) {
                NearbyShareView(
                    role: .advertiser(inviteCode: inviteURL?.absoluteString ?? inviteCode),
                    displayName: appViewModel.settings.displayName.isEmpty ? UIDevice.current.name : appViewModel.settings.displayName,
                    onApprovalReceived: { urlString in
                        // Invitee's npub arrived through the MPC session —
                        // auto-approve since admin physically initiated the
                        // NearbyShare invite (proximity = consent). Uses extra
                        // retries because the invitee's key package publish is
                        // deferred until after MPC tears down.
                        if let url = URL(string: urlString) {
                            appViewModel.approveViaNearbyShare(url)
                        }
                    }
                )
            }
        }
    }
}
