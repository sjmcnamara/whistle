import SwiftUI

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
    @State private var copiedGroupId = false
    @ObservedObject private var avatars = LocalGroupAvatarStore.shared
    @EnvironmentObject private var sharedAvatars: SharedGroupAvatarStore
    @EnvironmentObject private var appViewModel: AppViewModel

    /// Show members inline up to this many; beyond it, preview + "See all".
    private let memberPreviewCap = 6

    init(
        groupId: String,
        marmot: MarmotService,
        mls: MLSService,
        nicknameStore: NicknameStore,
        myPubkeyHex: String
    ) {
        _viewModel = StateObject(wrappedValue: GroupDetailViewModel(
            groupId: groupId,
            marmot: marmot,
            mls: mls,
            nicknameStore: nicknameStore,
            myPubkeyHex: myPubkeyHex
        ))
    }

    var body: some View {
        List {
            heroSection

            // Not gated on `viewModel.isAdmin` — see the comment on
            // `MemberRowView`'s swipe actions below for why: that check reads
            // a cached admin list that can diverge from live MLS truth, and
            // hiding these sections would make it impossible to ever recover
            // from that state through the UI. The underlying calls fail
            // safely via MDK's own enforcement for a genuine non-admin.
            if !viewModel.pendingJoiners.isEmpty {
                readyToJoinSection
            }
            invitePeopleSection
            membersSection
            locationSharingSection
            leaveSection

            if let error = viewModel.error {
                Section {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
        }
        .task { await viewModel.load() }
        .sheet(isPresented: $showInvite) {
            if let code = viewModel.inviteCode {
                InviteShareView(
                    inviteCode: code,
                    groupName: viewModel.groupName,
                    groupAvatar: SharedGroupAvatarStore.resolvedImage(
                        for: viewModel.groupId, local: avatars, shared: sharedAvatars
                    )
                )
            }
        }
        .onChange(of: viewModel.didLeave) { _, left in
            if left { dismiss() }
        }
        .alert("Rename Group", isPresented: $showRename) {
            TextField("Group name", text: $renameText)
            Button("Save") { Task { await viewModel.renameGroup(to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Leave Group?", isPresented: $showLeaveConfirmation) {
            Button("Leave", role: .destructive) {
                Task { await viewModel.leaveGroup() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll stop sharing your location and lose access to the chat immediately.")
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        Section {
            VStack(spacing: 10) {
                // Tap to manage the shared group photo (admin) or a personal
                // (local, per-device) one — see LocalGroupAvatarStore.
                //
                // Extracted into its own Equatable view so the picker survives
                // this screen's relay-driven re-renders; see the type's docs.
                GroupAvatarPickerButton(
                    groupId: viewModel.groupId,
                    isAdmin: viewModel.isAdmin,
                    hasSharedImage: sharedAvatars.hasImage(for: viewModel.groupId),
                    hasLocalImage: avatars.hasImage(for: viewModel.groupId),
                    image: SharedGroupAvatarStore.resolvedImage(
                        for: viewModel.groupId, local: avatars, shared: sharedAvatars
                    ),
                    onPickedGroup: { data in
                        await appViewModel.setGroupAvatar(data: data, groupId: viewModel.groupId)
                    },
                    onRemoveGroup: {
                        await appViewModel.removeGroupAvatar(groupId: viewModel.groupId)
                    },
                    onPickedLocal: { data in
                        avatars.setImage(data: data, for: viewModel.groupId)
                    },
                    onRemoveLocal: {
                        avatars.removeImage(for: viewModel.groupId)
                    }
                )
                // Without this, the closures above defeat SwiftUI's change
                // detection and the picker re-renders on every relay event.
                .equatable()

                HStack(spacing: 6) {
                    Text(viewModel.groupName.isEmpty ? "Unnamed Group" : viewModel.groupName)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    // Unlike Invite People/Make Admin/Ready to Join, there's no
                    // local-only fallback for a rename — MDK's own enforcement
                    // doesn't reject a non-admin's `updateGroupData` call
                    // locally, so it merges on this device only and then gets
                    // silently overwritten by the next live sync, with no
                    // error ever shown. Gating on `isAdmin` here (unlike those
                    // three) avoids that dead-end instead of relying on
                    // enforcement that doesn't actually fail safely for this
                    // specific operation.
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

                // Matches the id diagnostics exports show for this group (no
                // name there, by design) — the only way to tell groups apart
                // in a pasted diagnostics report when you're in more than one.
                Button {
                    UIPasteboard.general.string = viewModel.diagnosticsGroupId
                    withAnimation(.spring(duration: 0.2)) { copiedGroupId = true }
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(.spring(duration: 0.2)) { copiedGroupId = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Group ID: \(viewModel.diagnosticsGroupId)")
                            .font(.caption2.monospaced())
                        Image(systemName: copiedGroupId ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            .padding(.bottom, 12)
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
                        // Abbreviated npub, not raw hex — matchable against what
                        // the joiner can read off their own Identity card.
                        Text(viewModel.displayIdentifier(for: joiner.pubkey))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    // Same checkmark/xmark-circle-fill pairing used for the
                    // invitee-side "pending welcome" accept/decline in
                    // GroupListView — one consistent approve/deny idiom.
                    Button {
                        Task { await viewModel.addPendingJoiner(joiner) }
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.isAddingMember)
                    .accessibilityLabel("Approve")

                    Button(role: .destructive) {
                        viewModel.dismissPendingJoiner(joiner)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red.opacity(0.8))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Deny")
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

    // MARK: - Location sharing

    /// Pauses only this group's outbound broadcast — the user keeps receiving
    /// and viewing everyone else's location here. The global "Pause Sharing"
    /// switch in Settings still overrides this for every group at once.
    private var locationSharingSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { appViewModel.settings.pausedGroupIds.contains(viewModel.groupId) },
                set: { paused in
                    if paused {
                        appViewModel.settings.pausedGroupIds.insert(viewModel.groupId)
                    } else {
                        appViewModel.settings.pausedGroupIds.remove(viewModel.groupId)
                    }
                }
            )) {
                Label("Pause Sharing to This Group", systemImage: "location.slash")
            }
        } footer: {
            Text("You'll stop sending your location here, but you'll still see everyone else's.")
        }
    }

    // MARK: - Leave

    private var leaveSection: some View {
        Section {
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

// MARK: - Member row (shared by the detail preview and the full list)

private struct MemberRowView: View {
    let member: GroupDetailViewModel.MemberItem
    @ObservedObject var viewModel: GroupDetailViewModel
    /// Swipe management is enabled inline only for small groups; large groups
    /// manage from the dedicated "See all" screen.
    var allowManage: Bool = true

    @State private var showResyncConfirm = false
    @State private var showPubkey = false

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
        .contentShape(Rectangle())
        .onTapGesture { showPubkey = true }
        .sheet(isPresented: $showPubkey) {
            MemberPubkeySheet(member: member, npub: viewModel.fullNpub(for: member.pubkeyHex))
        }
        // Not gated on `viewModel.isAdmin` — that reads the same cached admin
        // list that can diverge from live MLS truth (see `leaveGroup`'s doc
        // comment). Showing these to a genuine non-admin is a low-cost UX
        // trade: the underlying call fails safely with MDK's own "only admins
        // can perform this operation" error rather than silently hiding a
        // legitimate admin's only way to act when the cache is wrong.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if allowManage && !member.isMe {
                Button(role: .destructive) {
                    Task { await viewModel.removeMember(pubkeyHex: member.pubkeyHex) }
                } label: {
                    Label("Remove", systemImage: "person.badge.minus")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            // Resync stays hidden on your own row — `resyncMember` has its
            // own self-guard (removing+re-adding your own live device via a
            // relay-fetched key package isn't a coherent operation) and isn't
            // needed for the identity-recovery case below.
            if allowManage && !member.isMe {
                Button {
                    showResyncConfirm = true
                } label: {
                    Label("Resync", systemImage: "arrow.triangle.2.circlepath")
                }
                .tint(.indigo)
            }

            if allowManage && !member.isMe && !member.isAdmin {
                Button {
                    Task { await viewModel.promoteToAdmin(pubkeyHex: member.pubkeyHex) }
                } label: {
                    Label("Make Admin", systemImage: "shield.checkered")
                }
                .tint(.orange)
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

// MARK: - Member pubkey reveal (out-of-band identity verification)

/// Lets you verify a *named* member's identity by comparing their full npub
/// against what they read off their own Identity card — a nickname-less
/// member already shows an abbreviated npub in place of a name, but once a
/// nickname is cached there was previously no way to see the pubkey behind it.
private struct MemberPubkeySheet: View {
    let member: GroupDetailViewModel.MemberItem
    let npub: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        UIPasteboard.general.string = npub
                        withAnimation(.spring(duration: 0.2)) { copied = true }
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation(.spring(duration: 0.2)) { copied = false }
                        }
                    } label: {
                        HStack(alignment: .top) {
                            Text(npub)
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                                .lineLimit(4)
                            Spacer(minLength: 8)
                            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                                .foregroundStyle(copied ? .green : .blue)
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text(member.displayName)
                } footer: {
                    Text("Compare against the npub they read off their own Identity card to confirm this is really who you think it is.")
                }
            }
            .navigationTitle("Member Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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
