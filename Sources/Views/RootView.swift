import SwiftUI

struct RootView: View {
    @EnvironmentObject var appViewModel: AppViewModel

    var body: some View {
        TabView {
            chatTab
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                }

            FamilyMapView(viewModel: appViewModel.locationViewModel)
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .alert("Approve Member?", isPresented: approvalBinding) {
            Button("Approve") { Task { await appViewModel.approvePendingMember() } }
            Button("Dismiss", role: .cancel) { appViewModel.pendingApproval = nil }
        } message: {
            if let approval = appViewModel.pendingApproval {
                let groupName = appViewModel.groupListViewModel?.groups
                    .first(where: { $0.id == approval.groupId })?.name ?? "a group"
                Text("\(String(approval.pubkeyHex.prefix(8)))… wants to join \(groupName).")
            }
        }
        .alert("Approval Failed", isPresented: errorBinding) {
            Button("OK") { appViewModel.approvalError = nil }
        } message: {
            if let msg = appViewModel.approvalError {
                Text(msg)
            }
        }
        .alert("Member Approved", isPresented: successBinding) {
            Button("OK") { appViewModel.approvalSuccess = false }
        } message: {
            Text("They should appear in the group shortly.")
        }
    }

    private var approvalBinding: Binding<Bool> {
        Binding(
            get: { appViewModel.pendingApproval != nil },
            set: { if !$0 { appViewModel.pendingApproval = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { appViewModel.approvalError != nil },
            set: { if !$0 { appViewModel.approvalError = nil } }
        )
    }

    private var successBinding: Binding<Bool> {
        Binding(
            get: { appViewModel.approvalSuccess },
            set: { if !$0 { appViewModel.approvalSuccess = false } }
        )
    }

    @ViewBuilder
    private var chatTab: some View {
        if let groupListVM = appViewModel.groupListViewModel {
            GroupListView(viewModel: groupListVM)
        } else {
            // Marmot not yet initialised — show placeholder
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
