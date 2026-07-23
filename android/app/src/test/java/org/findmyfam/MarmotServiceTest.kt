package org.findmyfam

import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import org.findmyfam.services.IdentityService
import org.findmyfam.services.MarmotService
import org.findmyfam.services.RelayService
import org.findmyfam.shared.models.InviteCode
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/**
 * Tests for MarmotService's pure (non-MLS) logic: rumor tag extraction, invite
 * generation, and active-relay reporting. Parity with the equivalent iOS
 * MarmotServiceTests cases.
 *
 * The MLS-orchestration cases (createGroup / sendMessage / addMembers /
 * gift-wrap / rotateStaleGroups) exercise the MDK native library and belong to
 * instrumented tests — the JVM `test/` sourceset has no MDK crypto. iOS can run
 * those as unit tests because XCTest runs on a simulator with an in-memory
 * MLSService; the Android equivalent requires a device/emulator.
 */
class MarmotServiceTest {

    private lateinit var relay: RelayService
    private lateinit var identity: IdentityService
    private lateinit var sut: MarmotService

    @Before
    fun setUp() {
        relay = mockk(relaxed = true)
        every { relay.connectedRelayUrls } returns MutableStateFlow(emptyList())

        identity = mockk(relaxed = true)
        every { identity.npub } returns "npub1test"
        every { identity.publicKeyHex } returns "a".repeat(64)

        sut = MarmotService(
            relay = relay,
            mls = mockk(relaxed = true),
            identity = identity,
            settings = mockk(relaxed = true),
            nicknameStore = mockk(relaxed = true),
            memberAvatarStore = mockk(relaxed = true),
            sharedGroupAvatarStore = mockk(relaxed = true),
            pendingInviteStore = mockk(relaxed = true),
            pendingLeaveStore = mockk(relaxed = true),
            pendingWelcomeStore = mockk(relaxed = true),
            joinRequestStore = mockk(relaxed = true),
            locationCache = mockk(relaxed = true),
            healthTracker = mockk(relaxed = true),
            batteryAlertService = mockk(relaxed = true)
        )
    }

    // MARK: - firstETag

    @Test
    fun firstETag_extractsKeyPackageEventId() {
        val json = """{"kind":444,"content":"x","tags":[["e","kp-event-id-123"],["relays","wss://r"]]}"""
        assertEquals("kp-event-id-123", sut.firstETag(json))
    }

    @Test
    fun firstETag_isNull_whenNoETag() {
        val json = """{"kind":444,"content":"x","tags":[["relays","wss://r"]]}"""
        assertNull(sut.firstETag(json))
    }

    @Test
    fun firstETag_isNull_onMalformedJson() {
        assertNull(sut.firstETag("not json at all"))
    }

    // MARK: - generateInviteCode

    @Test
    fun generateInviteCode_producesValidRoundTrippableCode() {
        val code = sut.generateInviteCode("test-group-id", "wss://relay.damus.io")
        val decoded = InviteCode.decode(code)
        assertEquals("test-group-id", decoded.groupId)
        assertEquals("wss://relay.damus.io", decoded.relay)
        assertTrue(decoded.inviterNpub.isNotEmpty())
    }

    // MARK: - activeRelayUrls

    @Test
    fun activeRelayUrls_reflectConnectedRelays() {
        every { relay.connectedRelayUrls } returns MutableStateFlow(listOf("wss://relay.damus.io"))
        assertEquals(listOf("wss://relay.damus.io"), sut.activeRelayUrls)
    }
}
