import SwiftUI

/// Sheet for joining a group via invite code.
struct JoinGroupView: View {
    @ObservedObject var viewModel: GroupListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var inviteCode = ""
    @State private var isJoining = false
    @State private var error: String?
    @State private var didJoin = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Invite Code", text: $inviteCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } footer: {
                    Text("Paste the invite code shared by a group member.")
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
        }
    }

    private func joinGroup() async {
        isJoining = true
        defer { isJoining = false }

        do {
            try await viewModel.joinGroup(inviteCode: inviteCode.trimmingCharacters(in: .whitespacesAndNewlines))
            didJoin = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
