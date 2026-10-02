import SwiftUI

/// Renders `NoticeCenter`'s two tiers over whatever tab is showing.
///
/// Attached once in `RootView` rather than per screen. That is the point:
/// under the old arrangement an error could only appear on the screen that
/// happened to own the view model holding it, so a failure raised by the
/// receive loop had nowhere to go at all. A stalled account also stops
/// location sharing, so its banner has to be visible on the Map tab, not just
/// in Groups.
///
/// Both tiers are drawn by the same `NoticeCard`. The first version did not,
/// and they drifted immediately: the banner became a material card with an
/// orange accent and primary text while the toast stayed a black capsule with
/// white text, so two notices from the same system looked like they came from
/// different apps. Only the things that *should* differ now differ — position,
/// accent, and whether there is a dismiss button.
struct NoticeOverlay: View {
    @ObservedObject var notices: NoticeCenter

    var body: some View {
        VStack(spacing: 0) {
            banners
            Spacer(minLength: 0)
            toasts
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: notices.banners.map(\.cause))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: notices.toasts.map(\.id))
    }

    // MARK: - Banners (top, persistent, dismissable)

    private var banners: some View {
        VStack(spacing: 8) {
            ForEach(notices.banners) { banner in
                NoticeCard(
                    // Orange: a condition the app is in, needing attention
                    // but not caused by something the user just did.
                    accent: .orange,
                    icon: "exclamationmark.triangle.fill",
                    message: banner.message,
                    actionTitle: banner.actionTitle,
                    action: banner.action,
                    onDismiss: { notices.dismissBanner(banner.cause) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Toasts (bottom, transient, tap to dismiss)

    private var toasts: some View {
        VStack(spacing: 8) {
            ForEach(notices.toasts) { toast in
                NoticeCard(
                    // Red: something the user just attempted did not work.
                    accent: .red,
                    icon: "exclamationmark.circle.fill",
                    message: toast.message,
                    actionTitle: toast.retry == nil ? nil : "Retry",
                    action: toast.retry.map { retry in
                        {
                            notices.dismissToast(toast.id)
                            await retry()
                        }
                    },
                    // No dismiss button: it times out on its own, and a
                    // second control would crowd a message that is leaving
                    // anyway. Tapping the card dismisses it.
                    onDismiss: nil
                )
                .onTapGesture { notices.dismissToast(toast.id) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Clear of the floating tab bar.
        .padding(.bottom, 70)
    }
}

/// The shared shape for both tiers.
private struct NoticeCard: View {
    let accent: Color
    let icon: String
    let message: String
    let actionTitle: String?
    let action: (() async -> Void)?
    let onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Solid leading bar rather than a border around the whole card:
            // a hairline stroke read as a weak outline instead of a warning,
            // and competed with the rounded rows of a grouped list behind it.
            Capsule()
                .fill(accent)
                .frame(width: 4)

            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(accent)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Below the message, not beside it: inline, a long message
                // squeezed the action down to a couple of characters.
                if let actionTitle, let action {
                    Button(actionTitle) { Task { await action() } }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.horizontal, 12)
    }
}
