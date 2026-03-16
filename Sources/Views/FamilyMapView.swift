import SwiftUI
import MapKit

/// Live family map showing member location pins.
///
/// Replaces `MapPlaceholderView` in v0.4. Uses the iOS 17 `Map { }` content
/// builder API with `Annotation` views for each member.
struct FamilyMapView: View {
    @ObservedObject var viewModel: LocationViewModel
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                ForEach(viewModel.annotations) { annotation in
                    Annotation(
                        annotation.displayName,
                        coordinate: annotation.coordinate
                    ) {
                        MemberPinView(annotation: annotation)
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .navigationTitle("Map")
            .overlay {
                if viewModel.annotations.isEmpty {
                    emptyState
                }
            }
            .onChange(of: viewModel.annotations.count) {
                if !viewModel.annotations.isEmpty {
                    position = .region(viewModel.region)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "location.slash.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No locations yet")
                .font(.headline)
            Text("Family members' locations will appear here once they start sharing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}
