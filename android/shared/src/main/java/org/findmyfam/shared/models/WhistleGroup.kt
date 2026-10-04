package org.findmyfam.shared.models

/**
 * A group, as the app understands one.
 *
 * The Kotlin counterpart of iOS's `WhistleGroup`, and it exists for the same
 * reason: so view models and UI stop consuming MarmotKit's own types directly.
 * That boundary is what let iOS swap the entire protocol stack underneath
 * without touching the view layer, and anything holding a MarmotKit type would
 * have had to change with it.
 */
data class WhistleGroup(
    val mlsGroupId: String,
    val name: String,
    /**
     * False for a group we have left, been removed from, or that was
     * disbanded.
     *
     * An unrecoverable group deliberately still counts as active: it needs a
     * re-admit to work again, but hiding it would leave the user unable to see
     * the group they have to act on.
     */
    val isActive: Boolean,
    val epoch: Long,
    val adminPubkeys: List<String>,
    /** Epoch seconds of the last activity, or null if none is recorded. */
    val lastMessageAt: Long?,
) {
    /** Name for display, falling back to a short id for an unnamed group. */
    val displayName: String
        get() = name.ifBlank { "Group ${mlsGroupId.take(8)}" }

    fun isAdmin(pubkeyHex: String): Boolean = adminPubkeys.contains(pubkeyHex)
}
