import SwiftUI

/// Chat thread for a single group — shows messages with a bottom input bar.
struct GroupChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    let groupName: String
    let onInfoTap: () -> Void
    @State private var title: String

    init(viewModel: ChatViewModel, groupName: String, onInfoTap: @escaping () -> Void) {
        self.viewModel = viewModel
        self.groupName = groupName
        self.onInfoTap = onInfoTap
        self._title = State(initialValue: groupName)
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            inputBar
        }
        .navigationTitle(" ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(groupName)
                        .font(.headline)
                    if !viewModel.memberNames.isEmpty {
                        Text(viewModel.memberNames)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .multilineTextAlignment(.center)
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
