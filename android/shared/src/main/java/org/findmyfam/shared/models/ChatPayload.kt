package org.findmyfam.shared.models

import org.json.JSONObject

/**
 * JSON payload for chat messages sent inside kind-445 MLS application messages.
 *
 * Schema (inner kind = MarmotKind.CHAT / 9):
 * { "type": "chat", "text": "Hello!", "ts": 1700000000, "v": 1 }
 */
data class ChatPayload(
    val type: String = "chat",
    val text: String,
    /** Unix timestamp in seconds since epoch. */
    val ts: Long,
    /** Schema version — always 1. */
    val v: Int = 1
) {
    constructor(text: String) : this(
        type = "chat",
        text = text,
        ts = System.currentTimeMillis() / 1000,
        v = 1
    )

    /** Encode to a JSON string for use as MLS message content. */
    fun toJson(): String {
        return JSONObject().apply {
            put("type", type)
            put("text", text)
            put("ts", ts)
            put("v", v)
        }.toString()
    }

    /** Unix timestamp converted to milliseconds (suitable for java.util.Date). */
    val dateMillis: Long get() = ts * 1000L

    companion object {
        /** Decode from a JSON string received in an MLS message. */
        fun fromJson(json: String): ChatPayload {
            val obj = JSONObject(json)
            return ChatPayload(
                type = obj.optString("type", "chat"),
                text = obj.getString("text"),
                ts = obj.getLong("ts"),
                v = obj.optInt("v", 1)
            )
        }
    }
}
