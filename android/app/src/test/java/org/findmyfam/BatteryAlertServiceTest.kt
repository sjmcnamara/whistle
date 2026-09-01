package org.findmyfam

import android.app.NotificationManager
import android.content.Context
import io.mockk.every
import io.mockk.mockk
import org.findmyfam.services.BatteryAlertService
import org.findmyfam.services.IdentityService
import org.findmyfam.services.NicknameStore
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/**
 * Tests for BatteryAlertService threshold-crossing / dedup logic.
 * Parity with iOS BatteryAlertServiceTests — uses the `deliver` seam to observe
 * alerts without the notification stack.
 */
class BatteryAlertServiceTest {

    private val me = "0".repeat(64)
    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)

    private data class Alert(val name: String, val battery: Int, val pubkeyHex: String)

    private lateinit var alerts: MutableList<Alert>
    private lateinit var service: BatteryAlertService

    @Before
    fun setUp() {
        alerts = mutableListOf()
        val context = mockk<Context>(relaxed = true)
        every { context.getSystemService(Context.NOTIFICATION_SERVICE) } returns
            mockk<NotificationManager>(relaxed = true)

        val identity = mockk<IdentityService> { every { publicKeyHex } returns me }
        // Display name falls back to the 8-char pubkey prefix, matching iOS.
        val nicknameStore = mockk<NicknameStore> {
            every { displayName(any()) } answers { firstArg<String>().take(8) }
        }

        service = BatteryAlertService(context, nicknameStore, identity)
        service.deliver = { name, battery, pubkeyHex ->
            alerts.add(Alert(name, battery, pubkeyHex))
        }
    }

    private val count get() = alerts.size
    private val last get() = alerts.lastOrNull()

    // MARK: - Threshold crossing

    @Test
    fun fires_onFirstUpdateBelowThreshold() {
        service.check(alice, 15)
        assertEquals(1, count)
        assertEquals(15, last?.battery)
    }

    @Test
    fun fires_whenCrossingFromAboveToBelow() {
        service.check(alice, 25)
        service.check(alice, 19)
        assertEquals(1, count)
        assertEquals(19, last?.battery)
    }

    @Test
    fun doesNotFire_atExactThreshold() {
        service.check(alice, BatteryAlertService.THRESHOLD)
        assertEquals(0, count)
    }

    @Test
    fun doesNotFire_aboveThreshold() {
        service.check(alice, 80)
        assertEquals(0, count)
    }

    // MARK: - No repeated firing

    @Test
    fun doesNotRefire_whileStillLow() {
        service.check(alice, 15)
        service.check(alice, 12)
        service.check(alice, 5)
        assertEquals("Should only fire once while battery stays below threshold", 1, count)
    }

    @Test
    fun refires_afterRecoveryAndDropAgain() {
        service.check(alice, 15)   // fires
        service.check(alice, 50)   // recovery
        service.check(alice, 10)   // fires again
        assertEquals(2, count)
    }

    @Test
    fun noRefiring_ifRecoveryIsExactlyAtThreshold() {
        service.check(alice, 15)
        service.check(alice, BatteryAlertService.THRESHOLD) // at threshold, no alert
        service.check(alice, 10)   // should fire again
        assertEquals(2, count)
    }

    // MARK: - Own pubkey

    @Test
    fun doesNotFire_forOwnPubkey() {
        service.check(me, 5)
        assertEquals(0, count)
    }

    // MARK: - Null battery

    @Test
    fun ignoresNullBattery() {
        service.check(alice, null)
        assertEquals(0, count)
    }

    // MARK: - Independent tracking

    @Test
    fun tracksEachMemberIndependently() {
        service.check(alice, 15)
        service.check(bob, 10)
        assertEquals(2, count)
    }

    @Test
    fun aliceDoesNotSuppressBobAlert() {
        service.check(alice, 15)   // alice fires
        service.check(alice, 12)   // alice suppressed
        service.check(bob, 18)     // bob fires independently
        assertEquals(2, count)
        assertEquals(listOf(alice, bob), alerts.map { it.pubkeyHex })
    }

    // MARK: - Display name

    @Test
    fun usesShortPubkey_whenNoNickname() {
        service.check(alice, 10)
        assertEquals(alice.take(8), last?.name)
    }
}
