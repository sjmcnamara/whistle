import SwiftUI

/// Renders `NoticeCenter`'s two tiers over whatever tab is showing.
///
/// Attached once in `RootView` rather than per screen. That is the point:
/// under the old arrangement an error could only appear on the screen that
/// happened to own the view model holding it, so a failure raised by the
/// receive loop had nowhere to go at all. A stalled account also stops
/// location sharing, so its banner has to be visible on the Map tab, not just
/// in Groups.
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

    // MARK: - Banners (top, persistent)

    private var banners: some View {
        VStack(spacing: 6) {
            ForEach(notices.banners) { banner in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                    Text(banner.message)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let title = banner.actionTitle, let action = banner.action {
                        Button(title) { Task { await action() } }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                    }

                    Button {
                        notices.dismissBanner(banner.cause)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.orange.opacity(0.35), lineWidth: 1)
                )
                .padding(.horizontal, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Toasts (bottom, transient)

    private var toasts: some View {
        VStack(spacing: 8) {
            ForEach(notices.toasts) { toast in
                HStack(spacing: 12) {
                    Text(toast.message)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let retry = toast.retry {
                        Button("Retry") {
                            notices.dismissToast(toast.id)
                            Task { await retry() }
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.85), in: Capsule())
                .padding(.horizontal, 16)
                // Tap anywhere to dismiss, so a toast never blocks the UI
                // underneath while it waits out its own timer.
                .onTapGesture { notices.dismissToast(toast.id) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Clear of the tab bar.
        .padding(.bottom, 58)
    }
}
