package org.findmyfam.shared

import org.findmyfam.shared.models.LocationPayload
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull

class LocationPayloadTest {

    private fun sample() = LocationPayload(
        lat = 51.5074,
        lon = -0.1278,
        alt = 10.0,
        acc = 5.0,
        ts = 1700000000L
    )

    @Test
    fun `type field is always location`() {
        assertEquals("location", sample().type)
    }

    @Test
    fun `v field is always 1`() {
        assertEquals(1, sample().v)
    }

    @Test
    fun `round-trip JSON preserves all fields`() {
        val original = sample()
        val json = original.toJson()
        val decoded = LocationPayload.fromJson(json)

        assertEquals(original.type, decoded.type)
        assertEquals(original.lat, decoded.lat)
        assertEquals(original.lon, decoded.lon)
        assertEquals(original.alt, decoded.alt)
        assertEquals(original.acc, decoded.acc)
        assertEquals(original.ts, decoded.ts)
        assertEquals(original.v, decoded.v)
    }

    @Test
    fun `dateMillis converts ts correctly`() {
        val payload = sample()
        assertEquals(1700000000L * 1000L, payload.dateMillis)
    }

    @Test
    fun `fromJson throws on invalid JSON`() {
        assertFailsWith<Exception> {
            LocationPayload.fromJson("not valid json {{")
        }
    }

    // region stationary (v1.7)

    @Test
    fun `stationary defaults to null`() {
        assertNull(sample().stationary)
    }

    @Test
    fun `stationary is omitted from JSON when null`() {
        // Must be absent, not "stationary":null — receivers distinguish
        // "unknown" from an explicit value.
        assertFalse(sample().toJson().contains("stationary"))
    }

    @Test
    fun `stationary round-trips true and false`() {
        for (value in listOf(true, false)) {
            val original = sample().copy(batt = 87, interval = 3600, stationary = value)
            val decoded = LocationPayload.fromJson(original.toJson())
            assertEquals(value, decoded.stationary)
            assertEquals(original, decoded)
        }
    }

    @Test
    fun `payload without stationary decodes as null not false`() {
        // pre-v1.7 clients omit the field. Null means "unknown"; false would
        // claim the member is known to be moving.
        val json = """
            {"type":"location","lat":0,"lon":0,"alt":0,"acc":0,"ts":1700000000,"interval":3600,"v":1}
        """.trimIndent()
        val payload = LocationPayload.fromJson(json)
        assertNull(payload.stationary)
        assertNotEquals<Boolean?>(false, payload.stationary)
    }

    @Test
    fun `explicit false is distinct from omitted`() {
        val explicit = sample().copy(stationary = false)
        val omitted = sample()
        assertNotEquals(explicit, omitted)
        assertEquals(false, LocationPayload.fromJson(explicit.toJson()).stationary)
        assertNull(LocationPayload.fromJson(omitted.toJson()).stationary)
    }

    // endregion
}
