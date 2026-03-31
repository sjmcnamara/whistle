package org.findmyfam.shared

import org.findmyfam.shared.models.NicknamePayload
import kotlin.test.Test
import kotlin.test.assertEquals

class NicknamePayloadTest {

    @Test
    fun `type field is always nickname`() {
        val payload = NicknamePayload(name = "Dad", ts = 1700000000L)
        assertEquals("nickname", payload.type)
    }

    @Test
    fun `v field is always 1`() {
        val payload = NicknamePayload(name = "Dad", ts = 1700000000L)
        assertEquals(1, payload.v)
    }

    @Test
    fun `round-trip JSON preserves all fields`() {
        val original = NicknamePayload(name = "Mum", ts = 1700000000L)
        val decoded = NicknamePayload.fromJson(original.toJson())

        assertEquals(original.type, decoded.type)
        assertEquals(original.name, decoded.name)
        assertEquals(original.ts, decoded.ts)
        assertEquals(original.v, decoded.v)
    }
}
