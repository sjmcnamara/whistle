package org.findmyfam.shared.models

import org.json.JSONObject

/**
 * JSON payload for location updates sent inside kind-445 MLS application messages.
 *
 * Schema (inner kind = MarmotKind.LOCATION / 1):
 * { "type": "location", "lat": 0.0, "lon": 0.0, "alt": 0.0, "acc": 10.0,
 *   "ts": 1700000000, "batt": 87, "interval": 3600, "v": 1 }
 *
 * `interval` is the publisher's own update cadence in seconds. Receivers use
 * it to decide when a pin is stale (typically > 2 × interval since `ts`).
 * Optional for backward compatibility — pre-1.2.1 clients omit it and
 * receivers fall back to their own local interval.
 */
data class LocationPayload(
    val type: String = "location",
    val lat: Double,
    val lon: Double,
    val alt: Double,
    val acc: Double,
    /** Unix timestamp in seconds since epoch. */
    val ts: Long,
    /** Device battery level 0–100, or null if unavailable. */
    val batt: Int? = null,
    /** Publisher's own location interval in seconds, or null if pre-1.2.1. */
    val interval: Int? = null,
    /** Schema version — always 1. */
    val v: Int = 1
) {
    /** Encode to a JSON string for use as MLS message content. */
    fun toJson(): String {
        return JSONObject().apply {
            put("type", type)
            put("lat", lat)
            put("lon", lon)
            put("alt", alt)
            put("acc", acc)
            put("ts", ts)
            batt?.let { put("batt", it) }
            interval?.let { put("interval", it) }
            put("v", v)
        }.toString()
    }

    /** Unix timestamp converted to milliseconds (suitable for java.util.Date). */
    val dateMillis: Long get() = ts * 1000L

    companion object {
        /** Decode from a JSON string received in an MLS message. */
        fun fromJson(json: String): LocationPayload {
            val obj = JSONObject(json)
            return LocationPayload(
                type = obj.optString("type", "location"),
                lat = obj.getDouble("lat"),
                lon = obj.getDouble("lon"),
                alt = obj.getDouble("alt"),
                acc = obj.getDouble("acc"),
                ts = obj.getLong("ts"),
                batt = if (obj.has("batt") && !obj.isNull("batt")) obj.getInt("batt") else null,
                interval = if (obj.has("interval") && !obj.isNull("interval")) obj.getInt("interval") else null,
                v = obj.optInt("v", 1)
            )
        }
    }
}
