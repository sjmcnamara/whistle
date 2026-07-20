import SwiftUI

/// Authorization row that deep-links to the app's page in system Settings.
///
/// Exists as its own view so that `@Environment(\.openURL)` is read *here*
/// rather than in `SettingsView`.
///
/// SwiftUI swaps the environment's `OpenURLAction` when a sheet is presented,
/// so a parent that reads `\.openURL` gets invalidated by its own presentation.
/// In `SettingsView` that meant presenting the avatar `PhotosPicker` re-rendered
/// the view presenting it, and the picker visibly reloaded. Instrumentation
/// named the dependency directly: `SettingsView: _openURL changed.` fired on
/// every reload while the row itself stayed inert.
///
/// Keeping the dependency in a leaf that nothing is presented from confines the
/// invalidation to a view where re-rendering costs nothing.
struct OpenAppSettingsRow: View {
    let statusText: String

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        } label: {
            HStack {
                Label("Authorization", systemImage: "checkmark.shield")
                Spacer()
                Text(statusText)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}
