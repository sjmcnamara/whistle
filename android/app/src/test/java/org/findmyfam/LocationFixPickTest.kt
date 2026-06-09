package org.findmyfam

import org.findmyfam.services.FixPick
import org.findmyfam.services.pickBestFix
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Tests for the GPS/NETWORK provider selection in LocationService.
 *
 * Without this logic, whichever provider's fix arrives first wins the throttle
 * gate — so a 2km-accurate NETWORK fix could beat a soon-to-arrive 10m GPS fix.
 */
class LocationFixPickTest {

    private val now = 1_000_000L
    private val fresh = 25_000L     // within the 30s default freshness window
    private val stale = 60_000L     // beyond the freshness window

    @Test
    fun `no fixes → NONE`() {
        assertEquals(FixPick.NONE, pickBestFix(null, null, null, null, now))
    }

    @Test
    fun `only GPS available → GPS`() {
        assertEquals(FixPick.GPS, pickBestFix(10f, now, null, null, now))
    }

    @Test
    fun `only NETWORK available → NETWORK`() {
        assertEquals(FixPick.NETWORK, pickBestFix(null, null, 500f, now, now))
    }

    @Test
    fun `both fresh — GPS wins even when NETWORK is more accurate`() {
        // A fresh GPS fix is almost always the right choice for family location;
        // GPS chipsets tend to over-report accuracy when partially obstructed,
        // but a real GPS fix is still preferable to a Wi-Fi triangulation.
        assertEquals(FixPick.GPS, pickBestFix(50f, now - fresh, 20f, now - fresh, now))
    }

    @Test
    fun `both fresh — GPS wins when more accurate`() {
        assertEquals(FixPick.GPS, pickBestFix(8f, now - fresh, 500f, now - fresh, now))
    }

    @Test
    fun `GPS stale, NETWORK fresh → NETWORK`() {
        // This is the indoor / dead-battery-GPS case: phone hasn't seen a
        // satellite in a minute, but Wi-Fi just gave us a location.
        assertEquals(FixPick.NETWORK, pickBestFix(8f, now - stale, 200f, now - fresh, now))
    }

    @Test
    fun `GPS fresh, NETWORK stale → GPS`() {
        assertEquals(FixPick.GPS, pickBestFix(8f, now - fresh, 200f, now - stale, now))
    }

    @Test
    fun `both stale — better accuracy wins (GPS)`() {
        assertEquals(FixPick.GPS, pickBestFix(15f, now - stale, 500f, now - stale, now))
    }

    @Test
    fun `both stale — better accuracy wins (NETWORK)`() {
        assertEquals(FixPick.NETWORK, pickBestFix(800f, now - stale, 200f, now - stale, now))
    }

    @Test
    fun `regression — NETWORK arrives first then GPS arrives 1s later → GPS`() {
        // The original throttle bug: a NETWORK fix arrived and won the gate
        // even though a GPS fix was about to land. With per-provider state and
        // selection on every onLocationChanged, the next call (1s later when
        // GPS arrives) picks GPS regardless of which arrived first.
        val gpsAcc = 8f
        val netAcc = 500f
        val tNet = now - 1_000L
        val tGps = now
        assertEquals(FixPick.GPS, pickBestFix(gpsAcc, tGps, netAcc, tNet, now))
    }

    @Test
    fun `freshness boundary — exactly at window is stale`() {
        // age == freshnessMs is stale (strict `<` in the predicate)
        val freshnessMs = 30_000L
        assertEquals(
            FixPick.NETWORK,
            pickBestFix(8f, now - freshnessMs, 200f, now - (freshnessMs / 2), now, freshnessMs)
        )
    }
}
