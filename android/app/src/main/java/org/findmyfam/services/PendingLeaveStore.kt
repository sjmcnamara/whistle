package org.findmyfam.services

import android.content.Context
import android.content.SharedPreferences
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Tracks groups where the user has requested to leave but the admin
 * hasn't yet processed the removal (which triggers MLS key rotation).
 *
 * SharedPreferences-backed so the "Leaving..." state survives app restarts.
 */
@Singleton
class PendingLeaveStore @Inject constructor(
    @ApplicationContext context: Context
) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("fmf_pending_leaves", Context.MODE_PRIVATE)

    private val _pendingLeaves = MutableStateFlow<Set<String>>(emptySet())
    val pendingLeaves: StateFlow<Set<String>> = _pendingLeaves.asStateFlow()

    init {
        load()
    }

    fun contains(groupId: String): Boolean {
        return groupId in _pendingLeaves.value
    }

    fun add(groupId: String) {
        if (groupId in _pendingLeaves.value) return
        _pendingLeaves.value = _pendingLeaves.value + groupId
        save()
        Timber.i("PendingLeaveStore: added leave request for group $groupId")
    }

    fun remove(groupId: String) {
        if (groupId !in _pendingLeaves.value) return
        _pendingLeaves.value = _pendingLeaves.value - groupId
        save()
        Timber.i("PendingLeaveStore: removed leave request for group $groupId")
    }

    fun removeAll() {
        _pendingLeaves.value = emptySet()
        save()
    }

    /**
     * Remove any pending leaves for groups that no longer exist in the active
     * group list -- meaning the admin processed the removal successfully.
     */
    fun removeResolved(activeGroupIds: Set<String>) {
        val resolved = _pendingLeaves.value - activeGroupIds
        if (resolved.isEmpty()) return
        _pendingLeaves.value = _pendingLeaves.value - resolved
        save()
        Timber.i("PendingLeaveStore: auto-cleared ${resolved.size} resolved leave(s)")
    }

    // --- Persistence ---

    private fun save() {
        val arr = JSONArray()
        for (id in _pendingLeaves.value) arr.put(id)
        prefs.edit().putString(STORAGE_KEY, arr.toString()).apply()
    }

    private fun load() {
        val json = prefs.getString(STORAGE_KEY, null) ?: return
        try {
            val arr = JSONArray(json)
            val set = mutableSetOf<String>()
            for (i in 0 until arr.length()) set.add(arr.getString(i))
            _pendingLeaves.value = set
        } catch (e: Exception) {
            Timber.w(e, "Failed to load pending leaves")
        }
    }

    companion object {
        private const val STORAGE_KEY = "fmf.pendingLeaves"
    }
}
