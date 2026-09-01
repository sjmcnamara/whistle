import SwiftUI
import WhistleCore

/// Sheet showing sharing options for a group invite.
struct InviteShareView: View {
    let inviteCode: String
    var groupName: String = ""
    var groupAvatar: UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    /// The `whistle://` URL for this invite (preferred share target).
    private var inviteURL: URL? { try? InviteCode.decode(from: inviteCode).asURL() }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                header

                qrCard

                // Icon-only — the OS share sheet's app list is user-customised,
                // so naming specific targets (AirDrop, Messages, …) here would
                // often just be wrong.
                HStack(spacing: 24) {
                    if let url = inviteURL {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title2)
                                .frame(width: 56, height: 56)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Share invite link")
                    }

                    Button {
                        UIPasteboard.general.string = inviteCode
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.title2)
                            .frame(width: 56, height: 56)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(copied ? "Copied" : "Copy invite code")
                }

                Text(copied ? "Copied to clipboard" : " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            if let groupAvatar {
                Image(uiImage: groupAvatar)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
            }
            if !groupName.isEmpty {
                Text(groupName)
                    .font(.headline)
            }
            Text("Share this invite with a group member.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    // MARK: - QR card

    private var qrCard: some View {
        ZStack {
            // QR encodes the raw base64 invite code for cross-platform
            // compatibility. Card background stays a fixed white regardless
            // of app theme — that's what keeps scan contrast high in dark mode.
            QRCodeView(content: inviteCode, hasCenterMark: true)
                .frame(width: 200, height: 200)

            Image("InviteQRMark")
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(4)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .padding(.horizontal, 32)
    }
}
