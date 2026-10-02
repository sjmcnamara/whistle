import SwiftUI
import WhistleCore

/// Shows the user's npub as a QR code + copyable text.
struct IdentityCardView: View {
    let identity: NostrIdentity

    /// Whether an admin scanning this code could actually add you.
    ///
    /// The npub is always correct, so the code is always worth showing and
    /// copying — but an invite only succeeds once the KeyPackage has reached a
    /// relay. `MemberCodeView` handles that by hiding the code entirely;
    /// here the caveat is stated instead, because hiding a valid npub is
    /// worse than explaining the one thing it cannot do yet.
    var isReadyToBeInvited: Bool = true

    @State private var copied = false

    var body: some View {
        List {
            if !isReadyToBeInvited {
                Section {
                    Label(
                        "Still publishing your key — an admin can't add you to a group until that finishes.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

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
