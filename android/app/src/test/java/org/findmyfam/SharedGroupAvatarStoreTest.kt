package org.findmyfam

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import org.findmyfam.services.LocalGroupAvatarStore
import org.findmyfam.services.SharedGroupAvatarStore
import org.findmyfam.shared.models.GroupAvatarPayload
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.Base64

/**
 * Tests for SharedGroupAvatarStore inbound/payload/removal/precedence logic.
 * Parity with iOS SharedGroupAvatarStoreTests.
 *
 * `BitmapFactory` is stubbed statically so we exercise the store's base64 /
 * file / cache / precedence logic without a real image decoder. Real encode
 * fidelity (`setImage`) is left to instrumented tests — the JVM `test/`
 * sourceset has no Android graphics stack.
 */
class SharedGroupAvatarStoreTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var context: Context
    private lateinit var store: SharedGroupAvatarStore
    private lateinit var sharedBitmap: Bitmap
    private lateinit var localBitmap: Bitmap
    private val group = "abc123group"
    private val otherGroup = "def456group"

    /** base64 of some non-empty, valid-base64 bytes (content is irrelevant — decode is stubbed). */
    private val validImg = Base64.getEncoder().encodeToString("fake-jpeg-bytes".toByteArray())

    @Before
    fun setUp() {
        context = mockk(relaxed = true)
        every { context.filesDir } returns tmp.root

        mockkStatic(BitmapFactory::class)
        // Distinct instances so precedence assertions can tell them apart.
        sharedBitmap = mockk(relaxed = true)
        localBitmap = mockk(relaxed = true)
        every { BitmapFactory.decodeByteArray(any(), any(), any()) } returns sharedBitmap
        every { BitmapFactory.decodeFile(any()) } returns localBitmap

        LocalGroupAvatarStore.init(context)
        LocalGroupAvatarStore.removeAll()
        store = SharedGroupAvatarStore(context)
    }

    /** Drop a raw file straight into the local-avatar dir so LocalGroupAvatarStore.image decodes it. */
    private fun seedLocalFile(groupId: String) {
        val localDir = java.io.File(tmp.root, "group_avatars").also { it.mkdirs() }
        java.io.File(localDir, "$groupId.jpg").writeBytes("local".toByteArray())
    }

    @After
    fun tearDown() {
        unmockkStatic(BitmapFactory::class)
    }

    private fun payload(img: String = validImg) = GroupAvatarPayload(img = img, ts = 1_000L)

    // MARK: - Empty state

    @Test
    fun emptyStore_hasNoImage() {
        assertNull(store.image(group))
        assertFalse(store.hasImage(group))
    }

    // MARK: - apply (inbound)

    @Test
    fun apply_validPayload_storesImageAndBumpsRevision() {
        val before = store.revision.value
        store.apply(payload(), group)

        assertTrue(store.hasImage(group))
        assertNotNull(store.image(group))
        assertTrue("applying an avatar must bump revision", store.revision.value > before)
    }

    @Test
    fun apply_removalPayload_clearsImage() {
        store.apply(payload(), group)
        assertTrue(store.hasImage(group))

        store.apply(payload(img = ""), group)  // isRemoval
        assertFalse(store.hasImage(group))
        assertNull(store.image(group))
    }

    @Test
    fun apply_invalidBase64_isIgnored() {
        val before = store.revision.value
        store.apply(payload(img = "!!! not base64 !!!"), group)

        assertFalse(store.hasImage(group))
        assertEquals("an undecodable payload must not bump revision", before, store.revision.value)
    }

    @Test
    fun apply_undecodableImage_isIgnored() {
        every { BitmapFactory.decodeByteArray(any(), any(), any()) } returns null
        store.apply(payload(), group)
        assertFalse(store.hasImage(group))
    }

    @Test
    fun apply_isScopedToGroup() {
        store.apply(payload(), group)
        assertTrue(store.hasImage(group))
        assertFalse(store.hasImage(otherGroup))
    }

    // MARK: - payload(for:) re-broadcast

    @Test
    fun payload_isNull_whenNothingStored() {
        assertNull(store.payload(group))
    }

    @Test
    fun payload_roundTripsStoredImage() {
        store.apply(payload(), group)
        val reread = store.payload(group)
        assertNotNull(reread)
        // Re-reading for a join re-announce must yield the same bytes we stored.
        assertEquals(validImg, reread?.img)
        assertFalse(reread!!.isRemoval)
    }

    // MARK: - removeImagePayload

    @Test
    fun removeImagePayload_clearsAndAnnouncesRemoval() {
        store.apply(payload(), group)
        val removal = store.removeImagePayload(group)

        assertTrue(removal.isRemoval)
        assertFalse(store.hasImage(group))
    }

    // MARK: - remove / removeAll

    @Test
    fun remove_clearsSingleGroup() {
        store.apply(payload(), group)
        store.apply(payload(), otherGroup)

        store.remove(group)

        assertFalse(store.hasImage(group))
        assertTrue(store.hasImage(otherGroup))
    }

    @Test
    fun removeAll_clearsEveryGroup() {
        store.apply(payload(), group)
        store.apply(payload(), otherGroup)

        store.removeAll()

        assertFalse(store.hasImage(group))
        assertFalse(store.hasImage(otherGroup))
    }

    // MARK: - resolvedImage precedence

    @Test
    fun resolvedImage_prefersLocalOverShared() {
        store.apply(payload(), group)   // shared present (sharedBitmap)
        seedLocalFile(group)            // local present (localBitmap)

        assertEquals("local override must win over the admin's shared photo",
            localBitmap, store.resolvedImage(group))
    }

    @Test
    fun resolvedImage_fallsBackToShared_whenNoLocal() {
        store.apply(payload(), group)
        assertEquals(sharedBitmap, store.resolvedImage(group))
    }

    @Test
    fun resolvedImage_isNull_whenNeitherSet() {
        assertNull(store.resolvedImage(group))
    }
}
