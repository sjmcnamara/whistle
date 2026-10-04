import SwiftUI

/// Groups tab root — shows the list of groups with Create / My Code actions.
struct GroupListView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @ObservedObject var viewModel: GroupListViewModel
    @State private var groupToLeave: GroupListViewModel.GroupListItem?
    @State private var showLeaveAlert = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.groups.isEmpty {
                    emptyState
                } else {
                    groupList
                }
            }
            .navigationTitle("Groups")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            viewModel.showCreateGroup = true
                        } label: {
                            Label("Create Group", systemImage: "plus.circle")
                        }
                        // Creating a group needs a published account.
                        // Offering it earlier let the user tap it and get
                        // `OnboardingRequired`, which reads as a broken
                        // button rather than "not ready yet".
                        .disabled(!viewModel.isAccountReady)
                        Button {
                            viewModel.showMyCode = true
                        } label: {
                            Label("Show My Code", systemImage: "qrcode")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $viewModel.showCreateGroup) {
                CreateGroupView(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showMyCode) {
                if let marmot = appViewModel.marmot {
                    MemberCodeView(marmot: marmot)
                }
            }
            .refreshable {
                await viewModel.refresh()
            }
        }
    }

    // MARK: - Group list

    private var groupList: some View {
        List {
            ForEach(viewModel.groups) { group in
                NavigationLink {
                    chatDestination(for: group)
                        .onAppear { viewModel.markAsRead(groupId: group.id) }
                } label: {
                    GroupRowView(group: group)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        groupToLeave = group
                        showLeaveAlert = true
                    } label: {
                        Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
        .listStyle(.plain)
        .alert("Leave Group?", isPresented: $showLeaveAlert) {
            Button("Leave", role: .destructive) {
                if let group = groupToLeave {
                    Task { await viewModel.leaveGroup(id: group.id) }
                }
            }
            Button("Cancel", role: .cancel) {
                groupToLeave = nil
            }
        } message: {
            if let group = groupToLeave {
                Text("Leave \"\(group.name)\"? You'll stop sharing your location and lose access to the chat.")
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
                nicknameStore: appViewModel.nicknameStore,
                myPubkeyHex: myPubkey,
                messageCache: appViewModel.chatMessageCache,
                notices: appViewModel.notices
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

            // No "show my code" button here any more: it vanished the moment
            // the first group arrived, so the action appeared to move. It
            // lives in the toolbar menu, which is present either way, and in
            // Settings → Your ID.
            Text("Create a group, or show your code from the menu above\nso an admin can add you to theirs.")
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
                .disabled(!viewModel.isAccountReady)

                // Says why the button is dim. Without this the empty state
                // looks broken on first launch, while publication is still in
                // flight.
                if !viewModel.isAccountReady {
                    Label("Publishing your account…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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
    let marmot: MarmotKitService
    let nicknameStore: NicknameStore
    let myPubkeyHex: String
    let messageCache: ChatMessageCache
    let notices: NoticeCenter
    var isUnhealthy: Bool = false

    @State private var showDetail = false

    var body: some View {
        GroupChatView(
            groupId: group.id,
            marmot: marmot,
            nicknameStore: nicknameStore,
            myPubkeyHex: myPubkeyHex,
            messageCache: messageCache,
            notices: notices,
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
                nicknameStore: nicknameStore,
                myPubkeyHex: myPubkeyHex,
                notices: notices
            )
        }
    }
}
