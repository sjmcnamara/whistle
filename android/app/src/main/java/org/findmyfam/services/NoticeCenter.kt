package org.findmyfam.services

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/**
 * One place for user-facing warnings and errors, in two tiers.
 *
 * The Kotlin counterpart of iOS's `NoticeCenter`. It replaces four ad-hoc
 * mechanisms, two of which displayed nothing at all: `MarmotKitService.lastError`
 * had no consumer, and `ChatViewModel.error` was never rendered, so a failed
 * chat send was silent. The rest were small red captions at the foot of a
 * list, easy to miss entirely.
 *
 * The split matters more than the styling:
 *
 * - A **toast** is for something the user just did that failed. They are
 *   looking at the screen, so it can auto-dismiss — and it carries a retry,
 *   because "send failed" without a way to send again is a dead end.
 * - A **banner** is for a state the app is *in*. A toast is wrong for these:
 *   it vanishes while the condition persists, so the app goes on being
 *   degraded with nothing on screen to say so.
 *
 * Field validation belongs in neither — it stays inline next to the field,
 * where it already was and already worked.
 *
 * `@Singleton`, not per-ViewModel: a failure raised by the background
 * location path has to reach whatever screen the user is on, and a
 * ViewModel-scoped instance would drop it.
 */
@Singleton
class NoticeCenter @Inject constructor() {

    // MARK: - Toasts

    data class Toast(
        val message: String,
        /**
         * Shown as a "Retry" affordance. Null for failures with nothing
         * sensible to repeat.
         */
        val retry: (suspend () -> Unit)? = null,
        val id: String = UUID.randomUUID().toString(),
    )

    /**
     * Newest last. More than one can be in flight — a burst of send failures
     * should not silently collapse into a single message.
     */
    private val _toasts = MutableStateFlow<List<Toast>>(emptyList())
    val toasts: StateFlow<List<Toast>> = _toasts.asStateFlow()

    /**
     * Not a `viewModelScope`: a toast posted as a screen is being torn down
     * still has to live out its lifetime on whatever screen replaces it.
     */
    private val scope = CoroutineScope(SupervisorJob())

    fun post(toast: Toast) {
        _toasts.value = _toasts.value + toast
        scope.launch {
            delay(TOAST_LIFETIME_MS)
            dismissToast(toast.id)
        }
    }

    /** Convenience for the common case. */
    fun postToast(message: String, retry: (suspend () -> Unit)? = null) =
        post(Toast(message = message, retry = retry))

    fun dismissToast(id: String) {
        _toasts.value = _toasts.value.filterNot { it.id == id }
    }

    // MARK: - Banners

    /**
     * What a banner is *about*, rather than what it says.
     *
     * Keyed by cause so that re-posting the same condition does not stack
     * duplicates, and so dismissing can be remembered per condition: a banner
     * the user has dismissed stays dismissed until the condition actually
     * clears, rather than reappearing on the next emission.
     */
    enum class Cause {
        ACCOUNT_SETUP_INCOMPLETE,
        GROUP_NEEDS_REPAIR,
        HISTORY_INCOMPLETE,
        RELAY_UNUSABLE,
        STARTUP_FAILED,
    }

    data class Banner(
        val cause: Cause,
        val message: String,
        val actionTitle: String? = null,
        val action: (suspend () -> Unit)? = null,
    )

    private val _banners = MutableStateFlow<List<Banner>>(emptyList())
    val banners: StateFlow<List<Banner>> = _banners.asStateFlow()

    /**
     * Causes the user has dismissed. Cleared by [clear] when the underlying
     * condition resolves, which is what lets the banner come back if it
     * happens again.
     */
    private val dismissedCauses = mutableSetOf<Cause>()

    fun post(banner: Banner) {
        if (banner.cause in dismissedCauses) return
        val existing = _banners.value.indexOfFirst { it.cause == banner.cause }
        _banners.value = if (existing >= 0) {
            // Replace rather than append: the message may have sharpened (a
            // specific relay named, say) while the cause is the same.
            _banners.value.toMutableList().also { it[existing] = banner }
        } else {
            _banners.value + banner
        }
    }

    /**
     * The condition has resolved. Removes the banner *and* forgets any
     * dismissal, so a recurrence is shown again.
     */
    fun clear(cause: Cause) {
        _banners.value = _banners.value.filterNot { it.cause == cause }
        dismissedCauses.remove(cause)
    }

    /** The user dismissed it. Suppressed until [clear]. */
    fun dismissBanner(cause: Cause) {
        _banners.value = _banners.value.filterNot { it.cause == cause }
        dismissedCauses.add(cause)
    }

    /**
     * Post or clear in one call, driven by whether the condition holds.
     *
     * The common shape for observed state — it keeps the "has it resolved?"
     * decision next to the "what do we say?" decision instead of scattering
     * [clear] calls through the callers. [message] is only built when needed.
     */
    fun setBanner(cause: Cause, active: Boolean, message: () -> Banner) {
        if (active) post(message()) else clear(cause)
    }

    /**
     * Report a failed operation.
     *
     * Most failures are transient and become a toast. The exception is
     * [MarmotKitService.ServiceError.GroupNeedsRepair]: that is a condition the
     * group is *in* until an admin re-admits the member, so a toast would
     * disappear while the group stayed unusable. It becomes a banner instead —
     * which is the entire reason the two tiers exist.
     */
    fun report(error: Throwable, fallback: String, retry: (suspend () -> Unit)? = null) {
        val serviceError = error as? MarmotKitService.ServiceError
        if (serviceError == null) {
            postToast(fallback, retry)
            return
        }

        // `ServiceError`'s own messages were written to be read by a user
        // ("You're the only admin of this group…"), which is the point of them
        // being typed rather than string-matched. Prefer them over the
        // caller's fallback, and never leak a raw debug description.
        val message = serviceError.message ?: fallback

        when (serviceError) {
            is MarmotKitService.ServiceError.GroupNeedsRepair ->
                post(Banner(cause = Cause.GROUP_NEEDS_REPAIR, message = message))

            // Advice, not transient failure. Retrying would fail identically,
            // so no Retry is offered however the caller asked.
            is MarmotKitService.ServiceError.LastAdminCannotLeave,
            is MarmotKitService.ServiceError.NotGroupAdmin,
            is MarmotKitService.ServiceError.MemberNotInGroup,
            is MarmotKitService.ServiceError.AlreadyMember,
            is MarmotKitService.ServiceError.LeaveAlreadyRequested,
            is MarmotKitService.ServiceError.UnrecognisedMemberCode,
            is MarmotKitService.ServiceError.AvatarTooLarge -> postToast(message)

            else -> postToast(message, retry)
        }
    }

    private companion object {
        /** How long a toast stays before dismissing itself. */
        const val TOAST_LIFETIME_MS = 4_000L
    }
}
