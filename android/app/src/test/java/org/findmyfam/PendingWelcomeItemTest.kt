package org.findmyfam

import org.findmyfam.services.PendingWelcomeItem
import org.json.JSONObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

/**
 * JVM unit tests for the PendingWelcomeItem data class.
 * Store-level tests (add/remove/persistence) require Android instrumentation
 * due to SharedPreferences dependency.
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
    fun `json round-trip`() {
        val original = PendingWelcomeItem(
            mlsGroupId = "group-abc",
            senderPubkeyHex = "deadbeef",
            wrapperEventId = "event-42",
            receivedAt = 1700000000L
        )
        val json = JSONObject().apply {
            put("mlsGroupId", original.mlsGroupId)
            put("senderPubkeyHex", original.senderPubkeyHex)
            put("wrapperEventId", original.wrapperEventId)
            put("receivedAt", original.receivedAt)
        }
        val decoded = PendingWelcomeItem(
            mlsGroupId = json.getString("mlsGroupId"),
            senderPubkeyHex = json.getString("senderPubkeyHex"),
            wrapperEventId = json.getString("wrapperEventId"),
            receivedAt = json.getLong("receivedAt")
        )
        assertEquals(original, decoded)
    }

    @Test
    fun `copy with different sender`() {
        val original = PendingWelcomeItem("g1", "aa", "e1", 1000L)
        val modified = original.copy(senderPubkeyHex = "bb")
        assertEquals("bb", modified.senderPubkeyHex)
        assertEquals("g1", modified.mlsGroupId)
    }
}
