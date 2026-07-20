package org.findmyfam.shared.models

import org.json.JSONObject

/**
 * JSON payload for a group's shared photo, inside kind-445 MLS application messages.
 *
 * Sent as an inner kind-9 message alongside chat, nickname, and member avatar,
 * distinguished by its `type`:
 * { "type": "group_avatar", "img": "<base64 JPEG>", "ts": 1700000000, "v": 1 }
 *
 * The group is implicit — the message travels inside that group's MLS session,
 * so no group id is carried and none can be spoofed.
 *
 * Shares [AvatarPayload]'s size ceiling and target edge deliberately: both
 * travel the same way and must clear the same relay event limits, and a
 * divergence would mean one kind of avatar silently failing where the other
 * works.
 *
 * **Admin-only, enforced on receive.** This rides as an MLS *application*
 * message, so MLS guarantees only that the sender is a group member — not that
 * they are an admin. Receivers must check the sender against the group's admin
 * list before applying. (Marmot's own group-image component lives in GroupData
 * and is changed by a commit, where admin policy is enforced at the protocol
 * layer; carrying the image inline trades that for app-layer enforcement in
 * exchange for needing no blob storage.)
 *
 * An empty [img] means the admin cleared the group photo.
 */
data class GroupAvatarPayload(
    val type: String = "group_avatar",
    /** Base64-encoded JPEG, or "" to clear the group's photo. */
    val img: String,
    /** Unix timestamp in seconds since epoch. */
    val ts: Long,
    /** Schema version — always 1. */
    val v: Int = 1
) {
    /** True when this payload clears the group photo rather than setting one. */
    val isRemoval: Boolean get() = img.isEmpty()

    /**
     * True when the encoded image is within the size ceiling. A payload that
     * fails this must not be published — an oversized event is liable to be
     * rejected by the relay, which would silently drop the broadcast.
     */
    val isWithinSizeLimit: Boolean get() = img.toByteArray(Charsets.UTF_8).size <= MAX_ENCODED_BYTES

    /** Encode to a JSON string for use as MLS message content. */
    fun toJson(): String {
        return JSONObject().apply {
            put("type", type)
            put("img", img)
            put("ts", ts)
            put("v", v)
        }.toString()
    }

    companion object {
        /** Same ceiling as member avatars — see [AvatarPayload.MAX_ENCODED_BYTES]. */
        const val MAX_ENCODED_BYTES = AvatarPayload.MAX_ENCODED_BYTES

        /** Same target edge as member avatars — see [AvatarPayload.TARGET_EDGE]. */
        const val TARGET_EDGE = AvatarPayload.TARGET_EDGE

        /** Decode from a JSON string received in an MLS message. */
        fun fromJson(json: String): GroupAvatarPayload {
            val obj = JSONObject(json)
            return GroupAvatarPayload(
                type = obj.optString("type", "group_avatar"),
                img = obj.optString("img", ""),
                ts = obj.getLong("ts"),
                v = obj.optInt("v", 1)
            )
        }
    }
}
