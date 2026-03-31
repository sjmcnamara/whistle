package org.findmyfam.shared

import org.findmyfam.shared.models.ChatPayload
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ChatPayloadTest {

    @Test
    fun `type field is always chat`() {
        val payload = ChatPayload(text = "Hello!", ts = 1700000000L)
        assertEquals("chat", payload.type)
    }

    @Test
    fun `v field is always 1`() {
        val payload = ChatPayload(text = "Hello!", ts = 1700000000L)
        assertEquals(1, payload.v)
    }

    @Test
    fun `round-trip JSON preserves all fields`() {
        val original = ChatPayload(text = "Hello, world!", ts = 1700000000L)
        val decoded = ChatPayload.fromJson(original.toJson())

        assertEquals(original.type, decoded.type)
        assertEquals(original.text, decoded.text)
        assertEquals(original.ts, decoded.ts)
        assertEquals(original.v, decoded.v)
    }

    @Test
    fun `convenience constructor sets ts to now`() {
        val before = System.currentTimeMillis() / 1000
        val payload = ChatPayload("hi")
        val after = System.currentTimeMillis() / 1000
        assertTrue(payload.ts in before..after)
    }

    @Test
    fun `dateMillis converts ts correctly`() {
        val payload = ChatPayload(text = "hi", ts = 1700000000L)
        assertEquals(1700000000L * 1000L, payload.dateMillis)
    }
}
