package org.findmyfam.models

/**
 * A cached location for one group member.
 */
data class MemberLocation(
    val groupId: String,
    val memberPubkeyHex: String,
    val payload: LocationPayload,
    val receivedAt: Long = System.currentTimeMillis() / 1000
) {
    val id: String get() = "$groupId:$memberPubkeyHex"
}
