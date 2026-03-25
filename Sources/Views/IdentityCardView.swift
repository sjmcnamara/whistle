import SwiftUI

/// Shows the user's npub as a QR code + copyable text.
struct IdentityCardView: View {
    let identity: NostrIdentity
    @State private var copied = false

    var body: some View {
        List {
            Section("Public Key (npub)") {
                QRCodeView(content: identity.npub)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.vertical, 8)

                Button {
                    UIPasteboard.general.string = identity.npub
                    withAnimation(.spring(duration: 0.2)) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(.spring(duration: 0.2)) { copied = false }
                    }
                } label: {
                    HStack(alignment: .top) {
                        Text(identity.npub)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(4)
                        Spacer(minLength: 8)
                        Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                            .foregroundStyle(copied ? .green : .blue)
                    }
                }
                .buttonStyle(.plain)
            }

            Section("About Your Identity") {
                Label {
                    Text("Your npub is your Nostr public key. Share it with family members so they can add you to a group.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.blue)
                }

                Label {
                    Text("Your private key (nsec) is stored in the iOS Keychain. You can export an encrypted backup from Settings \u{2192} Import / Export Key.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Your Identity")
        .navigationBarTitleDisplayMode(.inline)
    }
}
