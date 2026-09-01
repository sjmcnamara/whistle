import SwiftUI
import PhotosUI

/// The tappable group photo in `GroupDetailView`'s hero header, owning the
/// options dialog and the `PhotosPicker` that hangs off it.
///
/// Deliberately owns its own `@State` and takes only plain values and closures
/// — it must **not** observe `AppViewModel`, `LocalGroupAvatarStore`, or
/// `SharedGroupAvatarStore`.
///
/// This is the same bug `AvatarPickerRow` was extracted to fix, in the other
/// place a picker is presented. `AppViewModel.forwardChildChanges()`
/// republishes on every `settings`, `locationService`, and `relay` change, so
/// `GroupDetailView` — which holds it as an `@EnvironmentObject` — re-renders
/// continuously as relay traffic arrives. With the `.photosPicker` modifier
/// inline in the hero section, each of those re-renders tore down and
/// re-presented the picker: the photo library visibly reloaded every couple of
/// seconds while the admin was trying to choose a group photo.
///
/// Taking `String`/`Bool`/`UIImage` inputs means SwiftUI sees unchanged values
/// on a parent re-render and skips re-evaluating this body, leaving the
/// presented picker alone.
struct GroupAvatarPickerButton: View, Equatable {
    /// Compares only the value inputs, deliberately ignoring the closures.
    ///
    /// SwiftUI's structural comparison can never prove two closures equal, so
    /// with them as stored properties it treated this view as changed on
    /// *every* parent re-render — re-evaluating the body and reloading the
    /// presented picker even though nothing visible had changed. Passing a
    /// resolved image is not sufficient on its own.
    ///
    /// Safe to ignore them: they capture `AppViewModel` and the avatar stores,
    /// all reference types, so a stale closure still calls through to the live
    /// object.
    ///
    /// Must be applied with `.equatable()` at the call site to take effect.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.groupId == rhs.groupId
            && lhs.isAdmin == rhs.isAdmin
            && lhs.hasSharedImage == rhs.hasSharedImage
            && lhs.hasLocalImage == rhs.hasLocalImage
            && lhs.image === rhs.image
    }

    let groupId: String
    let isAdmin: Bool
    let hasSharedImage: Bool
    let hasLocalImage: Bool
    /// Resolved by the parent. Passing the image in — rather than letting the
    /// label read it from the stores — keeps the button's label subtree inert,
    /// so nothing can invalidate it while the sheet is presented.
    let image: UIImage?
    let onPickedGroup: (Data) async -> AppViewModel.GroupAvatarUpdate
    let onRemoveGroup: () async -> Void
    let onPickedLocal: (Data) -> Void
    let onRemoveLocal: () -> Void

    @State private var item: PhotosPickerItem?
    @State private var showOptions = false
    @State private var showPicker = false
    @State private var pickingForGroup = false
    @State private var errorMessage: String?

    var body: some View {
        // A plain Button rather than a PhotosPicker: inside a List row a
        // PhotosPicker's hit region expanded past the circle and swallowed
        // taps meant for the group name and its rename pencil below, making
        // rename unreachable. The explicit frame and contentShape confine the
        // tap target to the circle itself.
        Button {
            showOptions = true
        } label: {
            ZStack(alignment: .bottomTrailing) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())
                } else {
                    ZStack {
                        Circle().fill(Color.blue.opacity(0.12)).frame(width: 80, height: 80)
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.blue)
                    }
                }
                Image(systemName: "camera.circle.fill")
                    .font(.system(size: 24))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .blue)
            }
            .frame(width: 80, height: 80)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Group photo")
        .confirmationDialog("Photo", isPresented: $showOptions, titleVisibility: .visible) {
            if isAdmin {
                Button(hasSharedImage ? "Change Group Photo" : "Set Group Photo") {
                    pickingForGroup = true
                    showPicker = true
                }
                if hasSharedImage {
                    Button("Remove Group Photo", role: .destructive) {
                        Task { await onRemoveGroup() }
                    }
                }
            }
            Button(hasLocalImage ? "Change Personal Photo" : "Set Personal Photo") {
                pickingForGroup = false
                showPicker = true
            }
            if hasLocalImage {
                Button("Remove Personal Photo", role: .destructive) { onRemoveLocal() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            // Kept short: confirmationDialog is a system action sheet whose
            // width is not ours to control, so long copy wraps into a cramped
            // block. The full explanation lives in the failure alert, which is
            // where it actually matters.
            Text(isAdmin
                 ? "The group photo is sent to everyone. A personal photo replaces the group's image on this device only."
                 : "A personal photo replaces the group's image on this device only.")
        }
        .photosPicker(isPresented: $showPicker, selection: $item, matching: .images)
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            let forGroup = pickingForGroup
            Task {
                defer {
                    item = nil
                    pickingForGroup = false
                }
                guard let data = try? await newItem.loadTransferable(type: Data.self) else { return }
                guard forGroup else {
                    onPickedLocal(data)
                    return
                }
                // Handle the outcome — a silently dropped result made every
                // failure look like "nothing happened".
                switch await onPickedGroup(data) {
                case .updated:
                    break
                case .notAdmin:
                    errorMessage = "Only a group admin can set the group photo."
                case .couldNotEncode:
                    errorMessage = "Group photos are sent to everyone, so they have to be small. This one couldn't be shrunk enough — try another image."
                }
            }
        }
        .alert(
            "Couldn't set group photo",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
