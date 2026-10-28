package org.findmyfam

import dev.ipf.marmotkit.AccountSetupReadinessFfi
import dev.ipf.marmotkit.AccountSummaryFfi
import dev.ipf.marmotkit.AppGroupMemberRecordFfi
import dev.ipf.marmotkit.GroupDetailsFfi
import dev.ipf.marmotkit.HistoryNoticeCauseFfi
import dev.ipf.marmotkit.HistoryNoticeFfi
import dev.ipf.marmotkit.MarmotInterface
import dev.ipf.marmotkit.MarmotKitException
import dev.ipf.marmotkit.OnboardingSnapshotFfi
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.coVerifyOrder
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

    // MARK: - History notices

    private fun notice(id: String, group: String? = null) =
        HistoryNoticeFfi(
            noticeId = id,
            cause = HistoryNoticeCauseFfi.DELIVERY_LOSS,
            groupIdHex = group,
            parkedAtMs = null,
        )

    @Test
    fun `history notices are mapped to app types and published`() = runTest {
        val sut = startedService()
        coEvery { marmot.`historyNotices`(any()) } returns listOf(notice("n1"), notice("n2", group = "g"))

        sut.refreshHistoryNotices()

        assertEquals(listOf("n1", "n2"), sut.historyNotices.value.map { it.noticeId })
        assertEquals("delivery_loss", sut.historyNotices.value.first().cause)
        assertNull(sut.historyNotices.value.first().groupIdHex)
        assertEquals("g", sut.historyNotices.value.last().groupIdHex)
    }

    /**
     * Dropping the list because a read failed would hide exactly the condition
     * the user most needs to know about.
     */
    @Test
    fun `a failed read keeps the previous notices`() = runTest {
        val sut = startedService()
        coEvery { marmot.`historyNotices`(any()) } returns listOf(notice("n1"))
        sut.refreshHistoryNotices()

        coEvery { marmot.`historyNotices`(any()) } throws IllegalStateException("db busy")
        sut.refreshHistoryNotices()

        assertEquals(listOf("n1"), sut.historyNotices.value.map { it.noticeId })
    }

    @Test
    fun `dismissing records each notice and then re-reads the list`() = runTest {
        val sut = startedService()
        coEvery { marmot.`historyNotices`(any()) } returns listOf(notice("n1"), notice("n2"))
        sut.refreshHistoryNotices()
        coEvery { marmot.`dismissHistoryNotice`(any(), any()) } returns true
        coEvery { marmot.`historyNotices`(any()) } returns emptyList()

        sut.dismissHistoryNotices(listOf("n1", "n2"))

        coVerify(exactly = 1) { marmot.`dismissHistoryNotice`(any(), "n1") }
        coVerify(exactly = 1) { marmot.`dismissHistoryNotice`(any(), "n2") }
        assertTrue(sut.historyNotices.value.isEmpty())
    }

    /**
     * A `false` return means the id is stale — recovery re-armed since the list
     * was read. That is an expected race, not an error, and the answer is to
     * show the current list.
     */
    @Test
    fun `a stale id on dismiss re-reads rather than failing`() = runTest {
        val sut = startedService()
        coEvery { marmot.`dismissHistoryNotice`(any(), "old") } returns false
        coEvery { marmot.`historyNotices`(any()) } returns listOf(notice("new"))

        sut.dismissHistoryNotices(listOf("old"))

        assertEquals(listOf("new"), sut.historyNotices.value.map { it.noticeId })
    }

    /** The service must not read notices for an account it has not adopted. */
    @Test
    fun `refreshing before an account exists does nothing`() = runTest {
        val sut = service()

        sut.refreshHistoryNotices()

        coVerify(exactly = 0) { marmot.`historyNotices`(any()) }
        assertTrue(sut.historyNotices.value.isEmpty())
    }

    // MARK: - Resync keeps an admin an admin

    private fun member(hex: String) = mockk<AppGroupMemberRecordFfi>(relaxed = true).also {
        every { it.`memberIdHex` } returns hex
    }

    private fun stubGroup(admins: List<String>, members: List<String>) {
        val details = mockk<GroupDetailsFfi>(relaxed = true)
        every { details.`group`.`admins` } returns admins
        coEvery { marmot.`groupDetails`(any(), any()) } returns details
        coEvery { marmot.`groupMembers`(any(), any()) } returns members.map(::member)
    }

    /**
     * The bug. `resyncMember` is remove + invite, and admin status lives in the
     * group's MLS state, so the re-add produced an ordinary member: repairing an
     * admin silently demoted them. Order is asserted, not just presence — the
     * promotion has to follow the re-invite or there is no member to promote.
     */
    @Test
    fun `resyncing an admin promotes them again after the re-invite`() = runTest {
        val sut = startedService()
        stubGroup(admins = listOf("alice-hex", "bob-hex"), members = listOf("alice-hex", "bob-hex"))

        sut.resyncMember("bob-hex", "g")

        coVerifyOrder {
            marmot.`removeMembers`(any(), "g", listOf("bob-hex"))
            marmot.`inviteMembers`(any(), "g", listOf("bob-hex"))
            marmot.`promoteAdmin`(any(), "g", "bob-hex")
        }
    }

    /**
     * The reverse, and what makes the fix safe: promoting unconditionally would
     * quietly hand admin to every member that was ever resynced.
     */
    @Test
    fun `resyncing a plain member does not make them an admin`() = runTest {
        val sut = startedService()
        stubGroup(admins = listOf("alice-hex"), members = listOf("alice-hex", "bob-hex"))

        sut.resyncMember("bob-hex", "g")

        coVerify(exactly = 1) { marmot.`inviteMembers`(any(), "g", listOf("bob-hex")) }
        coVerify(exactly = 0) { marmot.`promoteAdmin`(any(), any(), any()) }
    }

    /**
     * A failed read must not be mistaken for "not an admin". `group()` swallows a
     * failed `groupDetails` into an empty admin list, which would demote an
     * admin without a word — so the read has to stop the resync before anything
     * is removed.
     */
    @Test
    fun `an unreadable admin list stops the resync before anything is removed`() = runTest {
        val sut = startedService()
        coEvery { marmot.`groupMembers`(any(), any()) } returns listOf(member("alice-hex"), member("bob-hex"))
        coEvery { marmot.`groupDetails`(any(), any()) } throws IllegalStateException("db busy")

        val thrown = runCatching { sut.resyncMember("bob-hex", "g") }.exceptionOrNull()

        assertNotNull(thrown)
        coVerify(exactly = 0) { marmot.`removeMembers`(any(), any(), any()) }
        coVerify(exactly = 0) { marmot.`inviteMembers`(any(), any(), any()) }
    }

    /**
     * After a failed re-add they are out of the group, so there is nothing live
     * to read their role from. The retry has to remember it.
     */
    @Test
    fun `retrying a failed re-add still restores the admin`() = runTest {
        val sut = startedService()
        stubGroup(admins = listOf("alice-hex", "bob-hex"), members = listOf("alice-hex", "bob-hex"))
        coEvery { marmot.`inviteMembers`(any(), any(), any()) } throws IllegalStateException("relay down")

        val first = runCatching { sut.resyncMember("bob-hex", "g") }.exceptionOrNull()
        assertTrue("expected ReAddFailed, got $first", first is MarmotKitService.ServiceError.ReAddFailed)
        coVerify(exactly = 0) { marmot.`promoteAdmin`(any(), any(), any()) }

        // Retry: Bob is out now, and the invite works this time.
        stubGroup(admins = listOf("alice-hex"), members = listOf("alice-hex"))
        coEvery { marmot.`inviteMembers`(any(), any(), any()) } returns mockk(relaxed = true)
        sut.resyncMember("bob-hex", "g")

        coVerify(exactly = 1) { marmot.`promoteAdmin`(any(), "g", "bob-hex") }
    }

    /**
     * A remembered role must never outlive its moment. If they are present and
     * not an admin, the live state wins and nothing is promoted — otherwise a
     * stale entry would hand someone admin later.
     */
    @Test
    fun `a remembered role does not promote someone who is present and not an admin`() = runTest {
        val sut = startedService()
        stubGroup(admins = listOf("alice-hex", "bob-hex"), members = listOf("alice-hex", "bob-hex"))
        coEvery { marmot.`inviteMembers`(any(), any(), any()) } throws IllegalStateException("relay down")
        runCatching { sut.resyncMember("bob-hex", "g") }   // leaves "bob was an admin" remembered

        // Someone re-adds Bob by hand, as a plain member.
        stubGroup(admins = listOf("alice-hex"), members = listOf("alice-hex", "bob-hex"))
        coEvery { marmot.`inviteMembers`(any(), any(), any()) } returns mockk(relaxed = true)
        sut.resyncMember("bob-hex", "g")

        coVerify(exactly = 0) { marmot.`promoteAdmin`(any(), any(), any()) }
    }

    /**
     * The recovery differs from a failed re-add — they are already back — so it
     * has to be reported as its own thing, or the retry would remove and re-add
     * them a second time as a plain member.
     */
    @Test
    fun `a failed promotion is reported distinctly from a failed re-add`() = runTest {
        val sut = startedService()
        stubGroup(admins = listOf("alice-hex", "bob-hex"), members = listOf("alice-hex", "bob-hex"))
        coEvery { marmot.`promoteAdmin`(any(), any(), any()) } throws IllegalStateException("relay down")

        val thrown = runCatching { sut.resyncMember("bob-hex", "g") }.exceptionOrNull()

        assertTrue(
            "expected AdminNotRestored, got $thrown",
            thrown is MarmotKitService.ServiceError.AdminNotRestored,
        )
        coVerify(exactly = 1) { marmot.`inviteMembers`(any(), "g", listOf("bob-hex")) }
    }

    // MARK: - Threading

    /**
     * The bug this guards. Every MarmotKit call used to run on the *caller's*
     * thread, which for nearly every view model is the main thread. With
     * `Dispatchers.Main.immediate` (the `viewModelScope` default) Rust waking
     * the continuation resumed it inline, nested inside the outer poll, which
     * re-polled into a lock the outer poll still held — the main thread
     * deadlocked permanently (an ANR with `rust_future_poll` on the stack, on a
     * Pixel, the first time a real device added a member).
     *
     * The deadlock itself needs the native library and cannot be reproduced on
     * the JVM, so this pins the invariant that causes it: an FFI call must never
     * execute on the thread that asked for it.
     */
    @Test
    fun `a suspending call runs off the callers thread`() = runTest {
        val sut = startedService()
        var ffiThread: Thread? = null
        coEvery { marmot.`groupMembers`(any(), any()) } coAnswers {
            ffiThread = Thread.currentThread()
            emptyList()
        }
        val caller = Thread.currentThread()

        sut.members("group-1")

        assertNotNull("the FFI call never ran", ffiThread)
        assertTrue(
            "ran on the caller's thread (${caller.name}); this is what deadlocked the main thread",
            ffiThread !== caller,
        )
    }

    /** The other half of the same boundary: a failure must still map, off-thread. */
    @Test
    fun `errors raised off-thread are still mapped to ServiceError`() = runTest {
        val sut = startedService()
        coEvery { marmot.`groupMembers`(any(), any()) } throws
            MarmotKitException.NotGroupAdmin("group-1")

        val thrown = runCatching { sut.members("group-1") }.exceptionOrNull()

        assertTrue(
            "expected a mapped ServiceError, got $thrown",
            thrown is MarmotKitService.ServiceError.NotGroupAdmin,
        )
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
