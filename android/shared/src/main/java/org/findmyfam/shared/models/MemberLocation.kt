package org.findmyfam.shared.models

/**
 * A cached location for one group member.
 */
data class MemberLocation(
    /** MLS group this location belongs to. */
    val groupId: String,

    /** Hex-encoded public key of the member. */
    val memberPubkeyHex: String,

    /** The decoded location payload. */
    val payload: LocationPayload,

    /** When this location was processed locally (unix seconds). */
    val receivedAt: Long = System.currentTimeMillis() / 1000
) {
    /** Compound key: "groupId:memberPubkeyHex". */
    val id: String get() = "$groupId:$memberPubkeyHex"

    /** True when the location is older than 2× the configured update interval. */
    fun isStale(intervalSeconds: Int): Boolean {
        val nowSeconds = System.currentTimeMillis() / 1000
        val threshold = intervalSeconds * 2L
        return (nowSeconds - payload.ts) > threshold
    }

    /** Short display name (first 8 hex chars + ellipsis). */
    val displayName: String get() = "${memberPubkeyHex.take(8)}…"
}
