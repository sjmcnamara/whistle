package org.findmyfam.services

import android.content.Context
import android.content.SharedPreferences
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.findmyfam.models.PendingInvite
import org.json.JSONArray
import org.json.JSONObject
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Persists pending group invites -- invites where the user has published
 * their key package but hasn't yet received a Welcome event.
 *
 * SharedPreferences-backed so pending state survives app restarts.
 */
@Singleton
class PendingInviteStore @Inject constructor(
    @ApplicationContext context: Context
) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("fmf_pending_invites", Context.MODE_PRIVATE)

    private val _pendingInvites = MutableStateFlow<List<PendingInvite>>(emptyList())
    val pendingInvites: StateFlow<List<PendingInvite>> = _pendingInvites.asStateFlow()

    init {
        load()
    }

    /**
     * Record a new pending invite.
     */
    fun add(invite: PendingInvite) {
        if (_pendingInvites.value.any { it.groupHint == invite.groupHint }) return
        _pendingInvites.value = _pendingInvites.value + invite
        save()
        Timber.i("PendingInviteStore: added invite for group ${invite.groupHint}")
    }

    /**
     * Remove a pending invite by group hint (e.g. when a Welcome is received).
     */
    fun remove(groupHint: String) {
        _pendingInvites.value = _pendingInvites.value.filter { it.groupHint != groupHint }
        save()
        Timber.i("PendingInviteStore: removed invite for group $groupHint")
    }

    /**
     * Remove all pending invites.
     */
    fun removeAll() {
        _pendingInvites.value = emptyList()
        save()
    }

    /**
     * Remove invites that match any of the given active group IDs.
     * Called after receiving Welcomes to clean up resolved invites.
     */
    fun removeResolved(activeGroupIds: Set<String>) {
        val before = _pendingInvites.value.size
        _pendingInvites.value = _pendingInvites.value.filter { it.groupHint !in activeGroupIds }
        val removed = before - _pendingInvites.value.size
        if (removed > 0) {
            save()
            Timber.i("PendingInviteStore: auto-removed $removed resolved invite(s)")
        }
    }

    // --- Persistence ---

    private fun save() {
        val arr = JSONArray()
        for (invite in _pendingInvites.value) {
            arr.put(JSONObject().apply {
                put("groupHint", invite.groupHint)
                put("inviterNpub", invite.inviterNpub)
                put("createdAt", invite.createdAt)
            })
        }
        prefs.edit().putString(STORAGE_KEY, arr.toString()).apply()
    }

    private fun load() {
        val json = prefs.getString(STORAGE_KEY, null) ?: return
        try {
            val arr = JSONArray(json)
            val list = mutableListOf<PendingInvite>()
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                list.add(
                    PendingInvite(
                        groupHint = obj.getString("groupHint"),
                        inviterNpub = obj.getString("inviterNpub"),
                        createdAt = obj.getLong("createdAt")
                    )
                )
            }
            _pendingInvites.value = list
        } catch (e: Exception) {
            Timber.w(e, "Failed to load pending invites")
        }
    }

    companion object {
        private const val STORAGE_KEY = "fmf.pendingInvites"
    }
}
