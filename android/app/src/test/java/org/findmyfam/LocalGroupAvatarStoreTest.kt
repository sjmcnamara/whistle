package org.findmyfam

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import org.findmyfam.services.LocalGroupAvatarStore
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * Tests for LocalGroupAvatarStore file/cache/removal logic. Parity with iOS
 * LocalGroupAvatarStoreTests.
 *
 * `BitmapFactory.decodeFile` is stubbed so we exercise read/has/remove logic
 * without a real decoder. `setImage` (real stream decode + downscale + JPEG
 * compress) is left to instrumented tests — no graphics stack in JVM `test/`.
 */
class LocalGroupAvatarStoreTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var context: Context
    private lateinit var bitmap: Bitmap
    private val group = "grouplocal-a"
    private val otherGroup = "grouplocal-b"

    @Before
    fun setUp() {
        context = mockk(relaxed = true)
        every { context.filesDir } returns tmp.root

        mockkStatic(BitmapFactory::class)
        bitmap = mockk(relaxed = true)
        every { BitmapFactory.decodeFile(any()) } returns bitmap

        LocalGroupAvatarStore.init(context)
        LocalGroupAvatarStore.removeAll()
    }

    @After
    fun tearDown() {
        LocalGroupAvatarStore.removeAll()
        unmockkStatic(BitmapFactory::class)
    }

    /** Drop a raw file straight into the store's dir to simulate a saved avatar. */
    private fun seedFile(groupId: String) {
        val dir = File(tmp.root, "group_avatars").also { it.mkdirs() }
        File(dir, "$groupId.jpg").writeBytes("local".toByteArray())
    }

    @Test
    fun emptyStore_hasNoImage() {
        assertNull(LocalGroupAvatarStore.image(group))
        assertFalse(LocalGroupAvatarStore.hasImage(group))
    }

    @Test
    fun image_decodesSeededFile() {
        seedFile(group)
        assertTrue(LocalGroupAvatarStore.hasImage(group))
        assertEquals(bitmap, LocalGroupAvatarStore.image(group))
    }

    @Test
    fun groups_areIsolated() {
        seedFile(group)
        assertTrue(LocalGroupAvatarStore.hasImage(group))
        assertFalse(LocalGroupAvatarStore.hasImage(otherGroup))
    }

    @Test
    fun removeImage_clearsGroup() {
        seedFile(group)
        // Prime the cache, then remove.
        LocalGroupAvatarStore.image(group)
        LocalGroupAvatarStore.removeImage(group)

        assertFalse(LocalGroupAvatarStore.hasImage(group))
        assertNull(LocalGroupAvatarStore.image(group))
    }

    @Test
    fun removeAll_clearsEveryGroup() {
        seedFile(group)
        seedFile(otherGroup)

        LocalGroupAvatarStore.removeAll()

        assertFalse(LocalGroupAvatarStore.hasImage(group))
        assertFalse(LocalGroupAvatarStore.hasImage(otherGroup))
    }

    @Test
    fun removeImage_bumpsRevision() {
        seedFile(group)
        val before = LocalGroupAvatarStore.revision.value
        LocalGroupAvatarStore.removeImage(group)
        assertTrue(LocalGroupAvatarStore.revision.value > before)
    }
}
