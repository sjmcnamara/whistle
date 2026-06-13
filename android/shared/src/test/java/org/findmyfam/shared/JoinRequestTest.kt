package org.findmyfam.shared

import org.findmyfam.shared.models.JoinRequest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull

class JoinRequestTest {

    private val kp = """{"kind":30443,"content":"<keypackage-hex>","tags":[]}"""

    @Test
    fun `type and version are fixed`() {
        val req = JoinRequest(groupId = "g1", pubkey = "abc", keyPackage = kp)
        assertEquals("join-request", req.type)
        assertEquals(1, req.v)
    }

    @Test
    fun `round-trip with name preserves all fields`() {
        val original = JoinRequest(groupId = "group-hex", pubkey = "pub-hex", keyPackage = kp, name = "Alice")
        val decoded = JoinRequest.fromJson(original.toJson())
        assertEquals(original, decoded)
        assertEquals("Alice", decoded.name)
        assertEquals(kp, decoded.keyPackage)
    }

    @Test
    fun `null name is omitted from the wire form`() {
        val original = JoinRequest(groupId = "g", pubkey = "p", keyPackage = kp)
        val json = original.toJson()
        assertFalse(json.contains("\"name\""))
        val decoded = JoinRequest.fromJson(json)
        assertNull(decoded.name)
        assertEquals(original, decoded)
    }

    @Test
    fun `decode tolerates unknown fields`() {
        val json = """{"type":"join-request","v":1,"groupId":"g","pubkey":"p","keyPackage":"{}","name":"Bo","future":42}"""
        val decoded = JoinRequest.fromJson(json)
        assertEquals("g", decoded.groupId)
        assertEquals("Bo", decoded.name)
    }

    @Test
    fun `decode missing required field throws`() {
        val json = """{"type":"join-request","v":1,"pubkey":"p","keyPackage":"{}"}""" // no groupId
        assertFailsWith<Exception> { JoinRequest.fromJson(json) }
    }
}
