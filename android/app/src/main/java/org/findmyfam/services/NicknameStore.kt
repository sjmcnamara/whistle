package org.findmyfam.services

import android.content.Context
import android.content.SharedPreferences
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Local store for member display names, backed by SharedPreferences.
 *
 * Maps pubkeyHex -> displayName. Updated when:
 * - The user sets their own nickname in Settings
 * - A "nickname" control message is received from another member via MarmotService
 */
@Singleton
class NicknameStore @Inject constructor(
    @ApplicationContext context: Context
) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("fmf_nicknames", Context.MODE_PRIVATE)

    private val _nicknames = MutableStateFlow<Map<String, String>>(emptyMap())
    val nicknames: StateFlow<Map<String, String>> = _nicknames.asStateFlow()

    init {
        load()
    }

    /**
     * Get the display name for a pubkey, or return a short hex fallback.
     */
    fun displayName(pubkeyHex: String): String {
        return _nicknames.value[pubkeyHex] ?: "${pubkeyHex.take(8)}..."
    }

    /**
     * Set a nickname for a pubkey. Empty strings remove the entry.
     */
    fun set(name: String, pubkeyHex: String) {
        val current = _nicknames.value.toMutableMap()
        if (name.isEmpty()) {
            current.remove(pubkeyHex)
        } else {
            current[pubkeyHex] = name
        }
        _nicknames.value = current
        save()
    }

    /**
     * Remove all nicknames (used during identity replacement).
     */
    fun clearAll() {
        _nicknames.value = emptyMap()
        save()
    }

    // --- Persistence ---

    private fun load() {
        val json = prefs.getString(STORAGE_KEY, null) ?: return
        try {
            val obj = JSONObject(json)
            val map = mutableMapOf<String, String>()
            for (key in obj.keys()) {
                map[key] = obj.getString(key)
            }
            _nicknames.value = map
        } catch (e: Exception) {
            Timber.w(e, "Failed to load nicknames")
        }
    }

    private fun save() {
        val obj = JSONObject()
        for ((key, value) in _nicknames.value) {
            obj.put(key, value)
        }
        prefs.edit().putString(STORAGE_KEY, obj.toString()).apply()
    }

    companion object {
        private const val STORAGE_KEY = "fmf.nicknames"
    }
}
