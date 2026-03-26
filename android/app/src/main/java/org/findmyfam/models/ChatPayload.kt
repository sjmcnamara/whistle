package org.findmyfam.models

import org.json.JSONObject

/**
 * JSON payload for chat messages sent inside kind-445 MLS application messages.
 *
 * Schema (inner kind = MarmotKind.chat / 9):
 * { "type": "chat", "text": "Hello!", "ts": 1700000000, "v": 1 }
 */
data class ChatPayload(
    val type: String = "chat",
    val text: String,
    val ts: Long,
    val v: Int = 1
) {
    constructor(text: String) : this(
        type = "chat",
        text = text,
        ts = System.currentTimeMillis() / 1000,
        v = 1
    )

    fun toJson(): String {
        return JSONObject().apply {
            put("type", type)
            put("text", text)
            put("ts", ts)
            put("v", v)
        }.toString()
    }

    companion object {
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
