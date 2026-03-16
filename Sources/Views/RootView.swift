import SwiftUI

struct RootView: View {
    @EnvironmentObject var appViewModel: AppViewModel

    var body: some View {
        TabView {
            FamilyMapView(viewModel: appViewModel.locationViewModel)
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }

            chatTab
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
    }

    @ViewBuilder
    private var chatTab: some View {
        if let marmot = appViewModel.marmot {
            GroupListView(
                viewModel: GroupListViewModel(
                    marmot: marmot,
                    mls: appViewModel.mls
                )
            )
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
