package org.findmyfam.shared

import org.findmyfam.shared.models.AppDefaults
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AppDefaultsTest {

    @Test
    fun `defaultRelays contains exactly 3 entries`() {
        assertEquals(3, AppDefaults.defaultRelays.size)
    }

    @Test
    fun `all default relays start with wss`() {
        for (relay in AppDefaults.defaultRelays) {
            assertTrue(relay.startsWith("wss://"), "Expected wss:// prefix but got: $relay")
        }
    }

    @Test
    fun `first default relay is relay damus io`() {
        assertEquals("wss://relay.damus.io", AppDefaults.defaultRelays[0])
    }

    @Test
    fun `defaultLocationIntervalSeconds is 3600`() {
        assertEquals(3600, AppDefaults.defaultLocationIntervalSeconds)
    }

    @Test
    fun `defaultKeyRotationIntervalDays is 7`() {
        assertEquals(7, AppDefaults.defaultKeyRotationIntervalDays)
    }

    @Test
    fun `all pref keys start with fmf dot`() {
        val keys = listOf(
            AppDefaults.Keys.relays,
            AppDefaults.Keys.displayName,
            AppDefaults.Keys.locationInterval,
            AppDefaults.Keys.locationPaused,
            AppDefaults.Keys.appLockEnabled,
            AppDefaults.Keys.appLockReauthOnForeground,
            AppDefaults.Keys.lastEventTimestamp,
            AppDefaults.Keys.processedEventIds,
            AppDefaults.Keys.pendingLeaveRequests,
            AppDefaults.Keys.pendingGiftWrapEventIds,
            AppDefaults.Keys.keyRotationIntervalDays
        )
        for (key in keys) {
            assertTrue(key.startsWith("fmf."), "Expected fmf. prefix but got: $key")
        }
    }
}
