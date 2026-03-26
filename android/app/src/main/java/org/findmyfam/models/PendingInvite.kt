package org.findmyfam.models

/**
 * Tracks a pending invite where the user has published their key package
 * but hasn't yet received a Welcome event.
 */
data class PendingInvite(
    val groupHint: String,
    val inviterNpub: String,
    val createdAt: Long = System.currentTimeMillis() / 1000
)
