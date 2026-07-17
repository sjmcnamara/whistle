import SwiftUI

/// Chat tab root — shows the list of groups with Create / Join actions.
struct GroupListView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @ObservedObject var viewModel: GroupListViewModel
    @State private var groupToLeave: GroupListViewModel.GroupListItem?
    @State private var showLeaveAlert = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.groups.isEmpty && viewModel.pendingInviteStore.pendingInvites.isEmpty && appViewModel.pendingWelcomeStore.pendingWelcomes.isEmpty {
                    emptyState
                } else {
                    groupList
                }
            }
            .navigationTitle("Chat")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            viewModel.showCreateGroup = true
                        } label: {
                            Label("Create Group", systemImage: "plus.circle")
                        }
                        Button {
                            viewModel.showJoinGroup = true
                        } label: {
                            Label("Join Group", systemImage: "person.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $viewModel.showCreateGroup) {
                CreateGroupView(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showJoinGroup, onDismiss: {
                viewModel.pendingJoinCode = nil
            }) {
                JoinGroupView(
                    viewModel: viewModel,
                    initialCode: viewModel.pendingJoinCode,
                    myPubkeyHex: appViewModel.myPubkeyHex
                )
            }
            .refreshable {
                await viewModel.refresh()
            }
        }
    }

    // MARK: - Group list

    private var groupList: some View {
        List {
            pendingWelcomesSection
            pendingInvitesSection
            ForEach(viewModel.groups) { group in
                NavigationLink {
                    chatDestination(for: group)
                        .onAppear { viewModel.markAsRead(groupId: group.id) }
                } label: {
                    GroupRowView(
                        group: group,
                        isUnhealthy: viewModel.healthTracker.isUnhealthy(groupId: group.id),
                        isLeaving: viewModel.pendingLeaveStore.contains(group.id),
                        hasAdminAction: viewModel.pendingAdminActionGroupIds.contains(group.id)
                    )
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !viewModel.pendingLeaveStore.contains(group.id) {
                        Button(role: .destructive) {
                            groupToLeave = group
                            showLeaveAlert = true
                        } label: {
                            Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .alert("Leave Group?", isPresented: $showLeaveAlert) {
            Button("Leave", role: .destructive) {
                if let group = groupToLeave {
                    Task { await viewModel.requestLeaveGroup(id: group.id) }
                }
            }
            Button("Cancel", role: .cancel) {
                groupToLeave = nil
            }
        } message: {
            if let group = groupToLeave {
                Text("Leave \"\(group.name)\"? The admin will be notified to remove you.")
            }
        }
    }

    // MARK: - Pending welcomes (consent required)

    @ViewBuilder
    private var pendingWelcomesSection: some View {
        let pending = appViewModel.pendingWelcomeStore.pendingWelcomes
        if !pending.isEmpty {
            Section("Group Invitations") {
                ForEach(pending) { pw in
                    HStack(spacing: 12) {
                        Image(systemName: "person.badge.plus")
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .frame(width: 36)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Group Invitation")
                                .font(.body)
                            Text("From \(appViewModel.nicknameStore.displayName(for: pw.senderPubkeyHex))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            Task {
                                try? await appViewModel.marmot?.declinePendingWelcome(mlsGroupId: pw.mlsGroupId)
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .red.opacity(0.8))
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task {
                                try? await appViewModel.marmot?.approvePendingWelcome(mlsGroupId: pw.mlsGroupId)
                            }
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .green)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Pending invites

    @ViewBuilder
    private var pendingInvitesSection: some View {
        let pending = viewModel.pendingInviteStore.pendingInvites
        if !pending.isEmpty {
            Section {
                ForEach(pending) { invite in
                    HStack(spacing: 12) {
                        Image(systemName: "hourglass")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pending Invite")
                                .font(.body)
                            Text("Waiting for admin to add you")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .opacity(0.7)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            viewModel.pendingInviteStore.remove(groupHint: invite.groupHint)
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                    }
                }
            }
        }
    }

    /// Build the chat view for a selected group.
    @ViewBuilder
    private func chatDestination(for group: GroupListViewModel.GroupListItem) -> some View {
        if let marmot = appViewModel.marmot,
           let myPubkey = appViewModel.myPubkeyHex {
            GroupChatContainer(
                group: group,
                marmot: marmot,
                mls: appViewModel.mls,
                nicknameStore: appViewModel.nicknameStore,
                myPubkeyHex: myPubkey,
                pendingLeaveStore: appViewModel.pendingLeaveStore,
                messageCache: appViewModel.chatMessageCache,
                isUnhealthy: viewModel.healthTracker.isUnhealthy(groupId: group.id)
            )
        } else {
            Text("Marmot service not ready")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No groups yet")
                .font(.title3.weight(.semibold))

            Text("Create a group to start sharing locations\nand chatting with your circle.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Button {
                    viewModel.showCreateGroup = true
                } label: {
                    Label("Create Group", systemImage: "plus.circle.fill")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    viewModel.showJoinGroup = true
                } label: {
                    Label("Join Group", systemImage: "person.badge.plus")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 48)
            .padding(.top, 4)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Chat container (owns chat + detail navigation)

/// Wrapper that holds the ChatViewModel and manages navigation to GroupDetailView.
private struct GroupChatContainer: View {
    let group: GroupListViewModel.GroupListItem
    let marmot: MarmotService
    let mls: MLSService
    let nicknameStore: NicknameStore
    let myPubkeyHex: String
    let pendingLeaveStore: PendingLeaveStore
    let messageCache: ChatMessageCache
    var isUnhealthy: Bool = false

    @State private var showDetail = false

    var body: some View {
        GroupChatView(
            groupId: group.id,
            marmot: marmot,
            mls: mls,
            nicknameStore: nicknameStore,
            myPubkeyHex: myPubkeyHex,
            messageCache: messageCache,
            groupName: group.name,
            onInfoTap: { showDetail = true },
            isUnhealthy: isUnhealthy
        )
        .navigationDestination(isPresented: $showDetail) {
            // GroupDetailView owns its VM via @StateObject, so this re-evaluating
            // body never swaps in a blank instance.
            GroupDetailView(
                groupId: group.id,
                marmot: marmot,
                mls: mls,
                nicknameStore: nicknameStore,
                myPubkeyHex: myPubkeyHex,
                pendingLeaveStore: pendingLeaveStore
            )
        }
    }
}
