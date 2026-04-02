package org.findmyfam.services

import android.content.Context
import android.content.SharedPreferences
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Data class representing an unsolicited Welcome that needs user approval.
 */
data class PendingWelcomeItem(
    val mlsGroupId: String,
    val senderPubkeyHex: String,
    val wrapperEventId: String,
    val receivedAt: Long
)

/**
 * Persists unsolicited Welcome events that need user approval before accepting.
 * Welcomes that match a pending invite are auto-accepted; all others are queued here.
 *
 * SharedPreferences-backed so pending state survives app restarts.
 */
@Singleton
class PendingWelcomeStore @Inject constructor(
    @ApplicationContext context: Context
) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("fmf_pending_welcomes", Context.MODE_PRIVATE)

    private val _pendingWelcomes = MutableStateFlow<List<PendingWelcomeItem>>(emptyList())
    val pendingWelcomes: StateFlow<List<PendingWelcomeItem>> = _pendingWelcomes.asStateFlow()

    init {
        load()
    }

    /**
     * Record a new pending welcome for user approval.
     */
    fun add(item: PendingWelcomeItem) {
        if (_pendingWelcomes.value.any { it.mlsGroupId == item.mlsGroupId }) return
        _pendingWelcomes.value = _pendingWelcomes.value + item
        save()
        Timber.i("PendingWelcomeStore: added welcome for group ${item.mlsGroupId}")
    }

    /**
     * Remove a pending welcome by MLS group ID (e.g. after user accepts or declines).
     */
    fun remove(mlsGroupId: String) {
        _pendingWelcomes.value = _pendingWelcomes.value.filter { it.mlsGroupId != mlsGroupId }
        save()
        Timber.i("PendingWelcomeStore: removed welcome for group $mlsGroupId")
    }

    /**
     * Remove all pending welcomes (e.g. during identity replacement).
     */
    fun removeAll() {
        _pendingWelcomes.value = emptyList()
        save()
    }

    // --- Persistence ---

    private fun save() {
        val arr = JSONArray()
        for (item in _pendingWelcomes.value) {
            arr.put(JSONObject().apply {
                put("mlsGroupId", item.mlsGroupId)
                put("senderPubkeyHex", item.senderPubkeyHex)
                put("wrapperEventId", item.wrapperEventId)
                put("receivedAt", item.receivedAt)
            })
        }
        prefs.edit().putString(STORAGE_KEY, arr.toString()).apply()
    }

    private fun load() {
        val json = prefs.getString(STORAGE_KEY, null) ?: return
        try {
            val arr = JSONArray(json)
            val list = mutableListOf<PendingWelcomeItem>()
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                list.add(
                    PendingWelcomeItem(
                        mlsGroupId = obj.getString("mlsGroupId"),
                        senderPubkeyHex = obj.getString("senderPubkeyHex"),
                        wrapperEventId = obj.getString("wrapperEventId"),
                        receivedAt = obj.getLong("receivedAt")
                    )
                )
            }
            _pendingWelcomes.value = list
        } catch (e: Exception) {
            Timber.w(e, "Failed to load pending welcomes")
        }
    }

    companion object {
        private const val STORAGE_KEY = "fmf.pendingWelcomes"
    }
}
