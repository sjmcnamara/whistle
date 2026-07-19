package org.findmyfam

import android.content.Context
import android.content.SharedPreferences
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import io.mockk.verify
import org.findmyfam.models.AppSettings
import org.findmyfam.shared.models.AppDefaults
import org.findmyfam.shared.models.RelayConfig
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class AppSettingsTest {

    private lateinit var settings: AppSettings
    private lateinit var prefs: SharedPreferences
    private lateinit var editor: SharedPreferences.Editor

    /** Stores written values so gets can read them back within the same test. */
    private val store = mutableMapOf<String, Any?>()

    @Before
    fun setUp() {
        editor = mockk(relaxed = true) {
            every { putString(any(), any()) } answers {
                store[firstArg()] = secondArg<String>(); this@mockk
            }
            every { putInt(any(), any()) } answers {
                store[firstArg()] = secondArg<Int>(); this@mockk
            }
            every { putBoolean(any(), any()) } answers {
                store[firstArg()] = secondArg<Boolean>(); this@mockk
            }
            every { putLong(any(), any()) } answers {
                store[firstArg()] = secondArg<Long>(); this@mockk
            }
            every { remove(any()) } answers {
                store.remove(firstArg<String>()); this@mockk
            }
        }
        prefs = mockk {
            every { getString(any(), any()) } answers { store[firstArg()] as? String ?: secondArg() }
            every { getInt(any(), any()) } answers { store[firstArg()] as? Int ?: secondArg() }
            every { getBoolean(any(), any()) } answers { store[firstArg()] as? Boolean ?: secondArg() }
            every { getLong(any(), any()) } answers { store[firstArg()] as? Long ?: secondArg() }
            every { edit() } returns editor
        }
        val context = mockk<Context> {
            every { getSharedPreferences("fmf_settings", Context.MODE_PRIVATE) } returns prefs
        }
        settings = AppSettings(context)
    }

    // region Relays

    @Test
    fun `relays returns defaults when no stored value`() {
        assertEquals(AppDefaults.defaultRelays.size, settings.relays.size)
    }

    @Test
    fun `relays round-trips through JSON`() {
        val custom = listOf(
            RelayConfig(url = "wss://one.example.com"),
            RelayConfig(url = "wss://two.example.com", isEnabled = false)
        )
        settings.relays = custom
        val loaded = settings.relays
        assertEquals(2, loaded.size)
        assertEquals("wss://one.example.com", loaded[0].url)
        assertTrue(loaded[0].isEnabled)
        assertEquals("wss://two.example.com", loaded[1].url)
        assertFalse(loaded[1].isEnabled)
    }

    @Test
    fun `relays falls back to defaults on corrupt JSON`() {
        store[AppDefaults.Keys.relays] = "not json"
        val relays = settings.relays
        assertEquals(AppDefaults.defaultRelays.size, relays.size)
    }

    // endregion

    // region Display Name

    @Test
    fun `displayName defaults to empty`() {
        assertEquals("", settings.displayName)
    }

    @Test
    fun `displayName round-trips`() {
        settings.displayName = "Alice"
        assertEquals("Alice", settings.displayName)
    }

    // endregion

    // region Location

    @Test
    fun `locationIntervalSeconds defaults to AppDefaults value`() {
        assertEquals(AppDefaults.defaultLocationIntervalSeconds, settings.locationIntervalSeconds)
    }

    @Test
    fun `locationIntervalSeconds round-trips`() {
        settings.locationIntervalSeconds = 600
        assertEquals(600, settings.locationIntervalSeconds)
    }

    @Test
    fun `locationIntervalSecondsFlow emits the current value on setter change`() {
        // Regression: previously the running LocationService stayed on its
        // startup-snapshot interval until app restart because nothing observed
        // setter changes. Mirrors iOS AppViewModel.swift:173.
        val flow = settings.locationIntervalSecondsFlow
        assertEquals(AppDefaults.defaultLocationIntervalSeconds, flow.value)
        settings.locationIntervalSeconds = 10
        assertEquals(10, flow.value)
        settings.locationIntervalSeconds = 300
        assertEquals(300, flow.value)
    }

    @Test
    fun `isLocationPaused defaults to false`() {
        assertFalse(settings.isLocationPaused)
    }

    @Test
    fun `isLocationPaused round-trips`() {
        settings.isLocationPaused = true
        assertTrue(settings.isLocationPaused)
    }

    @Test
    fun `locationFuzzMeters defaults to zero`() {
        assertEquals(0, settings.locationFuzzMeters)
    }

    @Test
    fun `locationFuzzMeters round-trips`() {
        settings.locationFuzzMeters = 200
        assertEquals(200, settings.locationFuzzMeters)
    }

    // endregion

    // region App Lock

    @Test
    fun `isAppLockEnabled defaults to false`() {
        assertFalse(settings.isAppLockEnabled)
    }

    @Test
    fun `isAppLockEnabled round-trips`() {
        settings.isAppLockEnabled = true
        assertTrue(settings.isAppLockEnabled)
    }

    @Test
    fun `isAppLockReauthOnForeground defaults to false`() {
        assertFalse(settings.isAppLockReauthOnForeground)
    }

    // endregion

    // region Event Tracking

    @Test
    fun `processedEventIds starts empty`() {
        assertTrue(settings.processedEventIds.isEmpty())
    }

    @Test
    fun `addProcessedEventId and isEventProcessed`() {
        settings.addProcessedEventId("evt-1")
        assertTrue(settings.isEventProcessed("evt-1"))
        assertFalse(settings.isEventProcessed("evt-2"))
    }

    @Test
    fun `processedEventIds survives corrupt JSON`() {
        store[AppDefaults.Keys.processedEventIds] = "broken"
        assertTrue(settings.processedEventIds.isEmpty())
    }

    // endregion

    // region Pending Leave Requests

    @Test
    fun `pendingLeaveRequests starts empty`() {
        assertTrue(settings.pendingLeaveRequests.isEmpty())
    }

    @Test
    fun `addPendingLeaveRequest and round-trip`() {
        settings.addPendingLeaveRequest("group-1", "pubkey-a")
        settings.addPendingLeaveRequest("group-1", "pubkey-b")
        val map = settings.pendingLeaveRequests
        assertEquals(1, map.size)
        assertEquals(setOf("pubkey-a", "pubkey-b"), map["group-1"])
    }

    @Test
    fun `removePendingLeaveRequest`() {
        settings.addPendingLeaveRequest("group-1", "pubkey-a")
        settings.addPendingLeaveRequest("group-1", "pubkey-b")
        settings.removePendingLeaveRequest("group-1", "pubkey-a")
        val map = settings.pendingLeaveRequests
        assertEquals(setOf("pubkey-b"), map["group-1"])
    }

    // endregion

    // region Pending Gift Wrap Event IDs

    @Test
    fun `pendingGiftWrapEventIds starts empty`() {
        assertTrue(settings.pendingGiftWrapEventIds.isEmpty())
    }

    @Test
    fun `addPendingGiftWrapEventId and removePendingGiftWrapEventId`() {
        settings.addPendingGiftWrapEventId("gw-1")
        settings.addPendingGiftWrapEventId("gw-2")
        assertTrue(settings.pendingGiftWrapEventIds.contains("gw-1"))
        settings.removePendingGiftWrapEventId("gw-1")
        assertFalse(settings.pendingGiftWrapEventIds.contains("gw-1"))
        assertTrue(settings.pendingGiftWrapEventIds.contains("gw-2"))
    }

    // endregion

    // region Unread Tracking

    @Test
    fun `getLastRead returns 0 for unknown group`() {
        assertEquals(0L, settings.getLastRead("group-1"))
    }

    @Test
    fun `markGroupAsRead and getLastRead`() {
        settings.markGroupAsRead("group-1")
        assertTrue(settings.getLastRead("group-1") > 0)
    }

    @Test
    fun `getLastChatTimestamp returns null for unknown group`() {
        assertNull(settings.getLastChatTimestamp("group-1"))
    }

    @Test
    fun `recordChatMessage and getLastChatTimestamp`() {
        settings.recordChatMessage("group-1")
        assertNotNull(settings.getLastChatTimestamp("group-1"))
    }

    @Test
    fun `clearChatTimestamps removes both stores`() {
        settings.markGroupAsRead("group-1")
        settings.recordChatMessage("group-1")
        settings.clearChatTimestamps()
        assertEquals(0L, settings.getLastRead("group-1"))
        assertNull(settings.getLastChatTimestamp("group-1"))
    }

    // endregion

    // region Appearance

    @Test
    fun `appearance defaults to system`() {
        assertEquals("system", settings.appearance)
    }

    @Test
    fun `appearance round-trips and updates flow`() {
        settings.appearance = "dark"
        assertEquals("dark", settings.appearance)
        assertEquals("dark", settings.appearanceFlow.value)
    }

    // endregion

    // region Key Rotation

    @Test
    fun `keyRotationIntervalDays defaults to AppDefaults`() {
        assertEquals(AppDefaults.defaultKeyRotationIntervalDays, settings.keyRotationIntervalDays)
    }

    @Test
    fun `keyRotationIntervalSecs converts correctly`() {
        settings.keyRotationIntervalDays = 3
        assertEquals(3.toULong() * 24u * 3600u, settings.keyRotationIntervalSecs)
    }

    // endregion
}
