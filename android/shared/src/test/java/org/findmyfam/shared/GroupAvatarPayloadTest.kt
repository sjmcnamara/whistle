package org.findmyfam.shared

import org.findmyfam.shared.models.AvatarPayload
import org.findmyfam.shared.models.GroupAvatarPayload
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class GroupAvatarPayloadTest {

    private val sampleImage = "/9j/4AAQSkZJRg=="

    private fun sample(img: String = sampleImage) =
        GroupAvatarPayload(img = img, ts = 1700000000L)

    @Test
    fun `type field is always group_avatar`() {
        assertEquals("group_avatar", sample().type)
    }

    @Test
    fun `type is distinct from member avatar`() {
        // The two ride the same inner kind and are told apart only by `type`.
        // If these ever matched, a member photo would overwrite the group's.
        assertNotEquals(
            AvatarPayload(img = sampleImage, ts = 1L).type,
            sample().type
        )
    }

    @Test
    fun `v field is always 1`() {
        assertEquals(1, sample().v)
    }

    @Test
    fun `round-trips through JSON`() {
        val decoded = GroupAvatarPayload.fromJson(sample().toJson())
        assertEquals(sample(), decoded)
        assertEquals(sampleImage, decoded.img)
        assertEquals(1700000000L, decoded.ts)
    }

    // region removal

    @Test
    fun `empty image is a removal`() {
        assertTrue(sample(img = "").isRemoval)
    }

    @Test
    fun `removal survives round-trip`() {
        assertTrue(GroupAvatarPayload.fromJson(sample(img = "").toJson()).isRemoval)
    }

    // endregion

    // region size ceiling

    @Test
    fun `oversized payload fails size limit`() {
        assertFalse(sample(img = "A".repeat(GroupAvatarPayload.MAX_ENCODED_BYTES + 1)).isWithinSizeLimit)
    }

    @Test
    fun `size limit boundary is inclusive`() {
        assertTrue(sample(img = "A".repeat(GroupAvatarPayload.MAX_ENCODED_BYTES)).isWithinSizeLimit)
    }

    @Test
    fun `limits match member avatar`() {
        // Both travel the same way and must clear the same relay event limits.
        // A divergence would mean one kind of avatar silently failing to publish
        // where the other succeeds.
        assertEquals(AvatarPayload.MAX_ENCODED_BYTES, GroupAvatarPayload.MAX_ENCODED_BYTES)
        assertEquals(AvatarPayload.TARGET_EDGE, GroupAvatarPayload.TARGET_EDGE)
    }

    // endregion

    @Test
    fun `fromJson throws on invalid JSON`() {
        assertFailsWith<Exception> {
            GroupAvatarPayload.fromJson("not valid json {{")
        }
    }
}
