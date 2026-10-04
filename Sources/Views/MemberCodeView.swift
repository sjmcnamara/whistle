import SwiftUI
import WhistleCore

/// The code a prospective member shows so an admin can add them.
///
/// This replaces the v1 invite flow rather than mirroring it. Protocol v2 has
/// no out-of-group messaging, so a non-member cannot act on anything they
/// scan — which makes the old admin-shows-a-group-QR direction useless rather
/// than merely different. Only this direction survives: the member displays,
/// the admin scans (`ScanMemberCodeView`).
///
/// Nothing here is group-specific. The same code works for any group, because
/// what it identifies is the person, not an invitation.
struct MemberCodeView: View {
    @ObservedObject var marmot: MarmotKitService
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    /// Gates the code on account setup reaching `.networkReady`.
    ///
    /// Showing it earlier produces a code an admin *cannot* invite: the
    /// KeyPackage has not reached a relay yet, so the invite fails on their
    /// side with no indication that the cause was timing. The two-device
    /// tests only worked once publication had completed, and without this
    /// gate the failure reads as a broken scanner.
    @State private var isReady = false
    @State private var code: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                header

                if let code, isReady {
                    qrCard(for: code)
                    copyButton(for: code)
                } else {
                    notReadyYet
                }

                Spacer()
            }
            .padding(.top)
            .navigationTitle("My Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await waitUntilReady() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        Text("Show this to a group admin. They'll scan it to add you.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
    }

    private func qrCard(for code: String) -> some View {
        // Fixed white card regardless of app theme — that is what keeps scan
        // contrast high in dark mode.
        QRCodeView(content: code, hasCenterMark: false)
            .frame(width: 220, height: 220)
            .padding(20)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            .padding(.horizontal, 32)
    }

    private func copyButton(for code: String) -> some View {
        VStack(spacing: 8) {
            Button {
                UIPasteboard.general.string = code
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.title2)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel(copied ? "Copied" : "Copy my code")

            // Shown so a member can send it in a message when scanning is
            // impractical — an npub is portable, which is why the code is
            // npub rather than raw hex.
            Text(copied ? "Copied to clipboard" : code)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 32)
        }
    }

    private var notReadyYet: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Publishing your key…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Your code isn't ready to scan yet. This usually takes a moment.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 40)
    }

    // MARK: - Readiness

    /// Polls rather than observing, because readiness advances inside
    /// MarmotKit's runtime and is not published to the app.
    /// Polls without a deadline, for as long as the screen is open.
    ///
    /// The earlier version gave up after 30 seconds, which on device was
    /// shorter than real setup takes — leaving "Publishing your key…" on
    /// screen permanently even once the account had published. A `.task` is
    /// cancelled when the view goes away, so the loop needs no bound of its
    /// own.
    private func waitUntilReady() async {
        code = marmot.myMemberCode()
        while !Task.isCancelled {
            if marmot.isReadyToBeInvited() {
                isReady = true
                code = marmot.myMemberCode()
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
