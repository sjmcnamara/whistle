import Foundation
import Combine

/// One place for user-facing warnings and errors, in two tiers.
///
/// Replaces four ad-hoc mechanisms, two of which displayed nothing at all:
/// `MarmotKitService.lastError` had no consumer, and `ChatViewModel.error` was
/// never rendered, so a failed chat send was silent. The rest were small red
/// captions at the foot of a `List` section, easy to miss entirely.
///
/// The split matters more than the styling:
///
/// - A **toast** is for something the user just did that failed. They are
///   looking at the screen, so it can auto-dismiss — and it carries a retry,
///   because "send failed" without a way to send again is a dead end.
/// - A **banner** is for a state the app is *in*. A toast is wrong for these:
///   it vanishes while the condition persists, so the app goes on being
///   degraded with nothing on screen to say so.
///
/// Field validation belongs in neither — it stays inline next to the field,
/// where it already was and already worked.
@MainActor
final class NoticeCenter: ObservableObject {

    // MARK: - Toasts

    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        /// Shown as a "Retry" affordance. `nil` for failures with nothing
        /// sensible to repeat.
        let retry: (() async -> Void)?

        init(message: String, retry: (() async -> Void)? = nil) {
            self.message = message
            self.retry = retry
        }
    }

    /// Newest last. More than one can be in flight — a burst of send failures
    /// should not silently collapse into a single message.
    @Published private(set) var toasts: [Toast] = []

    /// How long a toast stays before dismissing itself.
    private let toastLifetime: Duration = .seconds(4)

    func post(_ toast: Toast) {
        toasts.append(toast)
        let id = toast.id
        // `lifetime` is read out here rather than inside the closure: capturing
        // it through `self` is an error under the Swift 6 language mode, and
        // the value cannot change between the two anyway.
        let lifetime = toastLifetime
        Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            self?.dismissToast(id)
        }
    }

    /// Convenience for the common case.
    func postToast(_ message: String, retry: (() async -> Void)? = nil) {
        post(Toast(message: message, retry: retry))
    }

    func dismissToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    // MARK: - Banners

    /// What a banner is *about*, rather than what it says.
    ///
    /// Keyed by cause so that re-posting the same condition does not stack
    /// duplicates, and so dismissing can be remembered per condition: a
    /// banner the user has dismissed stays dismissed until the condition
    /// actually clears, rather than reappearing on the next poll.
    enum Cause: String, CaseIterable {
        case accountSetupIncomplete
        case groupNeedsRepair
        case relayUnusable
        case startupFailed
    }

    struct Banner: Identifiable {
        let cause: Cause
        let message: String
        let actionTitle: String?
        let action: (() async -> Void)?

        var id: Cause { cause }

        init(
            cause: Cause,
            message: String,
            actionTitle: String? = nil,
            action: (() async -> Void)? = nil
        ) {
            self.cause = cause
            self.message = message
            self.actionTitle = actionTitle
            self.action = action
        }
    }

    @Published private(set) var banners: [Banner] = []

    /// Causes the user has dismissed. Cleared by `clear(_:)` when the
    /// underlying condition resolves, which is what lets the banner come back
    /// if it happens again.
    private var dismissedCauses: Set<Cause> = []

    func post(_ banner: Banner) {
        guard !dismissedCauses.contains(banner.cause) else { return }
        if let index = banners.firstIndex(where: { $0.cause == banner.cause }) {
            // Replace rather than append: the message may have sharpened (a
            // specific relay named, say) while the cause is the same.
            banners[index] = banner
        } else {
            banners.append(banner)
        }
    }

    /// The condition has resolved. Removes the banner *and* forgets any
    /// dismissal, so a recurrence is shown again.
    func clear(_ cause: Cause) {
        banners.removeAll { $0.cause == cause }
        dismissedCauses.remove(cause)
    }

    /// The user dismissed it. Suppressed until `clear(_:)`.
    func dismissBanner(_ cause: Cause) {
        banners.removeAll { $0.cause == cause }
        dismissedCauses.insert(cause)
    }

    /// Post or clear in one call, driven by whether the condition holds.
    ///
    /// The common shape for polled state — it keeps the "has it resolved?"
    /// decision next to the "what do we say?" decision instead of scattering
    /// `clear` calls through the callers.
    func setBanner(_ cause: Cause, active: Bool, message: @autoclosure () -> Banner) {
        if active {
            post(message())
        } else {
            clear(cause)
        }
    }
}
