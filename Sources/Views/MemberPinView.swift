import SwiftUI

/// Custom map annotation view for a family member's location pin.
///
/// - **Blue** = fresh location
/// - **Grey** = stale (older than 2× the update interval)
struct MemberPinView: View {
    let annotation: MemberAnnotation

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                MemberAvatarView(
                    pubkeyHex: annotation.memberPubkeyHex,
                    displayName: annotation.displayName,
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
