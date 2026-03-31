package org.findmyfam.shared

import org.findmyfam.shared.models.InviteCode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class InviteCodeTest {

    private fun sample() = InviteCode(
        relay = "wss://relay.damus.io",
        inviterNpub = "npub1testabcdef",
        groupId = "group123"
    )

    @Test
    fun `encode then decode round-trip preserves all fields`() {
        val original = sample()
        val encoded = original.encode()
        val decoded = InviteCode.decode(encoded)

        assertEquals(original.relay, decoded.relay)
        assertEquals(original.inviterNpub, decoded.inviterNpub)
        assertEquals(original.groupId, decoded.groupId)
    }

    @Test
    fun `asUri produces famstr invite prefix`() {
        val uri = sample().asUri()
        assertTrue(uri.startsWith("famstr://invite/"))
    }

    @Test
    fun `fromUri parses famstr invite URI correctly`() {
        val original = sample()
        val uri = original.asUri()
        val decoded = InviteCode.fromUri(uri)

        assertEquals(original.relay, decoded.relay)
        assertEquals(original.inviterNpub, decoded.inviterNpub)
        assertEquals(original.groupId, decoded.groupId)
    }

    @Test
    fun `approvalUri produces famstr addmember prefix`() {
        val uri = InviteCode.approvalUri("abcdef1234", "group456")
        assertEquals("famstr://addmember/abcdef1234/group456", uri)
    }

    @Test
    fun `fromUri with raw base64 string works (backward compat)`() {
        val original = sample()
        val rawBase64 = original.encode()
        // Pass raw base64 directly (no famstr:// prefix)
        val decoded = InviteCode.fromUri(rawBase64)

        assertEquals(original.relay, decoded.relay)
        assertEquals(original.inviterNpub, decoded.inviterNpub)
        assertEquals(original.groupId, decoded.groupId)
    }
}
