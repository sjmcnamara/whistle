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
    @State private var showAvatarOptions = false
    @State private var showAvatarPicker = false
    @ObservedObject private var avatars = LocalGroupAvatarStore.shared
    @EnvironmentObject private var sharedAvatars: SharedGroupAvatarStore
    @EnvironmentObject private var appViewModel: AppViewModel
    @State private var pickingForGroup = false
    @State private var groupPhotoError: String?

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
        .alert(
            "Couldn't set group photo",
            isPresented: Binding(
                get: { groupPhotoError != nil },
                set: { if !$0 { groupPhotoError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { groupPhotoError = nil }
        } message: {
            Text(groupPhotoError ?? "")
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
                // Tap to manage a personal (local, per-device) group photo. Not
                // shared with other members — see LocalGroupAvatarStore.
                //
                // A plain Button rather than a PhotosPicker: inside a List row a
                // PhotosPicker's hit region expanded past the circle and swallowed
                // taps meant for the group name and its rename pencil below,
                // making rename unreachable. The explicit frame and contentShape
                // confine the tap target to the circle itself.
                Button {
                    showAvatarOptions = true
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        if let img = SharedGroupAvatarStore.resolvedImage(
                            for: viewModel.groupId, local: avatars, shared: sharedAvatars
                        ) {
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
                    .frame(width: 80, height: 80)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Group photo")
                .confirmationDialog("Group Photo", isPresented: $showAvatarOptions, titleVisibility: .visible) {
                    if viewModel.isAdmin {
                        Button(sharedAvatars.hasImage(for: viewModel.groupId)
                               ? "Change Group Photo" : "Set Group Photo") {
                            pickingForGroup = true
                            showAvatarPicker = true
                        }
                        if sharedAvatars.hasImage(for: viewModel.groupId) {
                            Button("Remove Group Photo", role: .destructive) {
                                Task { await appViewModel.removeGroupAvatar(groupId: viewModel.groupId) }
                            }
                        }
                    }
                    Button(avatars.hasImage(for: viewModel.groupId)
                           ? "Change My Photo" : "Set My Own Photo") {
                        pickingForGroup = false
                        showAvatarPicker = true
                    }
                    if avatars.hasImage(for: viewModel.groupId) {
                        Button("Remove My Photo", role: .destructive) {
                            avatars.removeImage(for: viewModel.groupId)
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    // Kept short: confirmationDialog is a system action sheet
                    // whose width is not ours to control, so long copy wraps
                    // into a cramped block. The full explanation lives in the
                    // failure alert, which is where it actually matters.
                    Text(viewModel.isAdmin
                         ? "Group photo: sent to everyone. Your own photo: this device only, and takes precedence."
                         : "Your own photo stays on this device and takes precedence over the group's.")
                }
                .photosPicker(isPresented: $showAvatarPicker, selection: $pickedAvatar, matching: .images)
                .onChange(of: pickedAvatar) { _, item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            if pickingForGroup {
                                // Handle the outcome — a silently dropped result
                                // made every failure look like "nothing happened".
                                switch await appViewModel.setGroupAvatar(data: data, groupId: viewModel.groupId) {
                                case .updated:
                                    break
                                case .notAdmin:
                                    groupPhotoError = "Only a group admin can set the group photo."
                                case .couldNotEncode:
                                    groupPhotoError = "Group photos are sent to everyone in the group, so they have to be small. This one couldn't be shrunk enough — try a different image. (Your own photo has no limit, because it never leaves this device.)"
                                }
                            } else {
                                avatars.setImage(data: data, for: viewModel.groupId)
                            }
                        }
                        pickedAvatar = nil
                        pickingForGroup = false
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

    @State private var showResyncConfirm = false

    private var isResyncing: Bool {
        viewModel.resyncingMemberPubkey == member.pubkeyHex
    }

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
                    if isResyncing {
                        Label("Resyncing…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if isResyncing {
                ProgressView().controlSize(.small)
            }
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
            if allowManage && viewModel.isAdmin && !member.isMe {
                Button {
                    showResyncConfirm = true
                } label: {
                    Label("Resync", systemImage: "arrow.triangle.2.circlepath")
                }
                .tint(.indigo)

                if !member.isAdmin {
                    Button {
                        Task { await viewModel.promoteToAdmin(pubkeyHex: member.pubkeyHex) }
                    } label: {
                        Label("Make Admin", systemImage: "shield.checkered")
                    }
                    .tint(.orange)
                }
            }
        }
        .confirmationDialog(
            "Resync \(member.displayName)?",
            isPresented: $showResyncConfirm,
            titleVisibility: .visible
        ) {
            Button("Resync") {
                Task { await viewModel.resyncMember(pubkeyHex: member.pubkeyHex) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("They'll be briefly removed and re-added to rebuild encryption keys. Use this only if messages still can't be decrypted after a normal resync.")
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
