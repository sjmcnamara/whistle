package org.findmyfam.services

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File

/**
 * Local, per-user, per-device group avatars.
 *
 * Not shared with other members and not synced — purely a personal label on
 * your own view of a group. Stored as downscaled JPEGs in filesDir, keyed by
 * MLS group id. Call [init] from Application.onCreate() before use.
 *
 * (A future shared admin-controlled avatar can take precedence over this when it ships.)
 */
object LocalGroupAvatarStore {

    private const val MAX_DIMENSION = 256

    private lateinit var dir: File
    private val cache = HashMap<String, Bitmap>()

    private val _revision = MutableStateFlow(0)
    val revision: StateFlow<Int> = _revision.asStateFlow()

    fun init(context: Context) {
        dir = File(context.filesDir, "group_avatars").also { it.mkdirs() }
    }

    // MARK: - Read

    fun image(groupId: String): Bitmap? {
        cache[groupId]?.let { return it }
        val file = fileFor(groupId)
        if (!file.exists()) return null
        return BitmapFactory.decodeFile(file.absolutePath)?.also { cache[groupId] = it }
    }

    fun hasImage(groupId: String): Boolean =
        cache.containsKey(groupId) || fileFor(groupId).exists()

    // MARK: - Write

    fun setImage(context: Context, groupId: String, uri: Uri) {
        val rotation = context.contentResolver.openInputStream(uri)?.use { stream ->
            val exif = ExifInterface(stream)
            when (exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } ?: 0f

        val raw = context.contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it)
        } ?: return

        val upright = if (rotation != 0f) {
            Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, Matrix().apply { postRotate(rotation) }, true)
        } else raw

        val scaled = downscale(upright)
        fileFor(groupId).outputStream().use { out ->
            scaled.compress(Bitmap.CompressFormat.JPEG, 80, out)
        }
        cache[groupId] = scaled
        _revision.value++
    }

    fun removeImage(groupId: String) {
        fileFor(groupId).delete()
        cache.remove(groupId)
        _revision.value++
    }

    fun removeAll() {
        dir.listFiles()?.forEach { it.delete() }
        cache.clear()
        _revision.value++
    }

    // MARK: - Private

    private fun fileFor(groupId: String) = File(dir, "$groupId.jpg")

    private fun downscale(src: Bitmap): Bitmap {
        val longest = maxOf(src.width, src.height)
        if (longest <= MAX_DIMENSION) return src
        val scale = MAX_DIMENSION.toFloat() / longest
        return Bitmap.createScaledBitmap(
            src,
            (src.width * scale).toInt(),
            (src.height * scale).toInt(),
            true
        )
    }
}
