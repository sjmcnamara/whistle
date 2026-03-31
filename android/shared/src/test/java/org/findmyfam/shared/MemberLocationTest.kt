package org.findmyfam.shared

import org.findmyfam.shared.models.LocationPayload
import org.findmyfam.shared.models.MemberLocation
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MemberLocationTest {

    private fun makeLocation(tsOffsetSeconds: Long = 0): MemberLocation {
        val nowSeconds = System.currentTimeMillis() / 1000
        val payload = LocationPayload(
            lat = 51.5074,
            lon = -0.1278,
            alt = 0.0,
            acc = 10.0,
            ts = nowSeconds + tsOffsetSeconds
        )
        return MemberLocation(
            groupId = "groupAbc",
            memberPubkeyHex = "abcdefgh12345678",
            payload = payload
        )
    }

    @Test
    fun `id is groupId colon memberPubkeyHex`() {
        val loc = makeLocation()
        assertEquals("groupAbc:abcdefgh12345678", loc.id)
    }

    @Test
    fun `displayName is first 8 chars plus ellipsis`() {
        val loc = makeLocation()
        assertEquals("abcdefgh…", loc.displayName)
    }

    @Test
    fun `isStale returns true when location is older than 2x interval`() {
        // Location from 3 hours ago, interval is 1 hour (3600s), threshold is 7200s
        val loc = makeLocation(tsOffsetSeconds = -10800L)
        assertTrue(loc.isStale(intervalSeconds = 3600))
    }

    @Test
    fun `isStale returns false when location is recent`() {
        val loc = makeLocation(tsOffsetSeconds = 0L)
        assertFalse(loc.isStale(intervalSeconds = 3600))
    }
}
