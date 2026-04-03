import SwiftUI

/// Custom map annotation view for a family member's location pin.
///
/// - **Blue** = fresh location
/// - **Grey** = stale (older than 2× the update interval)
struct MemberPinView: View {
    let annotation: MemberAnnotation

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "person.circle.fill")
                .font(.title)
                .foregroundStyle(annotation.isStale ? .gray : .blue)
                .background(
                    Circle()
                        .fill(.white)
                        .frame(width: 28, height: 28)
                )

            Text(annotation.displayName)
                .font(.caption2.bold())
                .foregroundStyle(annotation.isStale ? .secondary : .primary)

            if let next = annotation.nextUpdateDate {
                Text(next, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text(annotation.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}
