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
                if viewModel.groups.isEmpty && viewModel.pendingInviteStore.pendingInvites.isEmpty {
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
            pendingInvitesSection
            ForEach(viewModel.groups) { group in
                NavigationLink {
                    chatDestination(for: group)
                } label: {
                    GroupRowView(
                        group: group,
                        isUnhealthy: viewModel.healthTracker.isUnhealthy(groupId: group.id),
                        isLeaving: viewModel.pendingLeaveStore.contains(group.id)
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
                isUnhealthy: viewModel.healthTracker.isUnhealthy(groupId: group.id)
            )
        } else {
            Text("Marmot service not ready")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)

            Text("No groups yet")
                .font(.headline)

            Text("Create a group to start sharing locations and chatting with your family.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            HStack(spacing: 16) {
                Button {
                    viewModel.showCreateGroup = true
                } label: {
                    Label("Create Group", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.showJoinGroup = true
                } label: {
                    Label("Join Group", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 40)
            .padding(.top, 8)
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
    var isUnhealthy: Bool = false

    @State private var showDetail = false

    var body: some View {
        let chatVM = ChatViewModel(
            groupId: group.id,
            marmot: marmot,
            mls: mls,
            nicknameStore: nicknameStore,
            myPubkeyHex: myPubkeyHex
        )
        let detailVM = GroupDetailViewModel(
            groupId: group.id,
            marmot: marmot,
            mls: mls,
            nicknameStore: nicknameStore,
            myPubkeyHex: myPubkeyHex,
            pendingLeaveStore: pendingLeaveStore
        )

        GroupChatView(
            viewModel: chatVM,
            groupName: group.name,
            onInfoTap: { showDetail = true },
            isUnhealthy: isUnhealthy
        )
        .navigationDestination(isPresented: $showDetail) {
            GroupDetailView(viewModel: detailVM)
        }
    }
}
