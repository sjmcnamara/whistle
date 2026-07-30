import SwiftUI
import MapKit

/// Live map showing group member location pins.
///
/// Uses the iOS 17 `Map { }` content builder API with `Annotation` views
/// for each member. A toolbar picker allows filtering by group.
struct MapView: View {
    private enum MapMode: String {
        case standard
        case satellite
    }

    @EnvironmentObject var appViewModel: AppViewModel
    /// Observed here rather than inside the pin. The pin is hosted by MapKit
    /// outside this view's environment, so it cannot reach the store itself —
    /// see `MemberPinView`. Observing it here also keeps pins live: a bumped
    /// `revision` re-renders this body, which re-resolves every pin's image.
    @EnvironmentObject private var memberAvatars: MemberAvatarStore
    @ObservedObject var viewModel: LocationViewModel
    @State private var position: MapCameraPosition = .automatic
    @State private var mapMode: MapMode = .standard
    @State private var selectedAnnotation: MemberAnnotation?

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                ForEach(viewModel.annotations) { annotation in
                    Annotation(
                        "",
                        coordinate: annotation.coordinate
                    ) {
                        // No `.environmentObject(...)` here — #187 re-injected
                        // the store to stop the same crash, which worked but
                        // left a trap-on-missing dependency inside the hosting
                        // view that had already lost the environment once. The
                        // pin now takes a resolved image and reads nothing from
                        // the environment, so there is nothing left to lose.
                        MemberPinView(
                            annotation: annotation,
                            avatarImage: memberAvatars.image(for: annotation.memberPubkeyHex)
                        )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedAnnotation = annotation
                            }
                    }
                }
            }
            .mapStyle(currentMapStyle)
            .navigationTitle("Map")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 10) {
                        locateMeButton
                        mapModeMenu
                    }
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
            .overlay(alignment: .bottom) {
                whistleButton
                    .padding(.bottom, 24)
            }
            .sheet(item: $selectedAnnotation) { annotation in
                MemberDetailSheet(annotation: annotation)
            }
            .onChange(of: viewModel.annotations.count) {
                if !viewModel.annotations.isEmpty {
                    centreOnSelfOrAll()
                }
            }
            .onChange(of: appViewModel.marmot?.groups) { _, groups in
                guard let selectedId = viewModel.selectedGroupId else { return }
                let activeIds = (groups ?? []).filter(\.isActive).map(\.mlsGroupId)
                if !activeIds.contains(selectedId) {
                    viewModel.selectedGroupId = nil
                }
            }
            .onChange(of: appViewModel.pendingLeaveStore.pendingLeaves) { _, pending in
                guard let selectedId = viewModel.selectedGroupId else { return }
                if pending.contains(selectedId) {
                    viewModel.selectedGroupId = nil
                }
            }
        }
    }

    // MARK: - Whistle

    /// Manual "force-publish my location now" button. Ignores the throttle,
    /// motion backoff, and pause state — see `AppViewModel.whistle()`.
    @ViewBuilder
    private var whistleButton: some View {
        Button {
            appViewModel.whistle()
        } label: {
            whistleIcon
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(
                    Circle().fill(appViewModel.whistleState == .failed ? Color.red : Color.accentColor)
                )
                .shadow(radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(appViewModel.whistleState == .sending)
        .accessibilityLabel("Whistle")
        .sensoryFeedback(.success, trigger: appViewModel.whistleState) { _, new in new == .sent }
        .sensoryFeedback(.impact, trigger: appViewModel.whistleState) { _, new in new == .sending }
        .animation(.easeInOut(duration: 0.2), value: appViewModel.whistleState)
    }

    @ViewBuilder
    private var whistleIcon: some View {
        switch appViewModel.whistleState {
        case .sending:
            ProgressView().tint(.white)
        case .sent:
            Image(systemName: "checkmark")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
        case .idle:
            Image(systemName: "dot.radiowaves.left.and.right")
        }
    }

    // MARK: - Locate me

    @ViewBuilder
    private var locateMeButton: some View {
        Button {
            centreOnSelf()
        } label: {
            Image(systemName: "location")
        }
        .disabled(viewModel.annotations.first(where: { $0.isMe }) == nil)
    }

    @ViewBuilder
    private var mapModeMenu: some View {
        Menu {
            mapModeButton(.standard, title: "Default", icon: "map")
            mapModeButton(.satellite, title: "Satellite", icon: "globe.europe.africa")
        } label: {
            Image(systemName: "map")
        }
    }

    /// 3D terrain is deliberately back on. #187 switched both cases to `.flat`
    /// while hunting the repeated-zoom-out crash, on the theory that MapKit's
    /// realistic terrain renderer was causing GPU-memory instability. The root
    /// cause turned out to be a missing `@EnvironmentObject` in the annotation
    /// hosting view (see `MemberPinView`) and had nothing to do with terrain,
    /// so the visual downgrade was buying nothing.
    private var currentMapStyle: MapStyle {
        switch mapMode {
        case .standard:
            return .standard(elevation: .realistic)
        case .satellite:
            return .imagery(elevation: .realistic)
        }
    }

    private func mapModeButton(_ mode: MapMode, title: String, icon: String) -> some View {
        Button {
            mapMode = mode
        } label: {
            HStack {
                Label(title, systemImage: icon)
                if mapMode == mode {
                    Image(systemName: "checkmark")
                }
            }
        }
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

                ForEach(marmot.groups.filter { $0.isActive && !appViewModel.pendingLeaveStore.contains($0.mlsGroupId) }, id: \.mlsGroupId) { group in
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
            Text("Group members' locations will appear here once they start sharing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}
