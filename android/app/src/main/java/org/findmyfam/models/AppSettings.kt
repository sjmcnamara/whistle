package org.findmyfam.models

import android.content.Context
import android.content.SharedPreferences
import dagger.hilt.android.qualifiers.ApplicationContext
import org.findmyfam.shared.models.AppDefaults
import org.findmyfam.shared.models.RelayConfig
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton

/**
 * App-wide settings backed by SharedPreferences.
 * Mirrors iOS AppSettings.
 */
@Singleton
class AppSettings @Inject constructor(
    @ApplicationContext context: Context
) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("fmf_settings", Context.MODE_PRIVATE)

    companion object {
        val defaultRelays: List<RelayConfig> = AppDefaults.defaultRelays.map { RelayConfig(url = it) }

        private val KEY_RELAYS = AppDefaults.Keys.relays
        private val KEY_DISPLAY_NAME = AppDefaults.Keys.displayName
        private val KEY_LOCATION_INTERVAL = AppDefaults.Keys.locationInterval
        private val KEY_LOCATION_PAUSED = AppDefaults.Keys.locationPaused
        private val KEY_APP_LOCK_ENABLED = AppDefaults.Keys.appLockEnabled
        private val KEY_APP_LOCK_REAUTH = AppDefaults.Keys.appLockReauthOnForeground
        private val KEY_LAST_EVENT_TIMESTAMP = AppDefaults.Keys.lastEventTimestamp
        private val KEY_PROCESSED_EVENT_IDS = AppDefaults.Keys.processedEventIds
        private val KEY_PENDING_LEAVE_REQUESTS = AppDefaults.Keys.pendingLeaveRequests
        private val KEY_PENDING_GIFT_WRAP_EVENT_IDS = AppDefaults.Keys.pendingGiftWrapEventIds
        private val KEY_KEY_ROTATION_INTERVAL_DAYS = AppDefaults.Keys.keyRotationIntervalDays
    }

    // --- Relays ---

    var relays: List<RelayConfig>
        get() {
            val json = prefs.getString(KEY_RELAYS, null) ?: return defaultRelays
            return try {
                val arr = JSONArray(json)
                (0 until arr.length()).map { i ->
                    val obj = arr.getJSONObject(i)
                    RelayConfig(
                        id = obj.optString("id", java.util.UUID.randomUUID().toString()),
                        url = obj.getString("url"),
                        isEnabled = obj.optBoolean("isEnabled", true)
                    )
                }
            } catch (e: Exception) {
                Timber.w(e, "Failed to parse relays, using defaults")
                defaultRelays
            }
        }
        set(value) {
            val arr = JSONArray()
            for (r in value) {
                arr.put(JSONObject().apply {
                    put("id", r.id)
                    put("url", r.url)
                    put("isEnabled", r.isEnabled)
                })
            }
            prefs.edit().putString(KEY_RELAYS, arr.toString()).apply()
        }

    // --- Display Name ---

    var displayName: String
        get() = prefs.getString(KEY_DISPLAY_NAME, "") ?: ""
        set(value) { prefs.edit().putString(KEY_DISPLAY_NAME, value).apply() }

    // --- Location ---

    var locationIntervalSeconds: Int
        get() {
            val v = prefs.getInt(KEY_LOCATION_INTERVAL, 0)
            return if (v == 0) AppDefaults.defaultLocationIntervalSeconds else v
        }
        set(value) { prefs.edit().putInt(KEY_LOCATION_INTERVAL, value).apply() }

    var isLocationPaused: Boolean
        get() = prefs.getBoolean(KEY_LOCATION_PAUSED, false)
        set(value) { prefs.edit().putBoolean(KEY_LOCATION_PAUSED, value).apply() }

    // --- App Lock ---

    var isAppLockEnabled: Boolean
        get() = prefs.getBoolean(KEY_APP_LOCK_ENABLED, false)
        set(value) { prefs.edit().putBoolean(KEY_APP_LOCK_ENABLED, value).apply() }

    var isAppLockReauthOnForeground: Boolean
        get() = prefs.getBoolean(KEY_APP_LOCK_REAUTH, false)
        set(value) { prefs.edit().putBoolean(KEY_APP_LOCK_REAUTH, value).apply() }

    // --- Event tracking ---

    var lastEventTimestamp: ULong
        get() = prefs.getLong(KEY_LAST_EVENT_TIMESTAMP, 0L).toULong()
        set(value) { prefs.edit().putLong(KEY_LAST_EVENT_TIMESTAMP, value.toLong()).apply() }

    var processedEventIds: MutableSet<String>
        get() {
            val json = prefs.getString(KEY_PROCESSED_EVENT_IDS, null) ?: return mutableSetOf()
            return try {
                val arr = JSONArray(json)
                val set = mutableSetOf<String>()
                for (i in 0 until arr.length()) {
                    set.add(arr.getString(i))
                }
                set
            } catch (_: Exception) { mutableSetOf() }
        }
        set(value) {
            val arr = JSONArray()
            for (id in value) arr.put(id)
            prefs.edit().putString(KEY_PROCESSED_EVENT_IDS, arr.toString()).apply()
        }

    fun addProcessedEventId(id: String) {
        val ids = processedEventIds
        ids.add(id)
        processedEventIds = ids
    }

    fun isEventProcessed(id: String): Boolean {
        return processedEventIds.contains(id)
    }

    // --- Pending leave requests ---

    var pendingLeaveRequests: MutableMap<String, MutableSet<String>>
        get() {
            val json = prefs.getString(KEY_PENDING_LEAVE_REQUESTS, null) ?: return mutableMapOf()
            return try {
                val obj = JSONObject(json)
                val map = mutableMapOf<String, MutableSet<String>>()
                for (key in obj.keys()) {
                    val arr = obj.getJSONArray(key)
                    val set = mutableSetOf<String>()
                    for (i in 0 until arr.length()) set.add(arr.getString(i))
                    map[key] = set
                }
                map
            } catch (_: Exception) { mutableMapOf() }
        }
        set(value) {
            val obj = JSONObject()
            for ((key, set) in value) {
                val arr = JSONArray()
                for (s in set) arr.put(s)
                obj.put(key, arr)
            }
            prefs.edit().putString(KEY_PENDING_LEAVE_REQUESTS, obj.toString()).apply()
        }

    fun addPendingLeaveRequest(groupId: String, pubkey: String) {
        val map = pendingLeaveRequests
        map.getOrPut(groupId) { mutableSetOf() }.add(pubkey)
        pendingLeaveRequests = map
    }

    fun removePendingLeaveRequest(groupId: String, pubkey: String) {
        val map = pendingLeaveRequests
        map[groupId]?.remove(pubkey)
        pendingLeaveRequests = map
    }

    // --- Pending gift wrap event IDs ---

    var pendingGiftWrapEventIds: MutableSet<String>
        get() {
            val json = prefs.getString(KEY_PENDING_GIFT_WRAP_EVENT_IDS, null) ?: return mutableSetOf()
            return try {
                val arr = JSONArray(json)
                val set = mutableSetOf<String>()
                for (i in 0 until arr.length()) set.add(arr.getString(i))
                set
            } catch (_: Exception) { mutableSetOf() }
        }
        set(value) {
            val arr = JSONArray()
            for (id in value) arr.put(id)
            prefs.edit().putString(KEY_PENDING_GIFT_WRAP_EVENT_IDS, arr.toString()).apply()
        }

    fun addPendingGiftWrapEventId(id: String) {
        val ids = pendingGiftWrapEventIds
        ids.add(id)
        pendingGiftWrapEventIds = ids
    }

    fun removePendingGiftWrapEventId(id: String) {
        val ids = pendingGiftWrapEventIds
        ids.remove(id)
        pendingGiftWrapEventIds = ids
    }

    // --- Unread tracking ---

    private val KEY_GROUP_LAST_READ = "groupLastReadTimestamps"
    private val KEY_GROUP_LAST_CHAT = "groupLastChatTimestamps"

    /** Get last-read epoch seconds for a group, or 0 if never read. */
    fun getLastRead(groupId: String): Long {
        val json = prefs.getString(KEY_GROUP_LAST_READ, null) ?: return 0L
        return try {
            JSONObject(json).optLong(groupId, 0L)
        } catch (_: Exception) { 0L }
    }

    /** Mark a group as read right now. */
    fun markGroupAsRead(groupId: String) {
        val obj = try {
            JSONObject(prefs.getString(KEY_GROUP_LAST_READ, null) ?: "{}")
        } catch (_: Exception) { JSONObject() }
        obj.put(groupId, System.currentTimeMillis() / 1000)
        prefs.edit().putString(KEY_GROUP_LAST_READ, obj.toString()).apply()
    }

    /** Get last chat-message epoch seconds for a group, or null if no chat received. */
    fun getLastChatTimestamp(groupId: String): Long? {
        val json = prefs.getString(KEY_GROUP_LAST_CHAT, null) ?: return null
        return try {
            val v = JSONObject(json).optLong(groupId, -1L)
            if (v == -1L) null else v
        } catch (_: Exception) { null }
    }

    /** Record that a chat message was received for a group right now. */
    fun recordChatMessage(groupId: String) {
        val obj = try {
            JSONObject(prefs.getString(KEY_GROUP_LAST_CHAT, null) ?: "{}")
        } catch (_: Exception) { JSONObject() }
        obj.put(groupId, System.currentTimeMillis() / 1000)
        prefs.edit().putString(KEY_GROUP_LAST_CHAT, obj.toString()).apply()
    }

    /** Clear all per-group chat and read timestamps. Called during identity burn. */
    fun clearChatTimestamps() {
        prefs.edit()
            .remove(KEY_GROUP_LAST_READ)
            .remove(KEY_GROUP_LAST_CHAT)
            .apply()
    }

    // --- Appearance ---

    private val _appearanceFlow = MutableStateFlow(
        prefs.getString(AppDefaults.Keys.appearance, "system") ?: "system"
    )
    val appearanceFlow: StateFlow<String> = _appearanceFlow

    var appearance: String
        get() = _appearanceFlow.value
        set(value) {
            prefs.edit().putString(AppDefaults.Keys.appearance, value).apply()
            _appearanceFlow.value = value
        }

    // --- Key rotation ---

    var keyRotationIntervalDays: Int
        get() {
            val v = prefs.getInt(KEY_KEY_ROTATION_INTERVAL_DAYS, 0)
            return if (v == 0) AppDefaults.defaultKeyRotationIntervalDays else v
        }
        set(value) { prefs.edit().putInt(KEY_KEY_ROTATION_INTERVAL_DAYS, value).apply() }

    val keyRotationIntervalSecs: ULong
        get() = keyRotationIntervalDays.toULong() * 24u * 3600u
}
