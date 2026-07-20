package org.findmyfam.services

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.findmyfam.shared.models.GroupAvatarPayload
import timber.log.Timber
import java.io.File
import java.util.Base64
import javax.inject.Inject
import javax.inject.Singleton

/**
 * A group's shared photo — set by an admin and broadcast to every member.
 *
 * Distinct from [LocalGroupAvatarStore], which is a purely personal per-device
 * picture for a group. When both exist the **local one wins**: a member who has
 * chosen their own picture keeps seeing it, and an admin changing the shared
 * photo does not override that choice. Use [resolvedImage] rather than reading
 * either store directly.
 *
 * Stored as JPEGs in filesDir, keyed by MLS group id.
 */
@Singleton
class SharedGroupAvatarStore @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private val dir: File = File(context.filesDir, "shared_group_avatars").also { it.mkdirs() }
    private val cache = HashMap<String, Bitmap>()

    /** Bumped whenever a shared avatar changes so observing composables re-read. */
    private val _revision = MutableStateFlow(0)
    val revision: StateFlow<Int> = _revision.asStateFlow()

    // region read

    fun image(groupId: String): Bitmap? {
        cache[groupId]?.let { return it }
        val file = fileFor(groupId)
        if (!file.exists()) return null
        return BitmapFactory.decodeFile(file.absolutePath)?.also { cache[groupId] = it }
    }

    fun hasImage(groupId: String): Boolean =
        cache.containsKey(groupId) || fileFor(groupId).exists()

    /**
     * The picture to show for a group: a personal override if the user set one,
     * otherwise the admin's shared photo.
     *
     * Single place this precedence is decided — call sites must not reach into
     * either store directly, or the two would drift apart.
     */
    fun resolvedImage(groupId: String): Bitmap? =
        LocalGroupAvatarStore.image(groupId) ?: image(groupId)

    // endregion

    // region inbound

    /**
     * Apply a group-avatar payload received from an admin.
     *
     * The caller is responsible for verifying the sender is an admin — see
     * MarmotService's dispatch. This store does not know about membership.
     */
    fun apply(payload: GroupAvatarPayload, groupId: String) {
        if (payload.isRemoval) {
            remove(groupId)
            return
        }
        val bytes = try {
            Base64.getDecoder().decode(payload.img)
        } catch (e: IllegalArgumentException) {
            Timber.w(e, "Group avatar for $groupId was not valid base64 — ignoring")
            return
        }
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        if (bitmap == null) {
            Timber.w("Group avatar for $groupId was not decodable — ignoring")
            return
        }
        fileFor(groupId).writeBytes(bytes)
        cache[groupId] = bitmap
        _revision.value++
    }

    // endregion

    // region outbound

    /**
     * Store a newly-picked shared photo and return the payload to broadcast, or
     * null if it could not be encoded within the wire cap.
     *
     * Reuses [MemberAvatarStore.encodeForWire] so both avatar kinds are
     * downscaled and quality-stepped identically — they share a size ceiling, so
     * they must share the encoder that respects it.
     */
    fun setImage(uri: Uri, groupId: String): GroupAvatarPayload? {
        val raw = context.contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it)
        } ?: return null
        val encoded = MemberAvatarStore.encodeForWire(raw)
        if (encoded == null) {
            Timber.e("Could not encode group avatar within ${GroupAvatarPayload.MAX_ENCODED_BYTES} bytes")
            return null
        }
        fileFor(groupId).writeBytes(encoded)
        cache[groupId] = BitmapFactory.decodeByteArray(encoded, 0, encoded.size)
        _revision.value++
        return GroupAvatarPayload(
            img = Base64.getEncoder().encodeToString(encoded),
            ts = System.currentTimeMillis() / 1000
        )
    }

    /** Payload announcing removal of the group's photo. Clears locally too. */
    fun removeImagePayload(groupId: String): GroupAvatarPayload {
        remove(groupId)
        return GroupAvatarPayload(img = "", ts = System.currentTimeMillis() / 1000)
    }

    /**
     * The group's current shared photo as a broadcastable payload, or null if
     * none is set. Used to re-announce to a newly joined member.
     */
    fun payload(groupId: String): GroupAvatarPayload? {
        val file = fileFor(groupId)
        if (!file.exists()) return null
        val payload = GroupAvatarPayload(
            img = Base64.getEncoder().encodeToString(file.readBytes()),
            ts = System.currentTimeMillis() / 1000
        )
        return if (payload.isWithinSizeLimit) payload else null
    }

    // endregion

    // region mutate

    fun remove(groupId: String) {
        fileFor(groupId).delete()
        cache.remove(groupId)
        _revision.value++
    }

    /** Clear every stored shared avatar (e.g. on identity burn). */
    fun removeAll() {
        dir.listFiles()?.forEach { it.delete() }
        cache.clear()
        _revision.value++
    }

    // endregion

    private fun fileFor(groupId: String) = File(dir, "$groupId.jpg")
}
