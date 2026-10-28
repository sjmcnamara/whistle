package org.findmyfam.shared

import org.findmyfam.shared.models.AppDefaults
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AppDefaultsTest {

    @Test
    fun `defaultRelays is not empty`() {
        assertTrue(AppDefaults.defaultRelays.isNotEmpty())
    }

    @Test
    fun `all default relays start with wss`() {
        for (relay in AppDefaults.defaultRelays) {
            assertTrue(relay.startsWith("wss://"), "Expected wss:// prefix but got: $relay")
        }
    }

    @Test
    fun `retired relay is not a default`() {
        assertTrue(
            AppDefaults.defaultRelays.none { it.contains("relay.damus.io") },
            "relay.damus.io is retired — MarmotKit refuses it and the whole directory fetch fails"
        )
    }

    @Test
    fun `defaultRelays has no duplicates`() {
        assertEquals(
            AppDefaults.defaultRelays.toSet().size,
            AppDefaults.defaultRelays.size,
            "a duplicated default relay would be dialled twice"
        )
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
            AppDefaults.Keys.pendingGiftWrapEventIds,
            AppDefaults.Keys.keyRotationIntervalDays
        )
        for (key in keys) {
            assertTrue(key.startsWith("fmf."), "Expected fmf. prefix but got: $key")
        }
    }
}
