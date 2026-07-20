import SwiftUI

/// Purely presentational avatar circle — observes nothing.
///
/// Kept separate from `MemberAvatarView` so it can be used as a `PhotosPicker`
/// label. The picker reloads its presented sheet whenever its label view is
/// invalidated, so the label's subtree must not depend on an `ObservableObject`
/// (or on anything that resolves lazily, like a disk read during `body`).
/// Handing this a resolved `UIImage?` makes the label inert.
struct MemberAvatarThumb: View {
    let pubkeyHex: String
    let displayName: String
    let image: UIImage?
    var diameter: CGFloat = 32
    /// Greyed out to match a stale map pin.
    var isStale: Bool = false

    var body: some View {
        #if DEBUG
        // Temporary: part of the picker re-render investigation.
        // `let _` is required inside a ViewBuilder — a bare `_ =` is not a
        // valid builder statement, so the lint rule does not apply here.
        // swiftlint:disable:next redundant_discardable_let
        let _ = Self._printChanges()
        #endif
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .saturation(isStale ? 0 : 1)
                    .opacity(isStale ? 0.6 : 1)
            } else {
                Circle()
                    .fill(isStale ? Color.gray : MemberAvatarView.colour(for: pubkeyHex))
                    .overlay(
                        Text(MemberAvatarView.initials(from: displayName))
                            .font(.system(size: diameter * 0.4, weight: .semibold))
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                    )
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white, lineWidth: 2))
    }
}

/// A member's avatar, falling back to their initials when no image is set.
///
/// Every member has a display name but only some have an avatar, so the
/// initials circle is the normal state rather than an error state — it is
/// styled to look deliberate, not like a missing image.
///
/// This is the store-connected wrapper: it re-renders when the store publishes.
/// Use `MemberAvatarThumb` directly anywhere that re-rendering is harmful.
struct MemberAvatarView: View {
    let pubkeyHex: String
    let displayName: String
    var diameter: CGFloat = 32
    /// Greyed out to match a stale map pin.
    var isStale: Bool = false

    @EnvironmentObject private var avatars: MemberAvatarStore

    var body: some View {
        MemberAvatarThumb(
            pubkeyHex: pubkeyHex,
            displayName: displayName,
            image: avatars.image(for: pubkeyHex),
            diameter: diameter,
            isStale: isStale
        )
        // No `.id(avatars.revision)` here. Observing the store via
        // @EnvironmentObject already re-renders this view (and re-reads
        // `image(for:)`) whenever `revision` is bumped, so the modifier was
        // redundant — and `.id()` destroys and rebuilds the view rather than
        // updating it, which visibly flickered when used as a picker label.
    }

    // MARK: - Fallback

    static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown]

    /// Up to two initials from a display name. Falls back to "?" for a name
    /// with no usable letters — a nickname can be an emoji or punctuation.
    static func initials(from name: String) -> String {
        let words = name
            .split(separator: " ", omittingEmptySubsequences: true)
            .compactMap { $0.first(where: \.isLetter) }
        if words.isEmpty {
            return "?"
        }
        return String(words.prefix(2)).uppercased()
    }

    /// Stable colour derived from the pubkey, so a member keeps the same
    /// initials circle across launches and across devices.
    static func colour(for pubkeyHex: String) -> Color {
        palette[colourIndex(for: pubkeyHex)]
    }

    /// FNV-1a rather than `hashValue`, which Swift seeds per process — a
    /// hash-based colour would change on every launch. Mirrors the Kotlin
    /// `MemberAvatarFallback.colorIndex` byte for byte.
    ///
    /// Takes the *top* bits. FNV-1a's low bits mix poorly, and reducing with
    /// `hash % 8` collapsed every one of 60 sample 64-character hex keys onto a
    /// single index — every member would have shared one colour. The high byte
    /// spreads across the whole palette.
    ///
    /// (A plain sum of bytes was the first attempt and was degenerate too: the
    /// palette size divides 64, so uniform 64-character keys all landed on 0.)
    static func colourIndex(for pubkeyHex: String) -> Int {
        var hash: UInt32 = 2166136261
        for byte in pubkeyHex.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return Int((hash >> 24) % UInt32(palette.count))
    }
}
