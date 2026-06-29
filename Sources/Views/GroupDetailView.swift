import SwiftUI
import PhotosUI

/// Group management — a WhatsApp-style hero header (icon + name + rename) over
/// Settings-style grouped sections: pending joiners, invite actions, members
/// (preview + "See all" for large groups), and leave.
struct GroupDetailView: View {
    // Owned via @StateObject so it survives parent re-renders. The parent row's
    // body re-evaluates whenever marmot.groups changes (e.g. after an add), and
    // an @ObservedObject created in that body would be swapped for a fresh blank
    // instance mid-view — leaving the detail screen unpopulated after "Add all".
    @StateObject private var viewModel: GroupDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showInvite = false
    @State private var showLeaveConfirmation = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var pickedAvatar: PhotosPickerItem?
    @ObservedObject private var avatars = LocalGroupAvatarStore.shared

    /// Show members inline up to this many; beyond it, preview + "See all".
    private let memberPreviewCap = 6

    init(
        groupId: String,
        marmot: MarmotService,
        mls: MLSService,
        nicknameStore: NicknameStore,
        myPubkeyHex: String,
        pendingLeaveStore: PendingLeaveStore
    ) {
        _viewModel = StateObject(wrappedValue: GroupDetailViewModel(
            groupId: groupId,
            marmot: marmot,
            mls: mls,
            nicknameStore: nicknameStore,
            myPubkeyHex: myPubkeyHex,
            pendingLeaveStore: pendingLeaveStore
        ))
    }

