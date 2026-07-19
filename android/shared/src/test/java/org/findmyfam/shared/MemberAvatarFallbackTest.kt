package org.findmyfam.shared

import org.findmyfam.shared.models.MemberAvatarFallback
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MemberAvatarFallbackTest {

    // region initials

    @Test
    fun `single word name takes first letter`() {
        assertEquals("D", MemberAvatarFallback.initials("Dad"))
    }

    @Test
    fun `two word name takes both initials`() {
        assertEquals("JS", MemberAvatarFallback.initials("Jane Smith"))
    }

    @Test
    fun `long name takes only first two`() {
        assertEquals("MJ", MemberAvatarFallback.initials("Mary Jane Watson Parker"))
    }

    @Test
    fun `initials are uppercased`() {
        assertEquals("JS", MemberAvatarFallback.initials("jane smith"))
    }

    @Test
    fun `extra whitespace is ignored`() {
        assertEquals("JS", MemberAvatarFallback.initials("  Jane   Smith  "))
    }

    @Test
    fun `name with no letters falls back to question mark`() {
        // Nicknames are free-form — an emoji-only or punctuation-only name must
        // not produce an empty circle.
        assertEquals("?", MemberAvatarFallback.initials("🎉"))
        assertEquals("?", MemberAvatarFallback.initials("!!!"))
        assertEquals("?", MemberAvatarFallback.initials(""))
    }

    @Test
    fun `leading non-letter is skipped within word`() {
        assertEquals("D", MemberAvatarFallback.initials("@dave"))
    }

    // endregion

    // region colour

    @Test
    fun `colour index is stable for the same key`() {
        val key = "a".repeat(64)
        assertEquals(
            MemberAvatarFallback.colorIndex(key),
            MemberAvatarFallback.colorIndex(key)
        )
    }

    @Test
    fun `colour index is always within the palette`() {
        for (i in 0 until 50) {
            val index = MemberAvatarFallback.colorIndex(pubkey(i))
            assertTrue(index in 0 until MemberAvatarFallback.PALETTE_SIZE, "index $index out of range")
        }
    }

    @Test
    fun `colour index spreads across the palette`() {
        val indices = (0 until 60).map { MemberAvatarFallback.colorIndex(pubkey(it)) }.toSet()
        // A plain byte-sum collapsed every uniform 64-char key onto index 0,
        // because the palette size divides 64. Require real spread, not just
        // "more than one value".
        assertTrue(indices.size >= 4, "poor palette spread: $indices")
    }

    @Test
    fun `uniform keys do not all collide`() {
        // The exact degeneracy that a byte-sum had: 64 identical characters.
        val indices = "0123456789abcdef".map { MemberAvatarFallback.colorIndex(it.toString().repeat(64)) }
        assertTrue(indices.toSet().size > 1, "uniform keys all collide: $indices")
    }

    @Test
    fun `colour index matches the FNV-1a reference`() {
        // Pinned so iOS and Android cannot drift apart — the same member must
        // get the same colour on both platforms.
        val key = "deadbeef" + "0".repeat(56)
        var hash = 2166136261u
        for (b in key.toByteArray(Charsets.UTF_8)) {
            hash = hash xor (b.toInt() and 0xFF).toUInt()
            hash *= 16777619u
        }
        assertEquals(((hash shr 24) % 8u).toInt(), MemberAvatarFallback.colorIndex(key))
    }

    /** A realistic-looking distinct 64-char hex pubkey for index [i]. */
    private fun pubkey(i: Int): String =
        i.toString(16).padStart(4, '0').repeat(16)

    // endregion
}
