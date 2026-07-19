package org.findmyfam.shared.models

import org.json.JSONObject

/**
 * JSON payload for member avatar broadcasts inside kind-445 MLS application messages.
 *
 * Sent as an inner kind-9 message (same as chat and nickname) with its own
 * `type` field.
 * { "type": "avatar", "img": "<base64 JPEG>", "ts": 1700000000, "v": 1 }
 *
 * The image travels inline rather than as a blob reference. A family group is
 * small and the image is deliberately tiny, so inlining keeps the feature fully
 * end-to-end encrypted with no blob server and no new infrastructure —
 * consistent with the project's no-servers position. See [MAX_ENCODED_BYTES]
 * for the size ceiling this relies on.
 *
 * An empty [img] means "I removed my avatar" — receivers clear any stored image
 * for that member rather than ignoring the message.
 */
data class AvatarPayload(
    val type: String = "avatar",
    /** Base64-encoded JPEG, or "" to clear a previously-set avatar. */
    val img: String,
    /** Unix timestamp in seconds since epoch. */
    val ts: Long,
    /** Schema version — always 1. */
    val v: Int = 1
) {
    /** True when this payload clears the sender's avatar rather than setting one. */
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
        /**
         * Ceiling on the base64 payload, in bytes.
         *
         * Nostr relays commonly cap event size somewhere between 64 KB and
         * 256 KB, and the avatar shares that budget with MLS framing and NIP-44
         * overhead. 16 KB leaves generous headroom against the most restrictive
         * relays while comfortably fitting the encoder's output at [TARGET_EDGE]
         * — a 128×128 JPEG at quality 70 lands around 4–8 KB base64.
         */
        const val MAX_ENCODED_BYTES = 16 * 1024

        /**
         * Edge length, in pixels, that avatars are downscaled to before
         * encoding. Sized for a map pin and a member row, not a full-screen view.
         */
        const val TARGET_EDGE = 128

        /** Decode from a JSON string received in an MLS message. */
        fun fromJson(json: String): AvatarPayload {
            val obj = JSONObject(json)
            return AvatarPayload(
                type = obj.optString("type", "avatar"),
                img = obj.optString("img", ""),
                ts = obj.getLong("ts"),
                v = obj.optInt("v", 1)
            )
        }
    }
}
