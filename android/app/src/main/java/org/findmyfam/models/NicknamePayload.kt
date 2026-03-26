package org.findmyfam.models

import org.json.JSONObject

/**
 * JSON payload for nickname broadcasts inside kind-445 MLS application messages.
 *
 * Sent as an inner kind-9 message (same as chat) with a different "type" field.
 * { "type": "nickname", "name": "Dad", "ts": 1700000000, "v": 1 }
 */
data class NicknamePayload(
    val type: String = "nickname",
    val name: String,
    val ts: Long,
    val v: Int = 1
) {
    constructor(name: String) : this(
        type = "nickname",
        name = name,
        ts = System.currentTimeMillis() / 1000,
        v = 1
    )

    fun toJson(): String {
        return JSONObject().apply {
            put("type", type)
            put("name", name)
            put("ts", ts)
            put("v", v)
        }.toString()
    }

    companion object {
        fun fromJson(json: String): NicknamePayload {
            val obj = JSONObject(json)
            return NicknamePayload(
                type = obj.optString("type", "nickname"),
                name = obj.getString("name"),
                ts = obj.getLong("ts"),
                v = obj.optInt("v", 1)
            )
        }
    }
}
