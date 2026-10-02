import SwiftUI
import WhistleCore

/// Admin side of the v2 join flow: scan a member's code and invite them.
///
/// The counterpart to `MemberCodeView`. There is no other direction — with no
/// out-of-group messaging in protocol v2, a non-member has no action available
/// to them, so the v1 flow (admin shares a group QR, prospect acts on it) has
/// no equivalent and no replacement.
struct ScanMemberCodeView: View {
    let groupId: String
    var groupName: String = ""
    @ObservedObject var marmot: MarmotKitService
    @Environment(\.dismiss) private var dismiss

    @State private var state: ScanState = .scanning

    private enum ScanState: Equatable {
        case scanning
        case inviting
        /// Distinct from `.failed` so a mis-scan reads as "wrong code" rather
        /// than "something went wrong" — the remedies differ entirely.
        case notAMemberCode
        case failed(String)
        case invited
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch state {
                case .scanning:
                    scanner
                case .inviting:
                    status(icon: nil, title: "Adding to \(displayName)…", detail: nil)
                case .invited:
                    status(
                        icon: "checkmark.circle.fill",
                        title: "Added to \(displayName)",
                        detail: "They'll see the group once their device catches up.",
                        tint: .green
                    )
                case .notAMemberCode:
                    status(
                        icon: "qrcode.viewfinder",
                        title: "That's not a member code",
                        detail: "Ask them to open Whistle and show their own code, then scan again.",
                        tint: .orange,
                        retry: true
                    )
                case .failed(let message):
                    status(
                        icon: "exclamationmark.triangle.fill",
                        title: "Couldn't add them",
                        detail: message,
                        tint: .orange,
                        retry: true
                    )
                }
            }
            .padding()
            .navigationTitle("Add Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(state == .invited ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
    }

    private var displayName: String {
        groupName.isEmpty ? "the group" : groupName
    }

    private var scanner: some View {
        VStack(spacing: 16) {
            QRScannerView { scanned in
                // The scanner can fire repeatedly for one code; ignore
                // anything that arrives once an invite is already in flight.
                guard state == .scanning else { return }
                Task { await invite(scanned) }
            }
            .frame(maxWidth: .infinity, maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Text("Scan the code from their Whistle app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func status(
        icon: String?,
        title: String,
        detail: String?,
        tint: Color = .secondary,
        retry: Bool = false
    ) -> some View {
        VStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(tint)
            } else {
                ProgressView()
            }
            Text(title).font(.headline)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if retry {
                Button("Scan again") { state = .scanning }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
        .padding(.top, 40)
    }

    private func invite(_ scanned: String) async {
        state = .inviting
        do {
            try await marmot.invite(scannedCode: scanned, toGroup: groupId)
            state = .invited
        } catch MarmotKitService.ServiceError.unrecognisedMemberCode {
            state = .notAMemberCode
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
