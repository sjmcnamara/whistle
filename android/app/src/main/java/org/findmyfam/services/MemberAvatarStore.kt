package org.findmyfam.services

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.findmyfam.shared.models.AvatarPayload
import timber.log.Timber
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.Base64
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Member avatars, keyed by Nostr public key hex.
 *
 * Unlike [LocalGroupAvatarStore] — which is a purely personal, per-device touch
 * — these *are* shared: your own avatar is broadcast to every active group as an
 * [AvatarPayload] inside an MLS application message, and other members' avatars
 * arrive the same way. Stored as downscaled JPEGs in filesDir, exactly as group
 * avatars are.
 *
 * Received images are held on the same footing as your own. There is no separate
 * "mine" vs "theirs" storage: the pubkey is the key, and your own entry is simply
 * the one matching your identity.
 */
@Singleton
class MemberAvatarStore @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private val dir: File = File(context.filesDir, "member_avatars").also { it.mkdirs() }
    private val cache = HashMap<String, Bitmap>()

    /** Bumped whenever any avatar changes so observing composables re-read. */
    private val _revision = MutableStateFlow(0)
    val revision: StateFlow<Int> = _revision.asStateFlow()

    // region read

    fun image(pubkeyHex: String): Bitmap? {
        cache[pubkeyHex]?.let { return it }
        val file = fileFor(pubkeyHex)
        if (!file.exists()) return null
        return BitmapFactory.decodeFile(file.absolutePath)?.also { cache[pubkeyHex] = it }
    }

    fun hasImage(pubkeyHex: String): Boolean =
        cache.containsKey(pubkeyHex) || fileFor(pubkeyHex).exists()

    // endregion

    // region inbound

    /**
     * Apply an avatar payload received from another member.
     *
     * A removal payload (empty img) clears the stored image rather than being
     * ignored, so "I deleted my avatar" actually propagates.
     */
    fun apply(payload: AvatarPayload, from: String) {
        if (payload.isRemoval) {
            remove(from)
            return
        }
        val bytes = try {
            Base64.getDecoder().decode(payload.img)
        } catch (e: IllegalArgumentException) {
            Timber.w(e, "Avatar from ${from.take(8)} was not valid base64 — ignoring")
            return
        }
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        if (bitmap == null) {
            Timber.w("Avatar from ${from.take(8)} was not decodable — ignoring")
            return
        }
        fileFor(from).writeBytes(bytes)
        cache[from] = bitmap
        _revision.value++
    }

    // endregion

    // region outbound

    /**
     * Store a newly-picked image for the local user and return the payload to
     * broadcast, or null if it could not be encoded within the wire cap.
     *
     * The stored copy is the *same* bytes that go on the wire, so what other
     * members see matches what we show for ourselves.
     */
    fun setOwnImage(uri: Uri, pubkeyHex: String): AvatarPayload? {
        val bitmap = decodeUpright(uri) ?: return null
        val encoded = encodeForWire(bitmap)
        if (encoded == null) {
            Timber.e("Could not encode avatar within ${AvatarPayload.MAX_ENCODED_BYTES} bytes")
            return null
        }
        fileFor(pubkeyHex).writeBytes(encoded)
        cache[pubkeyHex] = BitmapFactory.decodeByteArray(encoded, 0, encoded.size)
        _revision.value++
        return AvatarPayload(
            img = Base64.getEncoder().encodeToString(encoded),
            ts = System.currentTimeMillis() / 1000
        )
    }

    /** Payload announcing removal of the local user's avatar. Clears locally too. */
    fun removeOwnImage(pubkeyHex: String): AvatarPayload {
        remove(pubkeyHex)
        return AvatarPayload(img = "", ts = System.currentTimeMillis() / 1000)
    }

    /**
     * The local user's current avatar as a broadcastable payload, or null if
     * none is set. Used to re-announce on joining a new group.
     */
    fun ownPayload(pubkeyHex: String): AvatarPayload? {
        val file = fileFor(pubkeyHex)
        if (!file.exists()) return null
        val payload = AvatarPayload(
            img = Base64.getEncoder().encodeToString(file.readBytes()),
            ts = System.currentTimeMillis() / 1000
        )
        return if (payload.isWithinSizeLimit) payload else null
    }

    // endregion

    // region mutate

    fun remove(pubkeyHex: String) {
        fileFor(pubkeyHex).delete()
        cache.remove(pubkeyHex)
        _revision.value++
    }

    /** Clear every stored avatar (e.g. on identity burn). */
    fun removeAll() {
        dir.listFiles()?.forEach { it.delete() }
        cache.clear()
        _revision.value++
    }

    // endregion

    // region encoding

    /**
     * Downscale to [AvatarPayload.TARGET_EDGE] and JPEG-encode, stepping quality
     * down until the base64 form fits [AvatarPayload.MAX_ENCODED_BYTES].
     *
     * The size check is on the *base64* length, not the JPEG length, because
     * that is what actually travels — base64 inflates by roughly 4/3, and
     * checking the wrong one would let an oversized event reach the relay.
     * Returns null if even the lowest quality will not fit, so callers can
     * refuse rather than publish something a relay may silently drop.
     */
    private fun decodeUpright(uri: Uri): Bitmap? {
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
        } ?: return null

        return if (rotation != 0f) {
            Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, Matrix().apply { postRotate(rotation) }, true)
        } else {
            raw
        }
    }

    // endregion

    private fun fileFor(pubkeyHex: String) = File(dir, "$pubkeyHex.jpg")

    companion object {
    fun encodeForWire(bitmap: Bitmap): ByteArray? {
        val scaled = downscale(bitmap)
        for (quality in QUALITY_STEPS) {
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, quality, out)
            val bytes = out.toByteArray()
            if (Base64.getEncoder().encodeToString(bytes).toByteArray(Charsets.UTF_8).size
                <= AvatarPayload.MAX_ENCODED_BYTES
            ) {
                return bytes
            }
        }
        return null
    }

    private fun downscale(src: Bitmap): Bitmap {
        val longest = maxOf(src.width, src.height)
        if (longest <= AvatarPayload.TARGET_EDGE) return src
        val scale = AvatarPayload.TARGET_EDGE.toFloat() / longest
        return Bitmap.createScaledBitmap(
            src,
            (src.width * scale).toInt(),
            (src.height * scale).toInt(),
            true
        )
    }

        /** Mirrors the iOS quality ladder in MemberAvatarStore.encodeForWire. */
        private val QUALITY_STEPS = listOf(70, 60, 50, 40, 30, 20)
    }
}
