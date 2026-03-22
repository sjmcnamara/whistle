import SwiftUI

/// Group management view — member list, invite generation, rename, and leave.
struct GroupDetailView: View {
    @ObservedObject var viewModel: GroupDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showInvite = false
    @State private var editingName = ""
    @State private var showLeaveConfirmation = false

    var body: some View {
        List {
            // MARK: - Group info (editable for admins)
            Section("Group") {
                if viewModel.isAdmin {
                    HStack {
                        Image(systemName: "person.3.fill")
                            .foregroundStyle(.blue)
                        TextField("Group Name", text: $editingName)
                            .font(.headline)
                            .onSubmit {
                                Task { await viewModel.renameGroup(to: editingName) }
                            }
                    }
                } else {
                    HStack {
                        Image(systemName: "person.3.fill")
                            .foregroundStyle(.blue)
                        Text(viewModel.groupName)
                            .font(.headline)
                    }
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

            // MARK: - Invite
            if viewModel.isAdmin {
                Section {
                    Button {
                        viewModel.generateInvite()
                        showInvite = true
                    } label: {
                        Label("Invite Member", systemImage: "person.badge.plus")
                    }
                }
            }

            // MARK: - Add member
            if viewModel.isAdmin {
                Section("Add Member") {
                    TextField("npub or hex pubkey", text: $viewModel.addMemberNpub)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await viewModel.addMember() }
                    } label: {
                        if viewModel.isAddingMember {
                            ProgressView()
                        } else {
                            Text("Add Member")
                        }
                    }
                    .disabled(viewModel.addMemberNpub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isAddingMember)
                }
            }

            // MARK: - Leave group
            Section {
                if viewModel.pendingLeaveStore.contains(viewModel.groupId) {
                    HStack {
                        Spacer()
                        Label("Leave Requested", systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    Button(role: .destructive) {
                        showLeaveConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            if viewModel.isLeaving {
                                ProgressView()
                            } else {
                                Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                            Spacer()
                        }
                    }
                    .disabled(viewModel.isLeaving)
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
            editingName = viewModel.groupName
        }
        .sheet(isPresented: $showInvite) {
            if let code = viewModel.inviteCode {
                InviteShareView(inviteCode: code)
            }
        }
        .deleteDisabled(!viewModel.isAdmin)
        .onChange(of: viewModel.didAddMember) { _, added in
            if added { dismiss() }
        }
        .onChange(of: viewModel.didRequestLeave) { _, left in
            if left { dismiss() }
        }
        .onChange(of: viewModel.groupName) { _, newName in
            editingName = newName
        }
        .alert("Leave Group?", isPresented: $showLeaveConfirmation) {
            Button("Leave", role: .destructive) {
                Task { await viewModel.requestLeave() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The admin will be notified to remove you. You'll stop receiving updates once confirmed.")
        }
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
                HStack(spacing: 6) {
                    if member.isAdmin {
                        Text("Admin")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    if viewModel.leaveRequestMembers.contains(member.pubkeyHex) {
                        if viewModel.isAdmin {
                            Button {
                                Task { await viewModel.removeMember(pubkeyHex: member.pubkeyHex) }
                            } label: {
                                Text("Confirm Leave")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            Text("Wants to leave")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
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
