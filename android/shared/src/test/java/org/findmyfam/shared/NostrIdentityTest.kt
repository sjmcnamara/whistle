package org.findmyfam.shared

import org.findmyfam.shared.models.NostrIdentity
import kotlin.test.Test
import kotlin.test.assertEquals

class NostrIdentityTest {

    @Test
    fun `shortNpub truncates long npub correctly`() {
        val identity = NostrIdentity(
            npub = "npub1abc1234567890xyz",
            publicKeyHex = "aabbccddeeff"
        )
        // Length > 16, so should use prefix(10)...suffix(6) format
        assertEquals("npub1abc12...890xyz", identity.shortNpub)
    }

    @Test
    fun `shortNpub returns full npub when 16 chars or fewer`() {
        val identity = NostrIdentity(
            npub = "npub1short",
            publicKeyHex = "aabbccdd"
        )
        assertEquals("npub1short", identity.shortNpub)
    }

    @Test
    fun `shortNpub returns full npub at exactly 16 chars`() {
        val npub = "npub1exactly16ch"
        assertEquals(16, npub.length)
        val identity = NostrIdentity(npub = npub, publicKeyHex = "aabb")
        assertEquals(npub, identity.shortNpub)
    }
}
