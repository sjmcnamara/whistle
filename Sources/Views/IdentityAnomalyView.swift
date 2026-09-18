import SwiftUI

/// Blocking screen shown when `IdentityService` finds existing local group
/// data but no reachable Keychain identity — see
/// `IdentityService.identityAnomalyDetected` for the full explanation. This
/// is deliberately never shown automatically as a path to a fresh identity;
/// it requires an explicit, informed choice.
struct IdentityAnomalyView: View {
    let onRetry: () -> Void
    let onCreateNewAnyway: () -> Void

    @State private var showConfirmation = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.orange)

                Text("Can't Find Your Identity")
                    .font(.title3.weight(.semibold))

                Text("This device already has group data saved, but Whistle can't find the account key that goes with it. This usually resolves itself after an app update — try again first.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                VStack(spacing: 10) {
                    Button {
                        onRetry()
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(role: .destructive) {
                        showConfirmation = true
                    } label: {
                        Text("Create New Identity Anyway")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal, 32)
                .padding(.top, 8)

                Text("Creating a new identity won't erase your existing groups, but you won't be recognized as a member of them anymore.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(24)
        }
        .confirmationDialog(
            "Create a new identity?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Create New Identity", role: .destructive) {
                onCreateNewAnyway()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your existing groups will keep working for their other members, but you'll no longer be recognized as a member of them under this new identity.")
        }
    }
}
