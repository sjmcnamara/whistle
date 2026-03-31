package org.findmyfam.shared

import org.findmyfam.shared.models.LocationPayload
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

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
}
