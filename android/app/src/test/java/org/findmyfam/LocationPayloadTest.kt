package org.findmyfam

import org.findmyfam.shared.models.LocationPayload
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/**
 * Tests for LocationPayload JSON schema, mirroring iOS LocationPayloadTests.
 *
 * Focused on the v1.2.1 addition: an optional `interval` field carrying the
 * publisher's own update cadence so receivers can grade staleness against the
 * publisher's interval, not their own.
 */
class LocationPayloadTest {

    @Test
    fun `interval defaults to null`() {
        val p = LocationPayload(lat = 0.0, lon = 0.0, alt = 0.0, acc = 0.0, ts = 1_700_000_000L)
        assertNull(p.interval)
    }

    @Test
    fun `interval is encoded when set`() {
        val p = LocationPayload(lat = 0.0, lon = 0.0, alt = 0.0, acc = 0.0, ts = 1_700_000_000L, interval = 600)
        val json = JSONObject(p.toJson())
        assertEquals(600, json.getInt("interval"))
    }

    @Test
    fun `interval round-trips through JSON`() {
        val original = LocationPayload(
            lat = -33.8688, lon = 151.2093, alt = 58.0, acc = 3.5,
            ts = 1_710_000_000L, batt = 87, interval = 3600
        )
        val decoded = LocationPayload.fromJson(original.toJson())
        assertEquals(3600, decoded.interval)
        assertEquals(original, decoded)
    }

    @Test
    fun `decode backward-compat payload without interval falls back to null`() {
        // pre-v1.2.1 clients omit the interval field; receivers must accept the
        // payload and fall back to their own local interval for staleness.
        val json = """{"type":"location","lat":0,"lon":0,"alt":0,"acc":0,"ts":1700000000,"v":1}"""
        val p = LocationPayload.fromJson(json)
        assertNull(p.interval)
        assertEquals(1, p.v)
    }

    @Test
    fun `interval omitted from JSON when null`() {
        // Pure-decoder roundtrip should not introduce an interval key on payloads
        // that didn't have one; otherwise pre-1.2.1 clients re-encoding messages
        // would silently downgrade to interval=null instead of preserving the absence.
        val p = LocationPayload(lat = 0.0, lon = 0.0, alt = 0.0, acc = 0.0, ts = 1L, interval = null)
        val json = JSONObject(p.toJson())
        assertFalse("interval key should be omitted when null", json.has("interval"))
    }
}
