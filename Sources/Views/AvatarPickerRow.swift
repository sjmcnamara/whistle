import SwiftUI
import PhotosUI

/// Settings row for picking the user's own avatar.
///
/// Deliberately owns its own `@State` and takes only plain values and closures
/// — it must **not** observe `AppViewModel`.
///
/// `AppViewModel.forwardChildChanges()` republishes on every `settings`,
/// `locationService`, and `relay` change, so any view holding it as an
/// `@EnvironmentObject` re-renders continuously as relay traffic arrives. When
/// the `PhotosPicker` lived directly in `SettingsView`'s body, each of those
/// re-renders tore down and re-presented the picker — the photo library
/// visibly reloaded every couple of seconds while the user just sat there.
///
/// Taking `String`/`Bool` inputs means SwiftUI sees unchanged values on a
/// parent re-render and skips re-evaluating this body, leaving the presented
/// picker alone.
struct AvatarPickerRow: View, Equatable {
    /// Compares only the value inputs, deliberately ignoring the closures.
    ///
    /// SwiftUI's structural comparison can never prove two closures equal, so
    /// with `onPicked`/`onRemove` as stored properties it treated this view as
    /// changed on *every* parent re-render — re-evaluating the body and
    /// reloading the presented picker even though nothing visible had changed.
    /// Passing a resolved image was not sufficient on its own.
    ///
    /// Safe to ignore them: both closures capture `AppViewModel`, a reference
    /// type, so a stale closure still calls through to the live object.
    ///
    /// Must be applied with `.equatable()` at the call site to take effect.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pubkeyHex == rhs.pubkeyHex
            && lhs.displayName == rhs.displayName
            && lhs.image === rhs.image
    }

    let pubkeyHex: String
    let displayName: String
    /// Resolved by the parent. Passing the image in — rather than letting the
    /// label read it from the store — keeps the picker's label subtree inert,
    /// so nothing can invalidate it while the sheet is presented.
    let image: UIImage?
    let onPicked: (Data) async -> Bool
    let onRemove: () async -> Void

    @State private var item: PhotosPickerItem?
    @State private var showTooLargeAlert = false
    @State private var showOptions = false
    @State private var showPicker = false

    var body: some View {
        HStack {
            Label("Photo", systemImage: "person.crop.square")
                .lineLimit(1)
                .layoutPriority(1)
            Spacer()

            // Tapping the image opens a menu rather than jumping straight into
            // the library. Removal used to be a separate inline link — small,
            // easy to mis-tap, and visually noisy next to the thumbnail.
            Button {
                showOptions = true
            } label: {
                MemberAvatarThumb(
                    pubkeyHex: pubkeyHex,
                    displayName: displayName,
                    image: image,
                    diameter: 36
                )
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Your photo")
        }
        .confirmationDialog("Your Photo", isPresented: $showOptions, titleVisibility: .visible) {
            Button(image == nil ? "Choose Photo" : "Change Photo") { showPicker = true }
            if image != nil {
                Button("Remove Photo", role: .destructive) {
                    Task { await onRemove() }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Shared with everyone in your groups.")
        }
        .photosPicker(isPresented: $showPicker, selection: $item, matching: .images)
        .onChange(of: item) { (_, newItem) in
            guard let newItem else { return }
            Task {
                defer { item = nil }
                guard let data = try? await newItem.loadTransferable(type: Data.self) else { return }
                // Failure means the image could not be squeezed under the wire
                // cap — tell the user rather than leaving them with an avatar
                // only they can see.
                showTooLargeAlert = await onPicked(data) == false
            }
        }
        .alert("Couldn't share that photo", isPresented: $showTooLargeAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your photo is sent to everyone in your groups, so it has to be small. This one couldn't be shrunk enough — try a different image.")
        }
    }
}
