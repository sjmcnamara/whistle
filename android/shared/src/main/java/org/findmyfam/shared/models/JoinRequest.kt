package org.findmyfam.shared.models

import org.json.JSONObject

/**
 * JSON payload an invitee gift-wraps to the inviter (NIP-59, rumor kind
 * MarmotKind.JOIN_REQUEST) right after accepting an invite.
 *
 * It carries the invitee's KeyPackage inline so the admin can batch-add joiners
 * in a single MLS commit without a manual npub exchange. It stays private because
 * it rides inside a kind-1059 gift-wrap rather than any public event — membership
 * intent never touches a relay in the clear.
 *
 * Schema (rumor content):
 * { "type": "join-request", "v": 1,
 *   "groupId": "<mlsGroupId hex>",
 *   "pubkey": "<invitee pubkey hex>",
 *   "keyPackage": "<kind-30443 event JSON>",
 *   "name": "Alice" }
 */
data class JoinRequest(
    val type: String = "join-request",
    /** Target MLS group id (hex). Lets an admin of several groups route the request. */
    val groupId: String,
    /** Invitee's Nostr public key (hex). Redundant with the rumor author, but explicit. */
    val pubkey: String,
    /** Invitee's KeyPackage as a kind-30443 event JSON string — added with no relay fetch. */
    val keyPackage: String,
    /** Optional display name for the admin's pending-joiners list. */
    val name: String? = null,
    /** Schema version — always 1. */
    val v: Int = 1
) {
    /** Encode to a JSON string for use as the gift-wrapped rumor content. */
    fun toJson(): String = JSONObject().apply {
        put("type", type)
        put("v", v)
        put("groupId", groupId)
        put("pubkey", pubkey)
        put("keyPackage", keyPackage)
        if (name != null) put("name", name)
    }.toString()

    companion object {
        /** Decode from a gift-wrapped rumor's JSON content. */
        fun fromJson(json: String): JoinRequest {
            org.findmyfam.shared.JsonDepthGuard.validate(json)
            val obj = JSONObject(json)
            return JoinRequest(
                type = obj.optString("type", "join-request"),
                groupId = obj.getString("groupId"),
                pubkey = obj.getString("pubkey"),
                keyPackage = obj.getString("keyPackage"),
                name = if (obj.has("name") && !obj.isNull("name")) obj.getString("name") else null,
                v = obj.optInt("v", 1)
            )
        }
    }
}
