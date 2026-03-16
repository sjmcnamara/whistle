import SwiftUI

/// Sheet for creating a new group.
struct CreateGroupView: View {
    @ObservedObject var viewModel: GroupListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var groupName = ""
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Group Name", text: $groupName)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("Choose a name for your family group.")
                }

                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Create Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await createGroup() }
                    }
                    .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                }
            }
        }
    }

    private func createGroup() async {
        isCreating = true
        defer { isCreating = false }

        do {
            _ = try await viewModel.createGroup(name: groupName.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
