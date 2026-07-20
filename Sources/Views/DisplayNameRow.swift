import SwiftUI

/// Settings row for editing the local user's display name.
///
/// Holds the in-progress text locally and commits on submit or blur, rather
/// than writing straight through to `AppSettings` on every keystroke.
///
/// `AppSettings.displayName` is `@Published`, and `AppViewModel` forwards its
/// `objectWillChange` to every observer, so a write-through binding made each
/// character re-render the whole of `SettingsView` — rebuilding the very
/// `TextField` being typed into. Same root cause as the avatar picker reload;
/// this is the input-control version of it. (Android already worked this way:
/// local state, committed on done.)
struct DisplayNameRow: View {
    /// Current committed value, used to seed and to re-sync on external change
    /// (identity import, burn).
    let committedName: String
    let onCommit: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Label("Display Name", systemImage: "person.text.rectangle")
                .lineLimit(1)
                .layoutPriority(1)
            Spacer()
            TextField("Your Name", text: $draft)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit { commit() }
        }
        .task(id: committedName) {
            // Seed on first appearance, and re-sync if the name changes from
            // elsewhere — but never clobber what the user is mid-way through
            // typing.
            if !isFocused {
                draft = committedName
            }
        }
        .onChange(of: isFocused) { (_, focused) in
            // Commit on blur so tapping away keeps the edit, matching what
            // users expect from a settings field.
            if !focused { commit() }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != committedName else { return }
        onCommit(trimmed)
    }
}
