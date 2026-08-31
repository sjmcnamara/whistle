package org.findmyfam

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import org.findmyfam.services.MemberAvatarStore
import org.findmyfam.shared.models.AvatarPayload
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.Base64

/**
 * Tests for MemberAvatarStore inbound/payload/removal logic. Parity with iOS
 * MemberAvatarStoreTests (inbound cases).
 *
 * `BitmapFactory` is stubbed statically so the base64/file/cache logic runs
 * without a real decoder. `setOwnImage`/`encodeForWire` (real downscale + JPEG
 * compress) are instrumented-test territory — no graphics stack in JVM `test/`.
 */
class MemberAvatarStoreTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var context: Context
    private lateinit var store: MemberAvatarStore
    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)

    /** Non-empty, valid-base64 bytes (content irrelevant — decode is stubbed). */
    private val validImg = Base64.getEncoder().encodeToString("fake-jpeg-bytes".toByteArray())

    @Before
    fun setUp() {
        context = mockk(relaxed = true)
        every { context.filesDir } returns tmp.root

        mockkStatic(BitmapFactory::class)
        every { BitmapFactory.decodeByteArray(any(), any(), any()) } returns mockk<Bitmap>(relaxed = true)
        every { BitmapFactory.decodeFile(any()) } returns mockk<Bitmap>(relaxed = true)

        store = MemberAvatarStore(context)
    }

    @After
    fun tearDown() {
        unmockkStatic(BitmapFactory::class)
    }

    private fun payload(img: String = validImg) = AvatarPayload(img = img, ts = 1_000L)

    @Test
    fun emptyStore_hasNoImage() {
        assertNull(store.image(alice))
        assertFalse(store.hasImage(alice))
    }

    @Test
    fun apply_validPayload_storesImageAndBumpsRevision() {
        val before = store.revision.value
        store.apply(payload(), alice)

        assertTrue(store.hasImage(alice))
        assertNotNull(store.image(alice))
        assertTrue(store.revision.value > before)
    }

    @Test
    fun apply_removalPayload_clearsImage() {
        store.apply(payload(), alice)
        assertTrue(store.hasImage(alice))

        store.apply(payload(img = ""), alice)  // isRemoval
        assertFalse(store.hasImage(alice))
    }

    @Test
    fun apply_invalidBase64_isIgnored() {
        val before = store.revision.value
        store.apply(payload(img = "!!! not base64 !!!"), alice)

        assertFalse(store.hasImage(alice))
        assertEquals(before, store.revision.value)
    }

    @Test
    fun apply_undecodableImage_isIgnored() {
        every { BitmapFactory.decodeByteArray(any(), any(), any()) } returns null
        store.apply(payload(), alice)
        assertFalse(store.hasImage(alice))
    }

    @Test
    fun apply_isScopedToMember() {
        store.apply(payload(), alice)
        assertTrue(store.hasImage(alice))
        assertFalse(store.hasImage(bob))
    }

    @Test
    fun ownPayload_isNull_whenNothingStored() {
        assertNull(store.ownPayload(alice))
    }

    @Test
    fun ownPayload_roundTripsStoredImage() {
        store.apply(payload(), alice)
        val reread = store.ownPayload(alice)
        assertNotNull(reread)
        assertEquals(validImg, reread?.img)
        assertFalse(reread!!.isRemoval)
    }

    @Test
    fun removeOwnImage_clearsAndAnnouncesRemoval() {
        store.apply(payload(), alice)
        val removal = store.removeOwnImage(alice)

        assertTrue(removal.isRemoval)
        assertFalse(store.hasImage(alice))
    }

    @Test
    fun remove_clearsSingleMember() {
        store.apply(payload(), alice)
        store.apply(payload(), bob)

        store.remove(alice)

        assertFalse(store.hasImage(alice))
        assertTrue(store.hasImage(bob))
    }

    @Test
    fun removeAll_clearsEveryMember() {
        store.apply(payload(), alice)
        store.apply(payload(), bob)

        store.removeAll()

        assertFalse(store.hasImage(alice))
        assertFalse(store.hasImage(bob))
    }
}
