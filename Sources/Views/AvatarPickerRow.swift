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
struct AvatarPickerRow: View {
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

    var body: some View {
        HStack {
            Label("Photo", systemImage: "person.crop.square")
                .lineLimit(1)
                .layoutPriority(1)
            Spacer()

            if image != nil {
                Button(role: .destructive) {
                    Task { await onRemove() }
                } label: {
                    Text("Remove").font(.caption)
                }
                .buttonStyle(.borderless)
            }

            PhotosPicker(selection: $item, matching: .images) {
                MemberAvatarThumb(
                    pubkeyHex: pubkeyHex,
                    displayName: displayName,
                    image: image,
                    diameter: 36
                )
            }
            .buttonStyle(.borderless)
        }
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
            Text("That image couldn't be made small enough to send. Try a different one.")
        }
    }
}
