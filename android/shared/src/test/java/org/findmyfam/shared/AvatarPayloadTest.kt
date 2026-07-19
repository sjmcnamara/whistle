package org.findmyfam.shared

import org.findmyfam.shared.models.AvatarPayload
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AvatarPayloadTest {

    private val sampleImage = "/9j/4AAQSkZJRg=="

    private fun sample(img: String = sampleImage) =
        AvatarPayload(img = img, ts = 1700000000L)

    @Test
    fun `type field is always avatar`() {
        assertEquals("avatar", sample().type)
    }

    @Test
    fun `v field is always 1`() {
        assertEquals(1, sample().v)
    }

    @Test
    fun `round-trips through JSON`() {
        val decoded = AvatarPayload.fromJson(sample().toJson())
        assertEquals(sample(), decoded)
        assertEquals(sampleImage, decoded.img)
        assertEquals(1700000000L, decoded.ts)
    }

    // region removal sentinel

    @Test
    fun `empty image is a removal`() {
        assertTrue(sample(img = "").isRemoval)
    }

    @Test
    fun `non-empty image is not a removal`() {
        assertFalse(sample().isRemoval)
    }

    @Test
    fun `removal survives round-trip`() {
        // A removal must stay distinguishable from a set — receivers clear the
        // stored image on this rather than ignoring the message.
        assertTrue(AvatarPayload.fromJson(sample(img = "").toJson()).isRemoval)
    }

    // endregion

    // region size ceiling

    @Test
    fun `typical avatar is within size limit`() {
        // ~6 KB base64 — representative of a 128x128 JPEG at quality 70.
        assertTrue(sample(img = "A".repeat(6 * 1024)).isWithinSizeLimit)
    }

    @Test
    fun `oversized avatar fails size limit`() {
        assertFalse(sample(img = "A".repeat(AvatarPayload.MAX_ENCODED_BYTES + 1)).isWithinSizeLimit)
    }

    @Test
    fun `size limit boundary is inclusive`() {
        assertTrue(sample(img = "A".repeat(AvatarPayload.MAX_ENCODED_BYTES)).isWithinSizeLimit)
    }

    @Test
    fun `removal is always within size limit`() {
        assertTrue(sample(img = "").isWithinSizeLimit)
    }

    // endregion

    @Test
    fun `fromJson throws on invalid JSON`() {
        assertFailsWith<Exception> {
            AvatarPayload.fromJson("not valid json {{")
        }
    }

    @Test
    fun `size limits match the iOS constants`() {
        // The two platforms must agree on the wire budget, or one can publish
        // an avatar the other's relay path rejects.
        assertEquals(16 * 1024, AvatarPayload.MAX_ENCODED_BYTES)
        assertEquals(128, AvatarPayload.TARGET_EDGE)
    }
}
