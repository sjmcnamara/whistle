package org.findmyfam.shared.models

/**
 * Tracks a pending invite where the user has published their key package
 * but hasn't yet received a Welcome event.
 */
data class PendingInvite(
    /** Group ID from the invite code (used to match against incoming Welcomes). */
    val groupHint: String,

    /** Bech32 npub of the person who created the invite. */
    val inviterNpub: String,

    /** When the invite was accepted locally (unix seconds). */
    val createdAt: Long = System.currentTimeMillis() / 1000
) {
    /** Unique identifier — uses the group ID hint from the invite code. */
    val id: String get() = groupHint
}
