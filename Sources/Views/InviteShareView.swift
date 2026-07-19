import SwiftUI
import WhistleCore

/// Sheet showing sharing options for a group invite.
struct InviteShareView: View {
    let inviteCode: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    /// The `whistle://` URL for this invite (preferred share target).
    private var inviteURL: URL? { try? InviteCode.decode(from: inviteCode).asURL() }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Share this invite with a family member.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                // QR encodes the raw base64 invite code for cross-platform compatibility
                QRCodeView(content: inviteCode)
                    .frame(width: 200, height: 200)
                    .padding()

                // Share via AirDrop / Messages / etc. — shares the whistle:// URL
                if let url = inviteURL {
                    ShareLink(item: url) {
                        Label("Share via AirDrop / Messages…", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
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
        }
    }
}
