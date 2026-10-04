package org.findmyfam

import dev.ipf.marmotkit.AccountSetupReadinessFfi
import dev.ipf.marmotkit.AccountSummaryFfi
import dev.ipf.marmotkit.MarmotInterface
import dev.ipf.marmotkit.MarmotKitException
import dev.ipf.marmotkit.OnboardingSnapshotFfi
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.findmyfam.services.MarmotKitService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for the Kotlin port of `MarmotKitService`.
 *
 * Aimed deliberately at the behaviours that cost device round trips on iOS,
 * because a port is most likely to silently drop exactly those. Chief among
 * them: identity adoption must match the account **by id** rather than taking
 * the first one present, or an import silently resumes the previous identity.
 *
 * `MarmotInterface` is mocked because there is no alternative — Android unit
 * tests run on the JVM and cannot load `libmarmot_uniffi.so`, so unlike iOS
 * there is no loopback-relay harness and no real runtime to test against. The
 * protocol-level behaviour was established on iOS against the same Rust core;
 * what is tested here is this layer's own logic.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MarmotKitServiceTest {

    private val marmot: MarmotInterface = mockk(relaxed = true)

    private fun service(relays: List<String> = listOf("wss://relay.example")) =
        MarmotKitService(marmot = marmot, relayUrls = relays, scope = TestScope())

    private fun account(idHex: String) = mockk<AccountSummaryFfi>(relaxed = true).also {
        every { it.`accountIdHex` } returns idHex
    }

    private fun snapshot(idHex: String, ready: Boolean = false) =
        mockk<OnboardingSnapshotFfi>(relaxed = true).also {
            every { it.`accountIdHex` } returns idHex
            every { it.`ready` } returns ready
            every { it.`proposal` } returns null
            every { it.`steps` } returns emptyList()
        }

    // MARK: - Identity adoption

    @Test
    fun `adopting an nsec signs into the matching existing account`() = runTest {
        every { marmot.`accountIdHex`("npub-alice") } returns "alice-hex"
        every { marmot.`listAccounts`() } returns listOf(account("alice-hex"))
        coEvery { marmot.`signInAccount`("alice-hex") } returns account("alice-hex")

        val adopted = service().start(adoptingNsec = "nsec-alice", expectedReference = "npub-alice")

        assertEquals("alice-hex", adopted)
        coVerify(exactly = 0) { marmot.`beginOnboarding`(any(), any()) }
    }

    /**
     * The bug this guards. On iOS the first version signed into
     * `listAccounts().first()`, which looked equivalent and was not: after an
     * import or burn the previous account is still in the database, so the app
     * resumed the **old** identity — keeping its npub and its groups — while
     * reporting the import successful. Found by review, not by a test, because
     * every test until then used a single key.
     */
    @Test
    fun `adopting a different key does not resume the first stored account`() = runTest {
        every { marmot.`accountIdHex`("npub-bob") } returns "bob-hex"
        // Alice is still on the device; Bob is the key being imported.
        every { marmot.`listAccounts`() } returns listOf(account("alice-hex"))
        coEvery { marmot.`beginOnboarding`(any(), any()) } returns snapshot("bob-hex")

        val adopted = service().start(adoptingNsec = "nsec-bob", expectedReference = "npub-bob")

        assertEquals("bob-hex", adopted)
        coVerify(exactly = 0) { marmot.`signInAccount`("alice-hex") }
        // And the stale account is removed: a burned identity's keys must not
        // survive it.
        coVerify { marmot.`removeAccount`("alice-hex") }
    }

    @Test
    fun `an nsec that disagrees with the expected reference is rejected`() = runTest {
        every { marmot.`accountIdHex`("npub-bob") } returns "bob-hex"
        every { marmot.`listAccounts`() } returns emptyList()
        // Onboarding yields someone else entirely.
        coEvery { marmot.`beginOnboarding`(any(), any()) } returns snapshot("alice-hex")

        // `runCatching` rather than `assertThrows`: the call is suspending, and
        // nesting a second `runTest` inside the assertion swallows the throw.
        val error = runCatching {
            service().start(adoptingNsec = "nsec-alice", expectedReference = "npub-bob")
        }.exceptionOrNull()
        assertTrue(
            "expected an identity mismatch, got $error",
            error is MarmotKitService.ServiceError.IdentityMismatch,
        )
    }

    @Test
    fun `adopting with no expected reference still onboards`() = runTest {
        every { marmot.`listAccounts`() } returns emptyList()
        coEvery { marmot.`beginOnboarding`(any(), any()) } returns snapshot("alice-hex")

        val adopted = service().start(adoptingNsec = "nsec-alice", expectedReference = null)

        assertEquals("alice-hex", adopted)
    }

    // MARK: - Error mapping

    @Test
    fun `typed MarmotKit errors map to app errors rather than strings`() = runTest {
        every { marmot.`accountIdHex`(any()) } returns "alice-hex"
        every { marmot.`listAccounts`() } returns listOf(account("alice-hex"))
        coEvery { marmot.`signInAccount`(any()) } returns account("alice-hex")
        val sut = service()
        sut.start(adoptingNsec = "nsec", expectedReference = "npub")

        coEvery { marmot.`groupMembers`(any(), any()) } throws
            MarmotKitException.GroupUnrecoverableRepairRequired("halted")

        val error = runCatching { sut.members("group") }.exceptionOrNull()
        assertEquals(MarmotKitService.ServiceError.GroupNeedsRepair, error)
    }

    @Test
    fun `operations before start report not-started rather than crashing`() = runTest {
        val error = runCatching { service().members("group") }.exceptionOrNull()
        assertEquals(MarmotKitService.ServiceError.NotStarted, error)
    }

    // MARK: - Relay policy

    @Test
    fun `only allowed relays are offered for dialling`() {
        val classifications = listOf(
            relayClassification("wss://good.example", "wss://good.example", allowed = true),
            relayClassification("wss://retired.example", null, allowed = false),
        )
        every { marmot.`classifyRelayEndpoints`(any()) } returns classifications

        val allowed = service().allowedRelays(
            listOf("wss://good.example", "wss://retired.example")
        )

        assertEquals(listOf("wss://good.example"), allowed)
    }

    private fun relayClassification(endpoint: String, normalized: String?, allowed: Boolean) =
        mockk<dev.ipf.marmotkit.RelayEndpointClassificationFfi>(relaxed = true).also {
            every { it.`endpoint` } returns endpoint
            every { it.`normalizedEndpoint` } returns normalized
            every { it.`policy` } returns
                if (allowed) dev.ipf.marmotkit.RelayEndpointPolicyFfi.ALLOWED
                else dev.ipf.marmotkit.RelayEndpointPolicyFfi.RETIRED
        }

    // MARK: - Send outcome

    /**
     * MarmotKit accepts a send into durable local storage and publishes
     * asynchronously, so a successful return means *stored*, not *sent*. On
     * iOS that made an airplane-mode message look delivered when nothing had
     * left the device.
     */
    @Test
    fun `a send that reached no relay reports queued rather than published`() = runTest {
        val sut = startedService()
        coEvery { marmot.`sendCustomEvent`(any(), any(), any(), any(), any()) } returns
            sendSummary(published = 0u)

        val outcome = sut.send("{}", 3u, "group")

        assertEquals(MarmotKitService.SendOutcome.Queued, outcome)
    }

    @Test
    fun `a send that reached a relay reports published with the count`() = runTest {
        val sut = startedService()
        coEvery { marmot.`sendCustomEvent`(any(), any(), any(), any(), any()) } returns
            sendSummary(published = 2u)

        val outcome = sut.send("{}", 3u, "group")

        assertEquals(MarmotKitService.SendOutcome.Published(2), outcome)
    }

    private fun sendSummary(published: UInt) =
        mockk<dev.ipf.marmotkit.SendSummaryFfi>(relaxed = true).also {
            every { it.`published` } returns published
        }

    // MARK: - Readiness

    @Test
    fun `account readiness is published for the UI to observe`() = runTest {
        val sut = startedService()
        every { marmot.`accountSetupReadiness`(any()) } returns
            AccountSetupReadinessFfi.NETWORK_READY

        assertTrue(sut.isAccountReady())
        assertTrue(sut.accountIsReady.value)
    }

    @Test
    fun `readiness short of network-ready is not reported as ready`() = runTest {
        val sut = startedService()
        every { marmot.`accountSetupReadiness`(any()) } returns
            AccountSetupReadinessFfi.LOCAL_READY

        assertTrue(!sut.isAccountReady())
        assertTrue(!sut.accountIsReady.value)
    }

    /**
     * An account that came from a create rather than an adopt has no
     * onboarding session, and `runOnboarding` throws
     * `OnboardingActionUnavailable` on it — so the driver must not call it.
     */
    @Test
    fun `setup completion skips the driver when there is no onboarding session`() = runTest {
        val sut = startedService()
        every { marmot.`accountSetupReadiness`(any()) } returns
            AccountSetupReadinessFfi.LOCAL_READY
        every { marmot.`onboardingSnapshot`(any()) } returns null

        sut.completeAccountSetup()

        coVerify(exactly = 0) { marmot.`runOnboarding`(any()) }
    }

    @Test
    fun `setup completion returns immediately when already network-ready`() = runTest {
        val sut = startedService()
        every { marmot.`accountSetupReadiness`(any()) } returns
            AccountSetupReadinessFfi.NETWORK_READY

        val readiness = sut.completeAccountSetup()

        assertEquals(AccountSetupReadinessFfi.NETWORK_READY, readiness)
        coVerify(exactly = 0) { marmot.`runOnboarding`(any()) }
    }

    // MARK: - Member code

    @Test
    fun `a scanned code that is not an identity reference is rejected`() = runTest {
        val sut = startedService()
        every { marmot.`accountIdHex`("not-a-code") } returns null

        val error = runCatching { sut.inviteScanned("not-a-code", "group") }.exceptionOrNull()
        assertEquals(MarmotKitService.ServiceError.UnrecognisedMemberCode, error)
    }

    @Test
    fun `my member code is an npub, not hex`() = runTest {
        val sut = startedService()
        every { marmot.`npub`("alice-hex") } returns "npub1alice"

        assertEquals("npub1alice", sut.myMemberCode())
    }

    @Test
    fun `there is no member code before the account exists`() {
        assertNull(service().myMemberCode())
    }

    private suspend fun startedService(): MarmotKitService {
        every { marmot.`accountIdHex`(any()) } returns "alice-hex"
        every { marmot.`listAccounts`() } returns listOf(account("alice-hex"))
        coEvery { marmot.`signInAccount`(any()) } returns account("alice-hex")
        val sut = service()
        sut.start(adoptingNsec = "nsec", expectedReference = "npub")
        assertNotNull(sut.currentAccountRef)
        return sut
    }
}
