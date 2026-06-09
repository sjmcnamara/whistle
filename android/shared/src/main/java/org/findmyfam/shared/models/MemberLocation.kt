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

    /**
     * True when we haven't received a fresh location from this member in
     * more than 2× their update interval.
     *
     * Anchors on `receivedAt` (local clock) rather than `payload.ts`
     * (publisher's clock) so cross-device clock skew doesn't corrupt the
     * UI — semantically, "stale" means "we haven't heard from them in a
     * while," which is what users actually care about.
     *
     * Prefers the publisher's own `payload.interval` (added in v1.2.1) so a
     * member on a slow cadence isn't flagged stale just because the local
     * device polls more often. Falls back to `intervalSeconds` for pre-1.2.1
     * payloads that omit the field.
     */
    fun isStale(intervalSeconds: Int): Boolean {
        val basis = payload.interval ?: intervalSeconds
        val nowSeconds = System.currentTimeMillis() / 1000
        val threshold = basis * 2L
        return (nowSeconds - receivedAt) > threshold
    }

    /** Short display name (first 8 hex chars + ellipsis). */
    val displayName: String get() = "${memberPubkeyHex.take(8)}…"
}
