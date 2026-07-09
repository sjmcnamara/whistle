import SwiftUI

/// Chat thread for a single group — shows messages with a bottom input bar.
struct GroupChatView: View {
    // Owned via @StateObject so a parent body re-render (e.g. marmot.groups
    // changing after an add) doesn't swap in a fresh blank ChatViewModel and
    // reset the thread. See GroupDetailView for the same fix.
    @StateObject private var viewModel: ChatViewModel
    let groupName: String
    let onInfoTap: () -> Void
    var isUnhealthy: Bool = false
    @State private var title: String

    init(
        groupId: String,
        marmot: MarmotService,
        mls: MLSService,
        nicknameStore: NicknameStore,
        myPubkeyHex: String,
        groupName: String,
        onInfoTap: @escaping () -> Void,
        isUnhealthy: Bool = false
    ) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(
            groupId: groupId,
            marmot: marmot,
            mls: mls,
            nicknameStore: nicknameStore,
            myPubkeyHex: myPubkeyHex
        ))
        self.groupName = groupName
        self.onInfoTap = onInfoTap
        self.isUnhealthy = isUnhealthy
        self._title = State(initialValue: groupName)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isUnhealthy {
                epochMismatchBanner
            }
            messageList
            Divider()
            inputBar
        }
        .navigationTitle(" ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button(action: onInfoTap) {
                    VStack(spacing: 2) {
                        Text(groupName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if !viewModel.memberNames.isEmpty {
                            Text(viewModel.memberNames)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens group details")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onInfoTap) {
                    Image(systemName: "info.circle")
                }
            }
        }
        .task {
            await viewModel.loadMessages()
            await viewModel.loadMemberNames()
        }
        .onReceive(viewModel.$memberNames) { _ in
            // React to nickname changes that might update member names
        }
    }

    // MARK: - Message list

    private var epochMismatchBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(bannerMessage)
                .font(.caption)
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            if viewModel.isResyncing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else if !viewModel.resyncDidNotResolve {
                Button("Resync") {
                    Task { await viewModel.resync() }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.white.opacity(0.2), in: Capsule())
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.85))
    }

    private var bannerMessage: String {
        if viewModel.isResyncing {
            return "Resyncing…"
        }
        if viewModel.resyncDidNotResolve {
            return "Still out of sync. Ask a group admin to re-invite you to resync."
        }
        return "Some messages couldn't be decrypted. Tap Resync to catch up."
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if viewModel.hasMore {
                        Button("Load earlier messages") {
                            Task { await viewModel.loadMore() }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                    }

                    ForEach(viewModel.messages) { message in
                        ChatBubbleView(message: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: viewModel.messages.count) {
                if let lastId = viewModel.messages.last?.id {
                    withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("Message…", text: $viewModel.draftText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)

            Button {
                Task { await viewModel.sendMessage() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(viewModel.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSending)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
