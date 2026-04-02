package org.findmyfam

import org.findmyfam.services.PendingWelcomeItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * JVM unit tests for the PendingWelcomeItem data class.
 * Store-level and JSON tests require Android instrumentation
 * due to SharedPreferences / org.json dependency.
 */
class PendingWelcomeItemTest {

    @Test
    fun `data class equality`() {
        val a = PendingWelcomeItem(
            mlsGroupId = "g1",
            senderPubkeyHex = "aa",
            wrapperEventId = "e1",
            receivedAt = 1700000000L
        )
        val b = PendingWelcomeItem(
            mlsGroupId = "g1",
            senderPubkeyHex = "aa",
            wrapperEventId = "e1",
            receivedAt = 1700000000L
        )
        assertEquals(a, b)
    }

    @Test
    fun `data class inequality on different group`() {
        val a = PendingWelcomeItem("g1", "aa", "e1", 1000L)
        val b = PendingWelcomeItem("g2", "aa", "e1", 1000L)
        assertNotEquals(a, b)
    }

    @Test
    fun `data class inequality on different sender`() {
        val a = PendingWelcomeItem("g1", "aa", "e1", 1000L)
        val b = PendingWelcomeItem("g1", "bb", "e1", 1000L)
        assertNotEquals(a, b)
    }

    @Test
    fun `copy preserves unchanged fields`() {
        val original = PendingWelcomeItem("g1", "aa", "e1", 1000L)
        val modified = original.copy(senderPubkeyHex = "bb")
        assertEquals("bb", modified.senderPubkeyHex)
        assertEquals("g1", modified.mlsGroupId)
        assertEquals("e1", modified.wrapperEventId)
        assertEquals(1000L, modified.receivedAt)
    }

    @Test
    fun `hashCode consistent with equals`() {
        val a = PendingWelcomeItem("g1", "aa", "e1", 1000L)
        val b = PendingWelcomeItem("g1", "aa", "e1", 1000L)
        assertEquals(a.hashCode(), b.hashCode())
    }
}
