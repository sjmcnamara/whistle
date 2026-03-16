import SwiftUI

struct RootView: View {
    @EnvironmentObject var appViewModel: AppViewModel

    var body: some View {
        TabView {
            FamilyMapView(viewModel: appViewModel.locationViewModel)
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }

            ChatPlaceholderView()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
    }
}
