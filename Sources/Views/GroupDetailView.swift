import SwiftUI

/// Group management view — member list, invite generation, and admin actions.
struct GroupDetailView: View {
    @ObservedObject var viewModel: GroupDetailViewModel
    @State private var showInvite = false

    var body: some View {
        List {
            // MARK: - Group info
            Section("Group") {
                HStack {
                    Image(systemName: "person.3.fill")
                        .foregroundStyle(.blue)
                    Text(viewModel.groupName)
                        .font(.headline)
                }
            }

            // MARK: - Members
            Section("Members (\(viewModel.members.count))") {
                ForEach(viewModel.members) { member in
                    memberRow(member)
                }
                .onDelete { offsets in
                    Task { await deleteMember(at: offsets) }
                }
            }

            // MARK: - Actions
            Section {
                Button {
                    viewModel.generateInvite()
                    showInvite = true
                } label: {
                    Label("Invite Member", systemImage: "person.badge.plus")
                }
            }

            if let error = viewModel.error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Group Details")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
        }
        .sheet(isPresented: $showInvite) {
            if let code = viewModel.inviteCode {
                InviteShareView(inviteCode: code)
            }
        }
        .deleteDisabled(!viewModel.isAdmin)
    }

    // MARK: - Member row

    private func memberRow(_ member: GroupDetailViewModel.MemberItem) -> some View {
        HStack {
            Image(systemName: member.isMe ? "person.crop.circle.fill" : "person.circle")
                .foregroundStyle(member.isMe ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(member.displayName)
                        .font(.body)
                    if member.isMe {
                        Text("(You)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if member.isAdmin {
                    Text("Admin")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            Spacer()
        }
    }

    // MARK: - Delete

    private func deleteMember(at offsets: IndexSet) async {
        for index in offsets {
            let member = viewModel.members[index]
            guard !member.isMe else { continue }
            await viewModel.removeMember(pubkeyHex: member.pubkeyHex)
        }
    }
}
