package org.findmyfam.services

import dev.ipf.marmotkit.AccountSetupReadinessFfi
import dev.ipf.marmotkit.GroupLifecycleStateFfi
import dev.ipf.marmotkit.SelfMembershipFfi
import dev.ipf.marmotkit.MarmotInterface
import dev.ipf.marmotkit.MarmotKitException
import dev.ipf.marmotkit.OnboardingActionFfi
import dev.ipf.marmotkit.OnboardingOptionsFfi
import dev.ipf.marmotkit.OnboardingSnapshotFfi
import dev.ipf.marmotkit.OnboardingStatusFfi
import dev.ipf.marmotkit.OnboardingStepFfi
import dev.ipf.marmotkit.MessageUpdateFfi
import dev.ipf.marmotkit.OnboardingStepStateFfi
import dev.ipf.marmotkit.ReceivedMessageFfi
import dev.ipf.marmotkit.RelayEndpointPolicyFfi
import dev.ipf.marmotkit.TimelineMessageQueryFfi
import dev.ipf.marmotkit.TimelineMessageRecordFfi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.findmyfam.shared.MarmotKind
import org.findmyfam.shared.models.ChatPayload
import org.findmyfam.shared.models.LocationPayload
import org.findmyfam.shared.models.WhistleGroup
import org.findmyfam.shared.models.WhistleMessage
import org.json.JSONObject
import timber.log.Timber

/**
 * Marmot protocol v2 group operations, backed by MarmotKit (MDK 0.10.x).
 *
 * The Kotlin counterpart of iOS's `MarmotKitService`, and deliberately a close
 * transcription of it rather than a fresh design. Every behaviour here that
 * looks fussy was established by device testing on iOS, usually after getting
 * it wrong first; the comments say which, so the next person does not
 * "simplify" one back out.
 *
 * One structural difference from iOS: this takes `MarmotInterface` rather than
 * constructing the runtime itself. Android has no injectable transport and no
 * loopback-relay harness — `testDebugUnitTest` runs on the JVM and cannot load
 * `libmarmot_uniffi.so` at all — so the only way to test this layer is to mock
 * the boundary. Depending on the interface makes that possible; constructing
 * `Marmot` internally would not.
 */
