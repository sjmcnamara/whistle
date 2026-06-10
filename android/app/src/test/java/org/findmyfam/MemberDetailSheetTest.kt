package org.findmyfam

import org.findmyfam.ui.map.formatCadence
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Tests for the cadence formatter used by the member detail sheet
 * (Android v1.3.0 — surfaces `LocationPayload.interval` on pin tap).
 */
class MemberDetailSheetTest {

    @Test
    fun `sub-minute renders as seconds`() {
        assertEquals("10 sec", formatCadence(10))
        assertEquals("1 sec", formatCadence(1))
        assertEquals("59 sec", formatCadence(59))
    }

    @Test
    fun `whole minutes render as minutes`() {
        assertEquals("1 min", formatCadence(60))
        assertEquals("5 min", formatCadence(300))
        assertEquals("59 min", formatCadence(59 * 60))
    }

    @Test
    fun `whole hours render as hours`() {
        assertEquals("1 hour", formatCadence(3600))
        assertEquals("2 hours", formatCadence(7200))
    }

    @Test
    fun `mixed hours and minutes render together`() {
        assertEquals("1 hr 30 min", formatCadence(5400))
        assertEquals("2 hr 15 min", formatCadence(2 * 3600 + 15 * 60))
    }

    @Test
    fun `zero seconds renders as zero seconds`() {
        // Edge case — interval=0 shouldn't happen in practice but should not crash.
        assertEquals("0 sec", formatCadence(0))
    }
}
