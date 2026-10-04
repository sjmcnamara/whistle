import SwiftUI

struct RootView: View {
    @EnvironmentObject var appViewModel: AppViewModel

    var body: some View {
        TabView {
            chatTab
                .tabItem {
                    Label("Groups", systemImage: "person.3.fill")
                }

            MapView(viewModel: appViewModel.locationViewModel)
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        // Attached once, here, so notices appear on every tab. A stalled
        // account stops location sharing as well as chat, so its banner has to
        // be visible on Map too — not only on the screen whose view model
        // happened to own the error.
        .overlay(alignment: .top) {
            NoticeOverlay(notices: appViewModel.notices)
                .allowsHitTesting(true)
        }
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