class MarmotKitService(
    private val marmot: MarmotInterface,
    private val relayUrls: List<String>,
    private val scope: CoroutineScope,
    var locationCache: LocationCache? = null,
    var nicknameStore: NicknameStore? = null,
    var memberAvatarStore: MemberAvatarStore? = null,
    var sharedGroupAvatarStore: SharedGroupAvatarStore? = null,
    var chatMessageCache: ChatMessageCache? = null,
) {

    // MARK: - Errors

    /**
     * App-level errors, mapped from MarmotKit's typed ones.
     *
     * The point of mapping at all: v1 had to pattern-match MDK's error *text*
     * ("last active admin", "only admins can perform this operation") because
     * 0.8 surfaced these as untyped strings. These are first-class cases now,
     * so the matching is exhaustive rather than fragile.
     */
    sealed class ServiceError(message: String) : Exception(message) {
        object NotStarted : ServiceError("Marmot is not started yet.")
        object LastAdminCannotLeave : ServiceError(
            "You're the only admin of this group. Promote another member to admin before leaving."
        )
        object NotGroupAdmin : ServiceError("Only an admin can do that.")
        object AlreadyMember : ServiceError("This person is already a member of the group")
        object MemberNotInGroup : ServiceError("That person isn't a member of this group.")
        object LeaveAlreadyRequested : ServiceError(
            "You're already leaving this group — it will complete shortly."
        )

        /**
         * The group is halted and only a re-admit by another member can revive
         * it — MarmotKit's `GroupUnrecoverableRepairRequired`. The v1 stack
         * inferred this from consecutive failures; here it is reported
         * outright.
         */
        object GroupNeedsRepair : ServiceError(
            "This group needs to be re-joined. Ask an admin to re-invite you."
        )
        object SendQueueFull : ServiceError(
            "This group is stuck sending. Try again once it catches up."
        )
        object UnrecognisedMemberCode : ServiceError(
            "That code isn't a Whistle member code. Ask them to show theirs from Settings → Your Identity."
        )

        /**
         * The nsec being adopted does not belong to the identity the caller
         * said it did. Never expected in normal operation — it means the app
         * would otherwise have started as the wrong person.
         */
        class IdentityMismatch(expected: String, adopted: String) : ServiceError(
            "Identity mismatch: expected ${expected.take(8)}…, adopted ${adopted.take(8)}…"
        )
        class Underlying(detail: String) : ServiceError(detail)
    }

    private fun mapError(error: Throwable): ServiceError {
        // Our own errors pass straight through. Everything here runs inside
        // `run`, which maps on the way out, so a `ServiceError` thrown *inside*
        // would otherwise be re-wrapped as `Underlying` and lose the case a
        // caller is trying to catch.
        if (error is ServiceError) return error
        return when (error) {
            is MarmotKitException.WouldRemoveLastAdmin -> ServiceError.LastAdminCannotLeave
            is MarmotKitException.NotGroupAdmin, is MarmotKitException.NotAdmin ->
                ServiceError.NotGroupAdmin
            is MarmotKitException.AlreadyAdmin -> ServiceError.AlreadyMember
            is MarmotKitException.MemberNotInGroup -> ServiceError.MemberNotInGroup
            is MarmotKitException.LeaveAlreadyRequested -> ServiceError.LeaveAlreadyRequested
            is MarmotKitException.GroupUnrecoverableRepairRequired -> ServiceError.GroupNeedsRepair
            is MarmotKitException.GroupSendQueueFull -> ServiceError.SendQueueFull
            else -> ServiceError.Underlying(error.message ?: error.toString())
        }
    }

    private inline fun <T> run(body: () -> T): T =
        try {
            body()
        } catch (error: Throwable) {
            throw mapError(error)
        }

    // MARK: - Published state

    private val _groups = MutableStateFlow<List<WhistleGroup>>(emptyList())
    val groups: StateFlow<List<WhistleGroup>> = _groups.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    private val _lastChatMessageGroupId = MutableStateFlow<String?>(null)
    val lastChatMessageGroupId: StateFlow<String?> = _lastChatMessageGroupId.asStateFlow()

    private val _lastJoinedGroupId = MutableStateFlow<String?>(null)
    val lastJoinedGroupId: StateFlow<String?> = _lastJoinedGroupId.asStateFlow()

    private val _lastGroupMembershipChangeId = MutableStateFlow<Pair<String, Long>?>(null)
    val lastGroupMembershipChangeId: StateFlow<Pair<String, Long>?> =
        _lastGroupMembershipChangeId.asStateFlow()

    /**
     * Whether the account is published and usable for anything touching
     * relays. Observed by the UI; see `isAccountReady`.
     */
    private val _accountIsReady = MutableStateFlow(false)
    val accountIsReady: StateFlow<Boolean> = _accountIsReady.asStateFlow()

    private var accountRef: String? = null
    val currentAccountRef: String? get() = accountRef

    private fun requireAccount(): String = accountRef ?: throw ServiceError.NotStarted

    // MARK: - Relay policy

    /** Hostnames MarmotKit "will never dial or adopt". */
    fun retiredRelayHosts(): List<String> = marmot.`retiredRelayHosts`()

    /** Classify relay URLs with the same policy applied when dialling. */
    fun classifyRelays(endpoints: List<String>): List<Pair<String, String>> =
        marmot.`classifyRelayEndpoints`(endpoints).map { it.`endpoint` to it.`policy`.toString() }

    /** The subset of [endpoints] MarmotKit is willing to dial. */
    fun allowedRelays(endpoints: List<String>): List<String> =
        marmot.`classifyRelayEndpoints`(endpoints)
            .filter { it.`policy` == RelayEndpointPolicyFfi.ALLOWED }
            .map { it.`normalizedEndpoint` ?: it.`endpoint` }

    /**
     * Endpoints reduced to one form, so two spellings of the same relay
     * compare equal.
     *
     * MarmotKit's own normalisation is applied first but is **not** enough:
     * measured on iOS, `classifyRelayEndpoints` leaves a trailing slash alone,
     * so `wss://host` and `wss://host/` came back distinct and one of them
     * reported a permanent "restart to connect". Case and trailing slashes are
     * folded here as well.
     */
    private fun canonical(endpoints: List<String>): Set<String> =
        marmot.`classifyRelayEndpoints`(endpoints)
            .map { (it.`normalizedEndpoint` ?: it.`endpoint`).lowercase().trimEnd('/') }
            .toSet()

    /** The pool this runtime is dialling, fixed at construction. */
    val dialledRelayEndpoints: List<String> get() = relayUrls

    // MARK: - Lifecycle

    /**
     * Start, adopting an identity the app already has.
     *
     * This is the upgrade path, and it is what stops the cutover costing users
     * their identity. MarmotKit owns accounts itself — `createIdentity…` mints
     * a *new* key — so starting that way on an existing install would hand
     * every user a new npub and silently orphan them from everyone who knows
     * them. v2.0 breaking groups is agreed; breaking identity is not.
     *
     * [expectedReference] is matched against the accounts already present.
     * **Never take `listAccounts().first()`**: after an identity import or
     * burn the previous account is still in the database, so `.first()` signs
     * back into the *old* identity — keeping its npub and its groups — while
     * reporting the import successful. That was found by review on iOS, not by
     * a test, because every test until then used a single key.
     */
    suspend fun start(adoptingNsec: String, expectedReference: String?): String {
        return run {
            marmot.`start`()

            val expectedId = expectedReference?.let { marmot.`accountIdHex`(it) }
            val existing = marmot.`listAccounts`()

            val match = expectedId?.let { wanted ->
                existing.firstOrNull { it.`accountIdHex` == wanted }
            }
            if (match != null) {
                val summary = marmot.`signInAccount`(match.`accountIdHex`)
                accountRef = summary.`accountIdHex`
                return@run summary.`accountIdHex`
            }

            // Accounts present, none of them this one: the identity
            // replacement path. Stale accounts are dropped rather than left
            // behind — a burned identity's keys must not survive it, and
            // leaving them would make the matching above depend on a database
            // that only grows.
            existing.filter { it.`accountIdHex` != expectedId }.forEach { stale ->
                try {
                    marmot.`removeAccount`(stale.`accountIdHex`)
                    Timber.i("Removed stale account ${stale.`accountIdHex`.take(8)}")
                } catch (error: Throwable) {
                    Timber.w(error, "Could not remove stale account")
                }
            }

            val usable = allowedRelays(relayUrls)
            val snapshot = marmot.`beginOnboarding`(
                adoptingNsec,
                OnboardingOptionsFfi(`defaultRelays` = usable, `discoveryRelays` = usable),
            )
            accountRef = snapshot.`accountIdHex`

            // A mismatch means the nsec and the reference describe different
            // identities. Worth failing loudly: continuing would run the app as
            // whoever the nsec belongs to, not who the caller believed.
            if (expectedId != null && snapshot.`accountIdHex` != expectedId) {
                throw ServiceError.IdentityMismatch(expectedId, snapshot.`accountIdHex`)
            }
            snapshot.`accountIdHex`
        }
    }

    /** The account's nsec, for key backup and export. */
    fun revealNsec(): String = run { marmot.`revealNsec`(requireAccount()) }

    /**
     * Remove this device's account, destroying its local signing key.
     *
     * Called before teardown on identity replacement. Done through MarmotKit
     * rather than by deleting the database directory: a root is owned
     * exclusively while its handle lives, so removing files underneath it is
     * not safe while the service exists.
     */
    suspend fun forgetCurrentAccount() {
        val account = accountRef ?: return
        try {
            marmot.`removeAccount`(account)
            Timber.i("Removed account ${account.take(8)} on identity replacement")
        } catch (error: Throwable) {
            Timber.e(error, "Failed to remove account on identity replacement")
        }
        accountRef = null
    }

    suspend fun shutdown() {
        stopSubscriptions()
        try {
            marmot.`shutdown`()
        } catch (error: Throwable) {
            Timber.w(error, "Shutdown reported an error")
        }
    }

    // MARK: - Account setup

    fun setupReadiness(): AccountSetupReadinessFfi =
        run { marmot.`accountSetupReadiness`(requireAccount()) }

    /**
     * Whether the account is published and usable for anything that touches
     * relays — creating a group, being invited to one.
     *
     * The same precondition in both cases: until setup reaches `NETWORK_READY`
     * the account has no published relay list or KeyPackage, and MarmotKit
     * rejects the operation with `OnboardingRequired`. Gate UI on this rather
     * than letting the user act and fail.
     */
    fun isAccountReady(): Boolean {
        val ready = runCatching { setupReadiness() }.getOrNull() ==
            AccountSetupReadinessFfi.NETWORK_READY
        if (ready != _accountIsReady.value) _accountIsReady.value = ready
        return ready
    }

    /**
     * Drive account setup from local-ready to network-ready.
     *
     * `beginOnboarding` stops at local-ready — it persists the identity and
     * returns before any network preflight or publication — so until this
     * completes anything needing a published account is rejected with
     * `OnboardingRequired`.
     *
     * Onboarding is a **sequential state machine that blocks on caller
     * input**, not a single call. Measured on iOS: after `beginOnboarding` all
     * six steps are pending; one `runOnboarding` moves `profile` to
     * `NEEDS_INPUT` and every later step stays pending behind it. So
     * `runOnboarding` alone can never finish — it advances only what it can
     * decide itself, and the caller must clear each blocking step.
     */
    suspend fun completeAccountSetup(): AccountSetupReadinessFfi {
        val account = requireAccount()
        return run {
            if (marmot.`accountSetupReadiness`(account) == AccountSetupReadinessFfi.NETWORK_READY) {
                _accountIsReady.value = true
                return@run AccountSetupReadinessFfi.NETWORK_READY
            }
            // No session means the account came from a create rather than an
            // adopt, which runs its own setup — `runOnboarding` would throw
            // `OnboardingActionUnavailable`.
            if (marmot.`onboardingSnapshot`(account) == null) {
                return@run marmot.`accountSetupReadiness`(account)
            }

            // Every (step, strategy) pair already tried. Without this the loop
            // re-applies the *same* action every pass — observed on device,
            // where `inboxRelays` kept being handed the configured relay list
            // and kept coming back needing input, while another offered action
            // sat unused.
            val attempted = mutableSetOf<String>()

            repeat(MAX_ONBOARDING_PASSES) {
                var snapshot = marmot.`runOnboarding`(account)
                if (snapshot.`ready`) return@repeat

                val blocked = snapshot.`steps`.firstOrNull {
                    it.`status` == OnboardingStatusFfi.NEEDS_INPUT ||
                        it.`status` == OnboardingStatusFfi.RETRYABLE_FAILURE
                } ?: return@repeat

                blocked.`findings`.forEach { finding ->
                    Timber.w(
                        "Onboarding ${blocked.`step`} finding: ${finding.`issue`} " +
                            "endpoint=${finding.`endpoint` ?: "-"}"
                    )
                }

                resolveOnboardingStep(blocked, account, snapshot, attempted) ?: return@repeat
            }

            val readiness = marmot.`accountSetupReadiness`(account)
            _accountIsReady.value = readiness == AccountSetupReadinessFfi.NETWORK_READY
            if (readiness != AccountSetupReadinessFfi.NETWORK_READY) {
                Timber.e("Account setup stalled at $readiness")
                onboardingDiagnostics().forEach { Timber.e("  $it") }
            }
            readiness
        }
    }

    /**
     * Clear one blocking onboarding step.
     *
     * Tries strategies in a per-step order, skips any already attempted, and
     * **treats one that throws as simply not working** — moving to the next
     * rather than failing the whole setup. Observed on iOS: `inboxRelays`
     * offers `EDIT_RELAYS`, but the onboarding-level propose rejects that step
     * with `OnboardingActionUnavailable`, and because the throw propagated it
     * killed the entire run with four untried strategies left.
     *
     * The offered action list is a hint about what a UI may present, not a
     * guarantee the matching call is valid for that step.
     */
    private suspend fun resolveOnboardingStep(
        state: OnboardingStepStateFfi,
        account: String,
        snapshot: OnboardingSnapshotFfi,
        attempted: MutableSet<String>,
    ): OnboardingSnapshotFfi? {
        for (strategy in strategiesFor(state, snapshot)) {
            val key = "${state.`step`}|$strategy"
            if (key in attempted) continue
            try {
                val next = applyStrategy(strategy, state.`step`, account)
                if (next == null) {
                    // Not applicable *yet* — deliberately not recorded.
                    // `APPROVE_REPAIR` is inapplicable until a proposal
                    // exists, and recording it on the first pass would
                    // permanently skip the only action later offered.
                    continue
                }
                attempted += key
                Timber.i("Onboarding ${state.`step`}: $strategy accepted")
                return next
            } catch (error: Throwable) {
                attempted += key
                Timber.w("Onboarding ${state.`step`}: $strategy failed — $error")
            }
        }
        Timber.e("Onboarding ${state.`step`} exhausted every strategy; offered ${state.`actions`}")
        return null
    }

    private enum class OnboardingStrategy {
        APPROVE_REPAIR,
        SET_INBOX_RELAYS,
        PROPOSE_CONFIGURED_RELAYS,
        RECOMMENDED_RELAYS,
        DISCOVERY_RELAYS,
        RETRY,
        ACKNOWLEDGE_SINGLE_DEVICE,
        CONTINUE_WITHOUT,
    }

    /**
     * Strategy order per step.
     *
     * A pending repair proposal takes precedence over everything. Observed on
     * device: setting the inbox relay list published it correctly, and left
     * the step needing input because the machine had raised a proposal and
     * reduced the step's actions to approve/cancel. Approving is the only way
     * forward, and an earlier version omitted it entirely, so the run
     * exhausted itself while the machine waited on consent it had asked for.
     */
    private fun strategiesFor(
        state: OnboardingStepStateFfi,
        snapshot: OnboardingSnapshotFfi,
    ): List<OnboardingStrategy> {
        val repairFirst =
            if (snapshot.`proposal` != null) listOf(OnboardingStrategy.APPROVE_REPAIR)
            else emptyList()

        val stepOrder = when (state.`step`) {
            // Whistle publishes no public Nostr profile and has no social
            // graph: display names and avatars travel inside the group as MLS
            // payloads, so these are out of scope rather than merely optional.
            OnboardingStepFfi.PROFILE, OnboardingStepFfi.FOLLOWS ->
                listOf(OnboardingStrategy.CONTINUE_WITHOUT, OnboardingStrategy.RETRY)

            // Our own list first: it is policy-filtered, so it cannot
            // reintroduce a retired host.
            OnboardingStepFfi.RELAYS -> listOf(
                OnboardingStrategy.PROPOSE_CONFIGURED_RELAYS,
                OnboardingStrategy.RECOMMENDED_RELAYS,
                OnboardingStrategy.DISCOVERY_RELAYS,
                OnboardingStrategy.RETRY,
                OnboardingStrategy.CONTINUE_WITHOUT,
            )

            // The dedicated account-level call first, because the
            // onboarding-level propose is the one that threw for this step.
            OnboardingStepFfi.INBOX_RELAYS -> listOf(
                OnboardingStrategy.SET_INBOX_RELAYS,
                OnboardingStrategy.PROPOSE_CONFIGURED_RELAYS,
                OnboardingStrategy.RECOMMENDED_RELAYS,
                OnboardingStrategy.RETRY,
                OnboardingStrategy.CONTINUE_WITHOUT,
            )

            // One device is the normal case for this app, not a warning.
            OnboardingStepFfi.SINGLE_DEVICE -> listOf(
                OnboardingStrategy.ACKNOWLEDGE_SINGLE_DEVICE,
                OnboardingStrategy.CONTINUE_WITHOUT,
                OnboardingStrategy.RETRY,
            )

            // No `CONTINUE_WITHOUT`: without a published KeyPackage nobody can
            // add us to a group, which is the entire point of the member code.
            OnboardingStepFfi.KEY_PACKAGE -> listOf(
                OnboardingStrategy.RETRY,
                OnboardingStrategy.PROPOSE_CONFIGURED_RELAYS,
                OnboardingStrategy.RECOMMENDED_RELAYS,
            )
        }
        return repairFirst + stepOrder
    }

    private suspend fun applyStrategy(
        strategy: OnboardingStrategy,
        step: OnboardingStepFfi,
        account: String,
    ): OnboardingSnapshotFfi? {
        val relays = allowedRelays(relayUrls)
        return when (strategy) {
            OnboardingStrategy.CONTINUE_WITHOUT ->
                marmot.`continueOnboardingWithout`(account, step)

            OnboardingStrategy.RETRY ->
                marmot.`retryOnboardingStep`(account, step)

            OnboardingStrategy.PROPOSE_CONFIGURED_RELAYS ->
                if (relays.isEmpty()) null
                else marmot.`proposeOnboardingRelays`(account, step, relays, relays)

            OnboardingStrategy.SET_INBOX_RELAYS -> {
                if (relays.isEmpty()) {
                    null
                } else {
                    // Sets the list directly rather than proposing it through
                    // the onboarding machine, then re-reads the snapshot since
                    // this call returns relay lists rather than onboarding
                    // state.
                    marmot.`setAccountInboxRelays`(account, relays, relays)
                    marmot.`onboardingSnapshot`(account)
                }
            }

            OnboardingStrategy.RECOMMENDED_RELAYS ->
                marmot.`proposeOnboardingRecommendedRelays`(account, step)

            OnboardingStrategy.DISCOVERY_RELAYS ->
                if (relays.isEmpty()) null
                else marmot.`setOnboardingDiscoveryRelays`(account, relays)

            OnboardingStrategy.ACKNOWLEDGE_SINGLE_DEVICE -> {
                val current = marmot.`onboardingSnapshot`(account) ?: return null
                marmot.`acknowledgeOnboardingSingleDevice`(account, current.`revision`)
            }

            OnboardingStrategy.APPROVE_REPAIR -> {
                // Re-read rather than trusting the snapshot passed in: the
                // revision moves as the machine works, and approving is
                // revision-scoped.
                val current = marmot.`onboardingSnapshot`(account) ?: return null
                if (current.`proposal` == null) null
                else marmot.`approveOnboardingRepair`(account, current.`revision`)
            }
        }
    }

    /**
     * Human-readable dump of the onboarding state machine.
     *
     * Read this **first** when setup will not complete. The step statuses say
     * exactly which call is needed, and guessing from the error string cost
     * several cycles on iOS. Findings carry the reason — `issue` names the
     * fault and `endpoint` the relay it happened on; a count alone is useless,
     * which is how the first version of this was written.
     */
    fun onboardingDiagnostics(): List<String> {
        val account = accountRef ?: return listOf("no account")
        val snapshot = runCatching { marmot.`onboardingSnapshot`(account) }.getOrNull()
            ?: return listOf("no onboarding session (account was not created via an adopt)")
        val lines = mutableListOf(
            "ready=${snapshot.`ready`} revision=${snapshot.`revision`} " +
                "proposal=${snapshot.`proposal` != null}"
        )
        snapshot.`steps`.forEach { state ->
            lines += "step=${state.`step`} status=${state.`status`} actions=${state.`actions`}"
            state.`findings`.forEach { finding ->
                lines += "  finding issue=${finding.`issue`} endpoint=${finding.`endpoint` ?: "-"}"
            }
        }
        return lines
    }

    // MARK: - Groups

    suspend fun refreshGroups() {
        try {
            _groups.value = loadGroups()
        } catch (error: Throwable) {
            Timber.e(error, "Failed to refresh groups")
            _lastError.value = error.message
        }
    }

    private suspend fun loadGroups(): List<WhistleGroup> {
        val account = requireAccount()
        return run {
            marmot.`chatList`(account, false).map { row ->
                val details = runCatching { marmot.`groupDetails`(account, row.`groupIdHex`) }
                    .getOrNull()
                WhistleGroup(
                    mlsGroupId = row.`groupIdHex`,
                    name = row.`groupName`,
                    // A group we have left, been removed from, or that was
                    // disbanded is not active. `UNRECOVERABLE` deliberately
                    // still counts as active: it needs a re-admit to work
                    // again, but hiding it would leave the user unable to see
                    // the group they have to act on.
                    isActive = row.`selfMembership` == SelfMembershipFfi.MEMBER &&
                        row.`lifecycleState` != GroupLifecycleStateFfi.DISBANDED,
                    epoch = details?.`mlsState`?.`epoch`?.toLong() ?: 0L,
                    adminPubkeys = details?.`group`?.`admins` ?: emptyList(),
                    // 0 means "no activity recorded", which the app models as null.
                    lastMessageAt = row.`activitySortAt`.takeIf { it != 0uL }?.toLong(),
                )
            }
        }
    }

    suspend fun members(groupIdHex: String): List<String> {
        val account = requireAccount()
        return run { marmot.`groupMembers`(account, groupIdHex).map { it.`memberIdHex` } }
    }

    suspend fun isAdmin(pubkeyHex: String, groupIdHex: String): Boolean =
        runCatching {
            val account = requireAccount()
            marmot.`groupDetails`(account, groupIdHex).`group`.`admins`.contains(pubkeyHex)
        }.getOrDefault(false)

    // MARK: - Membership

    suspend fun createGroup(name: String, description: String? = null): String {
        val account = requireAccount()
        val groupId = run {
            marmot.`createGroup`(account, name, emptyList(), description)
        }
        // Mutations must republish `groups`: the UI observes the flow, and
        // MarmotKit does not emit on its own for a change this device just
        // made. Without this a created group did not appear until relaunch.
        refreshGroups()
        return groupId
    }

    suspend fun invite(memberRefs: List<String>, groupIdHex: String) {
        val account = requireAccount()
        run { marmot.`inviteMembers`(account, groupIdHex, memberRefs) }
        refreshGroups()
        // Published for the *local* actor too, not only on receipt. The device
        // performing an invite does not get its own system event back, so
        // relying on the receive path meant the admin never re-announced the
        // group photo or profiles — and a new joiner arrived to a group with no
        // picture.
        _lastGroupMembershipChangeId.value = groupIdHex to System.currentTimeMillis()
    }

    /** Invite whoever a scanned code refers to. */
    suspend fun inviteScanned(scannedCode: String, groupIdHex: String) {
        val reference = normalisedAccountReference(scannedCode)
            ?: throw ServiceError.UnrecognisedMemberCode
        invite(listOf(reference), groupIdHex)
    }

    fun normalisedAccountReference(scanned: String): String? =
        marmot.`accountIdHex`(scanned.trim())

    /** This device's member code, for an admin to scan. */
    fun myMemberCode(): String? = accountRef?.let { marmot.`npub`(it) }

    suspend fun removeMembers(memberRefs: List<String>, groupIdHex: String) {
        val account = requireAccount()
        run { marmot.`removeMembers`(account, groupIdHex, memberRefs) }
        refreshGroups()
        _lastGroupMembershipChangeId.value = groupIdHex to System.currentTimeMillis()
    }

    suspend fun promoteToAdmin(memberRef: String, groupIdHex: String) {
        val account = requireAccount()
        run { marmot.`promoteAdmin`(account, groupIdHex, memberRef) }
        refreshGroups()
    }

    suspend fun rename(groupIdHex: String, name: String) {
        val account = requireAccount()
        run { marmot.`updateGroupProfile`(account, groupIdHex, name, null) }
        refreshGroups()
    }

    /**
     * Leave a group, or delete it if you are the only member left.
     *
     * MLS has no way to remove the last member, so self-demote reports
     * `WouldRemoveLastAdmin` — which the app surfaced as "promote another
     * member to admin before leaving". That is impossible advice when there is
     * nobody to promote, and it left burning the identity as the only way out
     * of a group of one.
     */
    suspend fun leaveGroup(groupIdHex: String) {
        val account = requireAccount()

        val others = members(groupIdHex).filter { it != account }
        if (others.isEmpty()) {
            run { marmot.`deleteGroupLocal`(account, groupIdHex) }
            purgeLocalData(groupIdHex)
            refreshGroups()
            return
        }

        try {
            marmot.`selfDemoteAdmin`(account, groupIdHex)
        } catch (error: MarmotKitException) {
            when (error) {
                // Genuine now: other members exist, and one of them has to
                // take admin before this device can go.
                is MarmotKitException.WouldRemoveLastAdmin -> throw ServiceError.LastAdminCannotLeave
                // Not an admin — nothing to demote, fall through to leave.
                is MarmotKitException.NotGroupAdmin, is MarmotKitException.NotAdmin -> Unit
                else -> throw mapError(error)
            }
        }
        run { marmot.`leaveGroup`(account, groupIdHex) }

        // Drop the local row as well. Leaving otherwise left the group in the
        // list, faded, labelled "Inactive" — the right display for a group
        // that *ended* around you, the wrong one for a group you chose to
        // leave. Removing it also unwinds any pushed chat view.
        runCatching { marmot.`deleteGroupLocal`(account, groupIdHex) }
        purgeLocalData(groupIdHex)
        refreshGroups()
    }

    /**
     * Discard everything this device holds about a group it is no longer in.
     *
     * Leaving is leaving: the group row, the chat thread, the map pins and the
     * group photo all go. Nicknames and member avatars deliberately survive —
     * they are keyed by pubkey, not by group, and those people may be in other
     * groups, so discarding them would blank names elsewhere.
     */
    private fun purgeLocalData(groupIdHex: String) {
        chatMessageCache?.clearGroup(groupIdHex)
        locationCache?.clearGroup(groupIdHex)
        sharedGroupAvatarStore?.remove(groupIdHex)
        LocalGroupAvatarStore.removeImage(groupIdHex)
    }

    // MARK: - Sending

    /**
     * What happened to a send, beyond "it did not throw".
     *
     * MarmotKit accepts a send into durable local storage and publishes
     * asynchronously, so a successful return means *stored*, not *sent*. With
     * no relay reachable the call succeeds, the message appears in the
     * timeline, and nothing has left the device — which is exactly how a
     * message looked sent on iOS when it could not have been.
     */
    sealed class SendOutcome {
        data class Published(val relays: Int) : SendOutcome()
        object Queued : SendOutcome()
    }

    suspend fun send(content: String, kind: UShort, groupIdHex: String): SendOutcome {
        val account = requireAccount()
        val summary = run {
            marmot.`sendCustomEvent`(account, groupIdHex, kind.toULong(), emptyList(), content)
        }
        return if (summary.`published` > 0u) {
            SendOutcome.Published(summary.`published`.toInt())
        } else {
            SendOutcome.Queued
        }
    }

    suspend fun sendLocation(payload: LocationPayload, groupIdHex: String): SendOutcome =
        send(payload.toJson(), MarmotKind.ProtocolV2.LOCATION, groupIdHex)

    suspend fun sendChat(payload: ChatPayload, groupIdHex: String): SendOutcome =
        send(payload.toJson(), MarmotKind.ProtocolV2.CHAT, groupIdHex)

    // MARK: - Messages

    /**
     * A page of raw messages, newest first, paged by cursor.
     *
     * v1 paged by integer offset, which silently skips or repeats rows when
     * messages arrive mid-session — the offsets shift underneath you. The
     * cursor is a *raw* message rather than a displayed bubble: location
     * updates dominate the store, and a cursor taken from the chat bubbles
     * alone would skip every raw row between them.
     */
    suspend fun messages(
        groupIdHex: String,
        before: WhistleMessage? = null,
        limit: UInt = 50u,
    ): Pair<List<WhistleMessage>, Boolean> {
        val account = requireAccount()
        return run {
            val page = marmot.`timelineMessages`(
                account,
                TimelineMessageQueryFfi(
                    `groupIdHex` = groupIdHex,
                    `search` = null,
                    `before` = before?.createdAt?.toULong(),
                    `beforeMessageId` = before?.id,
                    `after` = null,
                    `afterMessageId` = null,
                    `limit` = limit,
                ),
            )
            // The backend treats `before` as *inclusive* and returns the cursor
            // row again, so consecutive pages overlap by one. Dropped here
            // rather than left to callers.
            val mapped = page.`messages`.map(::mapTimelineRecord).filter { it.id != before?.id }
            mapped to page.`hasMoreBefore`
        }
    }

    // MARK: - Mapping

    /**
     * MDK's own `GROUP_SYSTEM` kind, from the reserved set in
     * `crates/marmot-app` (see CLAUDE.md's table).
     */
    private val groupSystemKind: ULong = 1210uL

    /**
     * Whether a row is a membership/rename event rather than an app payload.
     *
     * Checks the kind first, then the payload's own shape: these carry a
     * `system_type` field, which nothing Whistle sends does. Deliberately
     * belt-and-braces — relying on MarmotKit's resolved `groupSystem` alone
     * produced a membership event rendered as a chat bubble on arrival and
     * correctly as a system row only after re-entering the chat.
     */
    private fun looksLikeSystemEvent(kind: ULong, plaintext: String): Boolean =
        kind == groupSystemKind || plaintext.contains("\"system_type\"")

    private fun systemText(plaintext: String): String? {
        if (!plaintext.contains("\"system_type\"")) return null
        return runCatching { JSONObject(plaintext).optString("text").ifEmpty { null } }.getOrNull()
    }

    /**
     * The live-stream counterpart of [mapTimelineRecord].
     *
     * `recordedAt`, **not** `sourceEpoch`, is the timestamp. iOS used the
     * latter here and every live-arriving message got a date in 1970 — the MLS
     * epoch is a small counter — which sorted it to the top of the thread.
     */
    private fun mapReceivedMessage(received: ReceivedMessageFfi): WhistleMessage =
        WhistleMessage(
            id = received.`messageIdHex`,
            mlsGroupId = received.`groupIdHex`,
            senderPubkey = received.`sender`,
            kind = received.`kind`.toInt(),
            content = received.`plaintext`,
            createdAt = received.`recordedAt`.toLong(),
            isSystemEvent = looksLikeSystemEvent(received.`kind`, received.`plaintext`),
            systemText = systemText(received.`plaintext`),
            sourceEpoch = received.`sourceEpoch`.toLong(),
        )

    private fun mapTimelineRecord(record: TimelineMessageRecordFfi): WhistleMessage =
        WhistleMessage(
            id = record.`messageIdHex`,
            mlsGroupId = record.`groupIdHex`,
            senderPubkey = record.`sender`,
            kind = record.`kind`.toInt(),
            content = record.`plaintext`,
            createdAt = record.`timelineAt`.toLong(),
            isSystemEvent = record.`groupSystem` != null ||
                looksLikeSystemEvent(record.`kind`, record.`plaintext`),
            systemText = record.`groupSystem`?.`text` ?: systemText(record.`plaintext`),
            sourceEpoch = record.`sourceEpoch`?.toLong(),
        )

    // MARK: - Receive loop

    private var receiveJob: Job? = null
    private var chatListJob: Job? = null

    /**
     * Group ids known when the chat-list subscription was opened.
     *
     * The baseline for deciding what counts as a join. Captured explicitly
     * rather than inferred from the list being empty: an earlier iOS version
     * guarded on the list being non-empty to skip the initial snapshot, which
     * also skipped **joining your first group** — the device has no groups, so
     * the case that matters most looked like a startup load and the joiner
     * never broadcast its name or avatar.
     */
    private var knownGroupIdsAtSubscribe: Set<String> = emptySet()

    fun startSubscriptions() {
        if (receiveJob != null) return
        val account = accountRef ?: return

        knownGroupIdsAtSubscribe = _groups.value.map { it.mlsGroupId }.toSet()

        receiveJob = scope.launch {
            val subscription = runCatching {
                marmot.`subscribeMessages`(
                    account,
                    null,
                    null,
                    listOf(
                        MarmotKind.ProtocolV2.LOCATION.toULong(),
                        MarmotKind.ProtocolV2.CHAT.toULong(),
                        MarmotKind.ProtocolV2.LEAVE_REQUEST.toULong(),
                        // Included deliberately: without it membership and
                        // rename events never arrive live at all.
                        groupSystemKind,
                    ),
                )
            }.getOrElse { error ->
                _lastError.value = error.message
                Timber.e(error, "Failed to open message subscription")
                return@launch
            }

            while (isActive) {
                val update = subscription.`next`() ?: break
                // Agent-stream starts are skipped: Whistle sends no agent
                // payloads, and surfacing them would make every caller handle
                // a case with no meaning here.
                val received = (update as? MessageUpdateFfi.Message)?.`received`?.`message` ?: continue
                route(mapReceivedMessage(received))
            }
        }

        chatListJob = scope.launch {
            val subscription = runCatching {
                marmot.`subscribeChatList`(account, false)
            }.getOrNull() ?: return@launch

            // Every row change republishes the list. This is the only signal
            // for "a group you were not in has appeared" — the message
            // subscription cannot cover it, since it was opened before the
            // group existed and a Welcome is not an app message.
            while (isActive) {
                subscription.`next`() ?: break
                refreshGroupsDetectingJoins()
            }
        }
    }

    fun stopSubscriptions() {
        receiveJob?.cancel()
        receiveJob = null
        chatListJob?.cancel()
        chatListJob = null
    }

    private suspend fun refreshGroupsDetectingJoins() {
        refreshGroups()
        val current = _groups.value.map { it.mlsGroupId }
        val arrived = current.filterNot { it in knownGroupIdsAtSubscribe }
        knownGroupIdsAtSubscribe = knownGroupIdsAtSubscribe + current

        // Before the join check below, so it runs on every emission and not
        // only when something new arrived — a departure is a chat-list change
        // with no new group. A leave does **not** reach `route`, proven on iOS
        // by a test that timed out waiting for the pin to clear while the
        // member list had already updated; the "Member left" line still
        // appears because the chat reads the timeline.
        reconcileLocationsWithMembership()

        arrived.firstOrNull()?.let { _lastJoinedGroupId.value = it }
    }

    /**
     * Reconcile cached locations for every group against its real membership.
     *
     * Reconciliation rather than removing the specific departed member: that
     * needs the system event's subject, and would leave the pin on screen
     * forever if that one event were ever missed. Reconciling is self-healing,
     * covers leave, removal and burn identically, and is a no-op when
     * membership is unchanged.
     *
     * Errors are logged rather than swallowed: a reconcile that silently fails
     * leaves a departed member on the map, which is the bug this fixes.
     */
    private suspend fun reconcileLocationsWithMembership() {
        val cache = locationCache ?: return
        _groups.value.forEach { group ->
            try {
                cache.retainOnly(members(group.mlsGroupId).toSet(), group.mlsGroupId)
            } catch (error: Throwable) {
                Timber.w(error, "Could not reconcile map pins for ${group.mlsGroupId}")
            }
        }
    }

    private suspend fun route(message: WhistleMessage) {
        when (message.kind) {
            MarmotKind.ProtocolV2.LOCATION.toInt() -> {
                runCatching { LocationPayload.fromJson(message.content) }
                    .onSuccess { payload ->
                        locationCache?.update(message.mlsGroupId, message.senderPubkey, payload)
                    }
                    .onFailure { Timber.e(it, "Failed to decode location payload") }
            }

            MarmotKind.ProtocolV2.CHAT.toInt() -> routeChatPayload(message)

            groupSystemKind.toInt() -> {
                refreshGroups()
                reconcileLocationsWithMembership()
                _lastGroupMembershipChangeId.value =
                    message.mlsGroupId to System.currentTimeMillis()
                _lastChatMessageGroupId.value = message.mlsGroupId
            }

            else -> Timber.d("Ignoring unknown inner kind ${message.kind}")
        }
    }

    private suspend fun routeChatPayload(message: WhistleMessage) {
        when (message.payloadType) {
            // A null type is plain text from an older client; v1 treated it as
            // chat and dropping it would silently lose messages.
            "chat", null -> _lastChatMessageGroupId.value = message.mlsGroupId
            "nickname" -> Timber.d("nickname payload routing lands with the UI slice")
            "avatar" -> Timber.d("avatar payload routing lands with the UI slice")
            "group_avatar" -> Timber.d("group avatar routing lands with the UI slice")
            else -> Timber.d("Unknown chat sub-type '${message.payloadType}'")
        }
    }

    companion object {
        /**
         * Bound on the onboarding driver. Generous because real setup on
         * device took many passes — the revision reached 47 — and a tight
         * bound would give up mid-flight.
         */
        private const val MAX_ONBOARDING_PASSES = 24
    }
}
