import SwiftUI
import MapKit

/// Live family map showing member location pins.
///
/// Uses the iOS 17 `Map { }` content builder API with `Annotation` views
/// for each member. A toolbar picker allows filtering by group.
struct FamilyMapView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @ObservedObject var viewModel: LocationViewModel
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                ForEach(viewModel.annotations) { annotation in
                    Annotation(
                        "",
                        coordinate: annotation.coordinate
                    ) {
                        MemberPinView(annotation: annotation)
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .navigationTitle("Map")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    locateMeButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    groupPicker
                }
            }
            .overlay {
                if viewModel.annotations.isEmpty {
                    emptyState
                }
            }
            .onChange(of: viewModel.annotations.count) {
                if !viewModel.annotations.isEmpty {
                    centreOnSelfOrAll()
                }
            }
        }
    }

    // MARK: - Locate me

    @ViewBuilder
    private var locateMeButton: some View {
        Button {
            centreOnSelf()
        } label: {
            Image(systemName: "location.fill")
        }
        .disabled(viewModel.annotations.first(where: { $0.isMe }) == nil)
    }

    private func centreOnSelf() {
        guard let selfAnnotation = viewModel.annotations.first(where: { $0.isMe }) else { return }
        withAnimation {
            position = .region(MKCoordinateRegion(
                center: selfAnnotation.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        }
    }

    /// Auto-centre on self when annotations first appear; fall back to fitting all pins.
    private func centreOnSelfOrAll() {
        if viewModel.annotations.first(where: { $0.isMe }) != nil {
            centreOnSelf()
        } else {
            position = .region(viewModel.region)
        }
    }

    // MARK: - Group picker

    @ViewBuilder
    private var groupPicker: some View {
        if let marmot = appViewModel.marmot, !marmot.groups.isEmpty {
            Menu {
                Button {
                    viewModel.selectedGroupId = nil
                } label: {
                    HStack {
                        Text("All Groups")
                        if viewModel.selectedGroupId == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                ForEach(marmot.groups, id: \.mlsGroupId) { group in
                    Button {
                        viewModel.selectedGroupId = group.mlsGroupId
                    } label: {
                        HStack {
                            Text(group.name.isEmpty ? "Unnamed Group" : group.name)
                            if viewModel.selectedGroupId == group.mlsGroupId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
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