    var body: some View {
        List {
            heroSection

            if viewModel.isAdmin && !viewModel.pendingJoiners.isEmpty {
                readyToJoinSection
            }
            if viewModel.isAdmin {
                invitePeopleSection
            }
            membersSection
            leaveSection

            if let error = viewModel.error {
                Section {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .navigationTitle("Group")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .sheet(isPresented: $showInvite) {
            if let code = viewModel.inviteCode {
                InviteShareView(inviteCode: code)
            }
        }
        .onChange(of: viewModel.didRequestLeave) { _, left in
            if left { dismiss() }
        }
        .alert("Rename Group", isPresented: $showRename) {
            TextField("Group name", text: $renameText)
            Button("Save") { Task { await viewModel.renameGroup(to: renameText) } }
            Button("Cancel", role: .cancel) {}
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

    // MARK: - Hero

    private var heroSection: some View {
        Section {
            VStack(spacing: 10) {
                // Tap to set a personal (local, per-device) group photo. Not shared
                // with other members — see LocalGroupAvatarStore.
                PhotosPicker(selection: $pickedAvatar, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        if let img = avatars.image(for: viewModel.groupId) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 80, height: 80)
                                .clipShape(Circle())
                        } else {
                            ZStack {
                                Circle().fill(Color.blue.opacity(0.12)).frame(width: 80, height: 80)
                                Image(systemName: "person.3.fill")
                                    .font(.system(size: 34))
                                    .foregroundStyle(.blue)
                            }
                        }
                        Image(systemName: "camera.circle.fill")
                            .font(.system(size: 24))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .blue)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Set group photo")
                .contextMenu {
                    if avatars.hasImage(for: viewModel.groupId) {
                        Button(role: .destructive) {
                            avatars.removeImage(for: viewModel.groupId)
                        } label: {
                            Label("Remove Photo", systemImage: "trash")
                        }
                    }
                }
                .onChange(of: pickedAvatar) { _, item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            avatars.setImage(data: data, for: viewModel.groupId)
                        }
                        pickedAvatar = nil
                    }
                }

                HStack(spacing: 6) {
                    Text(viewModel.groupName.isEmpty ? "Unnamed Group" : viewModel.groupName)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    if viewModel.isAdmin {
                        Button {
                            renameText = viewModel.groupName
                            showRename = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Rename group")
                    }
                }
                Text("\(viewModel.members.count) member\(viewModel.members.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Ready to Join (pending joiners)

    private var readyToJoinSection: some View {
        Section {
            ForEach(viewModel.pendingJoiners, id: \.pubkey) { joiner in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(joiner.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Anonymous")
                        Text(joiner.pubkey.prefix(16) + "…")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await viewModel.addPendingJoiner(joiner) }
                    } label: {
                        Image(systemName: "person.badge.plus")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.isAddingMember)

                    Button(role: .destructive) {
                        viewModel.dismissPendingJoiner(joiner)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            HStack {
                Text("Ready to Join (\(viewModel.pendingJoiners.count))")
                if viewModel.pendingJoiners.count > 1 {
                    Spacer()
                    Button {
                        Task { await viewModel.addAllPendingJoiners() }
                    } label: {
                        Text("Add all")
                    }
                    .textCase(nil)
                    .disabled(viewModel.isAddingMember)
                }
            }
        }
    }

    // MARK: - Invite People

    private var invitePeopleSection: some View {
        Section("Invite People") {
            Button {
                viewModel.generateInvite()
                showInvite = true
            } label: {
                Label("Invite via QR / Code", systemImage: "qrcode")
            }
            NavigationLink {
                AddByNpubView(viewModel: viewModel)
            } label: {
                Label("Add by npub", systemImage: "character.cursor.ibeam")
            }
        }
    }

    // MARK: - Members

    private var membersSection: some View {
        Section {
            let isLarge = viewModel.members.count > memberPreviewCap
            let shown = isLarge ? Array(viewModel.members.prefix(memberPreviewCap)) : viewModel.members
            ForEach(shown) { member in
                MemberRowView(member: member, viewModel: viewModel, allowManage: !isLarge)
            }
            if isLarge {
                NavigationLink {
                    MembersListView(viewModel: viewModel)
                } label: {
                    Text("See all \(viewModel.members.count) members")
                        .foregroundStyle(.blue)
                }
            }
        } header: {
            Text("Members (\(viewModel.members.count))")
        }
    }

    // MARK: - Leave

    private var leaveSection: some View {
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
    }
}

// MARK: - Member row (shared by the detail preview and the full list)

private struct MemberRowView: View {
    let member: GroupDetailViewModel.MemberItem
    @ObservedObject var viewModel: GroupDetailViewModel
    /// Swipe management is enabled inline only for small groups; large groups
    /// manage from the dedicated "See all" screen.
    var allowManage: Bool = true

    var body: some View {
        HStack {
            Image(systemName: member.isMe ? "person.crop.circle.fill" : "person.circle")
                .foregroundStyle(member.isMe ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(member.displayName).font(.body)
                    if member.isMe {
                        Text("(You)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    if member.isAdmin {
                        Text("Admin").font(.caption).foregroundStyle(.blue)
                    }
                    if viewModel.leaveRequestMembers.contains(member.pubkeyHex) {
                        Label("Wants to leave", systemImage: "arrow.right.circle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if allowManage && viewModel.isAdmin && !member.isMe {
                if viewModel.leaveRequestMembers.contains(member.pubkeyHex) {
                    Button {
                        Task { await viewModel.removeMember(pubkeyHex: member.pubkeyHex) }
                    } label: {
                        Label("Approve", systemImage: "checkmark.circle")
                    }
                    .tint(.green)
                } else {
                    Button(role: .destructive) {
                        Task { await viewModel.removeMember(pubkeyHex: member.pubkeyHex) }
                    } label: {
                        Label("Remove", systemImage: "person.badge.minus")
                    }
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if allowManage && viewModel.isAdmin && !member.isMe && !member.isAdmin {
                Button {
                    Task { await viewModel.promoteToAdmin(pubkeyHex: member.pubkeyHex) }
                } label: {
                    Label("Make Admin", systemImage: "shield.checkered")
                }
                .tint(.orange)
            }
        }
    }
}

// MARK: - Full members list (searchable; reached via "See all")

private struct MembersListView: View {
    @ObservedObject var viewModel: GroupDetailViewModel
    @State private var search = ""

    var body: some View {
        List {
            ForEach(filtered) { member in
                MemberRowView(member: member, viewModel: viewModel, allowManage: true)
            }
        }
        .searchable(text: $search, prompt: "Search members")
        .navigationTitle("Members (\(viewModel.members.count))")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var filtered: [GroupDetailViewModel.MemberItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return viewModel.members }
        return viewModel.members.filter {
            $0.displayName.lowercased().contains(q) || $0.pubkeyHex.lowercased().contains(q)
        }
    }
}

// MARK: - Add by npub (drilled-in; keeps the raw field off the main screen)

private struct AddByNpubView: View {
    @ObservedObject var viewModel: GroupDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showScanner = false

    var body: some View {
        List {
            Section {
                TextField("npub or hex pubkey", text: $viewModel.addMemberNpub)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button {
                    showScanner = true
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                }
            } footer: {
                Text("Ask the person for their npub or scan their QR. They must have opened Whistle at least once so their key package is published.")
            }

            Section {
                Button {
                    Task {
                        await viewModel.addMember()
                        if viewModel.error == nil { dismiss() }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.isAddingMember {
                            ProgressView()
                        } else {
                            Text("Add Member").bold()
                        }
                        Spacer()
                    }
                }
                .disabled(viewModel.addMemberNpub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isAddingMember)
            }

            if let error = viewModel.error {
                Section {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .navigationTitle("Add by npub")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                QRScannerView { scanned in
                    // Accept raw npub or a whistle://addmember/ deep link.
                    if scanned.hasPrefix("npub") {
                        viewModel.addMemberNpub = scanned
                    } else if scanned.contains("addmember/") {
                        let parts = scanned.components(separatedBy: "addmember/")
                        if let tail = parts.last {
                            viewModel.addMemberNpub = tail.components(separatedBy: "/").first ?? tail
                        }
                    } else {
                        viewModel.addMemberNpub = scanned
                    }
                    showScanner = false
                }
            }
        }
    }
}
