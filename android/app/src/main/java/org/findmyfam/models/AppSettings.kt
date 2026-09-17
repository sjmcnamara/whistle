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
        private val KEY_PENDING_GIFT_WRAP_EVENT_IDS = AppDefaults.Keys.pendingGiftWrapEventIds
        private val KEY_KEY_ROTATION_INTERVAL_DAYS = AppDefaults.Keys.keyRotationIntervalDays
        private val KEY_PAUSED_GROUP_IDS = AppDefaults.Keys.pausedGroupIds
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

    private val _locationIntervalSecondsFlow = MutableStateFlow(
        prefs.getInt(KEY_LOCATION_INTERVAL, 0).let { v ->
            if (v == 0) AppDefaults.defaultLocationIntervalSeconds else v
        }
    )
    /** Observable interval — emits on every setter call so services can re-apply throttling at runtime. */
    val locationIntervalSecondsFlow: StateFlow<Int> = _locationIntervalSecondsFlow

    var locationIntervalSeconds: Int
        get() = _locationIntervalSecondsFlow.value
        set(value) {
            prefs.edit().putInt(KEY_LOCATION_INTERVAL, value).apply()
            _locationIntervalSecondsFlow.value = value
        }

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

    // --- Location Fuzzing ---

    var locationFuzzMeters: Int
        get() = prefs.getInt(AppDefaults.Keys.locationFuzzMeters, 0)
        set(value) { prefs.edit().putInt(AppDefaults.Keys.locationFuzzMeters, value).apply() }

    // --- Motion-Adaptive Intervals ---

    var isMotionAdaptiveEnabled: Boolean
        get() = if (!prefs.contains(AppDefaults.Keys.motionAdaptive)) true
                else prefs.getBoolean(AppDefaults.Keys.motionAdaptive, true)
        set(value) { prefs.edit().putBoolean(AppDefaults.Keys.motionAdaptive, value).apply() }

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

    // --- Per-group location-sharing pause ---

    /**
     * Groups the user has paused *their own* outbound location broadcast to.
     * Independent of [isLocationPaused] (the global switch): a paused group is
     * skipped by LocationBroadcaster, but the user keeps receiving and viewing
     * other members' locations in that group as normal.
     */
    private val _pausedGroupIdsFlow = MutableStateFlow(loadPausedGroupIds())
    val pausedGroupIdsFlow: StateFlow<Set<String>> = _pausedGroupIdsFlow

    var pausedGroupIds: MutableSet<String>
        get() = _pausedGroupIdsFlow.value.toMutableSet()
        set(value) {
            val arr = JSONArray()
            for (id in value) arr.put(id)
            prefs.edit().putString(KEY_PAUSED_GROUP_IDS, arr.toString()).apply()
            _pausedGroupIdsFlow.value = value.toSet()
        }

    private fun loadPausedGroupIds(): Set<String> {
        val json = prefs.getString(KEY_PAUSED_GROUP_IDS, null) ?: return emptySet()
        return try {
            val arr = JSONArray(json)
            (0 until arr.length()).map { arr.getString(it) }.toSet()
        } catch (_: Exception) { emptySet() }
    }
}
