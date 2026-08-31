import SwiftUI

/// Custom map annotation view for a group member's location pin.
///
/// - **Blue** = fresh location
/// - **Grey** = stale (older than 2× the update interval)
///
/// Reads nothing from the SwiftUI environment, deliberately. MapKit hosts
/// `Annotation` content in its own `_UIHostingView` (`SwiftUIAnnotationView`),
/// which does **not** carry the environment from the `Map`'s ancestors — and it
/// builds that view from `MKAnnotationManager.updateVisibleAnnotations`, a timer
/// callback outside SwiftUI's update pass. This view previously used
/// `MemberAvatarView`, whose `@EnvironmentObject MemberAvatarStore` therefore
/// resolved to nothing and trapped in `EnvironmentObject.error()`, crashing the
/// app while the map was panned or zoomed. The avatar is now resolved by
/// `MapView` — where the environment is valid — and passed in.
struct MemberPinView: View {
    let annotation: MemberAnnotation
    /// Resolved by `MapView`. See the type's note on the missing environment.
    let avatarImage: UIImage?

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                MemberAvatarThumb(
                    pubkeyHex: annotation.memberPubkeyHex,
                    displayName: annotation.displayName,
                    image: avatarImage,
                    diameter: 32,
                    isStale: annotation.isStale
                )

                if annotation.isStationary == true {
                    Image(systemName: "figure.stand")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2.5)
                        .background(Circle().fill(Color.orange))
                        .offset(x: 8, y: -8)
                }
            }

            Text(annotation.displayName)
                .font(.caption2.bold())
                .foregroundStyle(annotation.isStale ? .secondary : .primary)

            // `fixedSize` lets the label expand to its natural width instead
            // of shrinking + truncating inside the VStack. Future-relative
            // strings ("in 2 min, 5 sec") are longer than past-relative
            // ("2 min ago"), so the self pin's countdown otherwise truncated.
            if let next = annotation.nextUpdateDate {
                Text(next, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text(annotation.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}
