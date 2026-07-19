package org.findmyfam.services

import android.content.Context
import android.content.SharedPreferences
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.findmyfam.shared.models.JoinRequest
import org.json.JSONArray
import org.json.JSONObject
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Persists incoming join-requests — gift-wrapped by invitees who accepted an
 * invite (kind MarmotKind.JOIN_REQUEST) — so an admin can review them and
 * batch-add the joiners in a single MLS commit.
 *
 * Deduped by (group, pubkey): a re-sent request replaces the old one so the
 * freshest KeyPackage wins (an invitee republishes on launch, which is how a
 * laggard becomes addable on a later "Add all").
 *
 * SharedPreferences-backed so pending state survives app restarts.
 */
@Singleton
class JoinRequestStore @Inject constructor(
    @ApplicationContext context: Context
) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("fmf_pending_join_requests", Context.MODE_PRIVATE)

    private val _requests = MutableStateFlow<List<JoinRequest>>(emptyList())
    val requests: StateFlow<List<JoinRequest>> = _requests.asStateFlow()

    init { load() }

    /** Pending requests for a group, in arrival order. */
    fun requestsForGroup(groupId: String): List<JoinRequest> =
        _requests.value.filter { it.groupId == groupId }

    /** Add a request, replacing any existing one from the same person for the same group. */
    fun add(request: JoinRequest) {
        _requests.value = _requests.value
            .filterNot { it.groupId == request.groupId && it.pubkey == request.pubkey } + request
        save()
        Timber.i("JoinRequestStore: queued join-request from ${request.pubkey.take(8)}… for group ${request.groupId}")
    }

    fun remove(groupId: String, pubkey: String) {
        _requests.value = _requests.value.filterNot { it.groupId == groupId && it.pubkey == pubkey }
        save()
    }

    fun removeAllForGroup(groupId: String) {
        _requests.value = _requests.value.filterNot { it.groupId == groupId }
        save()
    }

    fun removeAll() {
        _requests.value = emptyList()
        save()
    }

    // --- Persistence ---

    private fun save() {
        val arr = JSONArray()
        for (r in _requests.value) arr.put(JSONObject(r.toJson()))
        prefs.edit().putString(STORAGE_KEY, arr.toString()).apply()
    }

    private fun load() {
        val json = prefs.getString(STORAGE_KEY, null) ?: return
        try {
            val arr = JSONArray(json)
            val list = mutableListOf<JoinRequest>()
            for (i in 0 until arr.length()) {
                list.add(JoinRequest.fromJson(arr.getJSONObject(i).toString()))
            }
            _requests.value = list
        } catch (e: Exception) {
            Timber.w(e, "Failed to load join requests")
        }
    }

    companion object {
        private const val STORAGE_KEY = "fmf.pendingJoinRequests"
    }
}
