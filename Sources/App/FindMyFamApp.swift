import SwiftUI

@main
struct FindMyFamApp: App {

    @StateObject private var appViewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(appViewModel)

                if appViewModel.startupPhase != .ready {
                    SplashView(phase: appViewModel.startupPhase)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(.easeOut(duration: 0.45), value: appViewModel.startupPhase == .ready)
            .task {
                await appViewModel.onAppear()
            }
            .onOpenURL { url in
                appViewModel.handleIncomingURL(url)
            }
        }
    }
}
