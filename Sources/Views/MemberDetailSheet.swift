import SwiftUI

/// Bottom sheet shown when tapping a member pin on the map.
///
/// Surfaces the publisher's update cadence (carried in `LocationPayload.interval`
/// since v1.2.1) and a local-clock "last seen" so users can answer
/// "why is mom's pin always grey?" without crowding the map.
struct MemberDetailSheet: View {
    let annotation: MemberAnnotation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                MemberAvatarView(
                    pubkeyHex: annotation.memberPubkeyHex,
                    displayName: annotation.displayName,
                    diameter: 44,
                    isStale: annotation.isStale
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(annotation.displayName)
                        .font(.title3.bold())
                    if annotation.isMe {
                        Text("You")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Divider()

            row("Last seen", value: lastSeenText, systemImage: "clock")
            row("Publishes", value: cadenceText, systemImage: "arrow.triangle.2.circlepath")
            // Only shown when known stationary — an omitted/unknown value
            // renders nothing rather than claiming the member is moving.
            if annotation.isStationary == true {
                row("Motion", value: "Currently stationary", systemImage: "figure.stand")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 24)
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func row(_ label: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    private var lastSeenText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: annotation.timestamp, relativeTo: Date())
    }

    private var cadenceText: String {
        guard let seconds = annotation.intervalSeconds else { return "Unknown" }
        return "every " + MemberDetailSheet.formatCadence(seconds: seconds)
    }

    /// Renders a seconds count as a short human-readable cadence
    /// (e.g. `10` → "10 sec", `3600` → "1 hour", `5400` → "1 hr 30 min").
    static func formatCadence(seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds) sec"
        }
        if seconds < 3600 {
            let minutes = seconds / 60
            return "\(minutes) min"
        }
        let hours = seconds / 3600
        let remMinutes = (seconds % 3600) / 60
        if remMinutes == 0 {
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return "\(hours) hr \(remMinutes) min"
    }
}
