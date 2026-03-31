package org.findmyfam.shared

import org.findmyfam.shared.models.RelayConfig
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class RelayConfigTest {

    @Test
    fun `default isEnabled is true`() {
        val relay = RelayConfig(url = "wss://relay.damus.io")
        assertTrue(relay.isEnabled)
    }

    @Test
    fun `two instances with same url but different UUIDs are not equal`() {
        val a = RelayConfig(url = "wss://relay.damus.io")
        val b = RelayConfig(url = "wss://relay.damus.io")
        // data class equality compares all fields including id (UUID)
        assertNotEquals(a, b)
    }

    @Test
    fun `can set isEnabled to false`() {
        val relay = RelayConfig(url = "wss://nos.lol", isEnabled = false)
        assertEquals(false, relay.isEnabled)
    }
}
