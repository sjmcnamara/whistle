package org.findmyfam.viewmodels

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import android.net.Uri
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.findmyfam.models.AppSettings
import org.findmyfam.models.BurnPlan
import org.findmyfam.shared.models.AvatarPayload
import org.findmyfam.services.*
import timber.log.Timber
import javax.inject.Inject
import kotlin.math.*
import kotlin.random.Random

/**
 * Root application ViewModel — coordinates startup, owns service references.
 * Mirrors iOS AppViewModel.
 */
@HiltViewModel
class AppViewModel @Inject constructor(
    @ApplicationContext private val context: Context,
    val identity: IdentityService,
    val marmot: MarmotKitService,
    val notices: NoticeCenter,
    val settings: AppSettings,
    val nicknameStore: NicknameStore,
    val memberAvatarStore: MemberAvatarStore,
    val sharedGroupAvatarStore: SharedGroupAvatarStore,
    val diagnosticsCollector: DiagnosticsCollector,
    val locationCache: LocationCache,
    val chatMessageCache: ChatMessageCache,
    val locationService: LocationService,
    val motionService: MotionService,
    val appLockService: AppLockService,
    val locationBroadcaster: LocationBroadcaster,
    val backgroundSessionCoordinator: BackgroundSessionCoordinator
) : ViewModel() {

    val locationViewModel = LocationViewModel(
        locationCache = locationCache,
        nicknameStore = nicknameStore,
        intervalSeconds = { settings.locationIntervalSeconds },
        myPubkeyHex = { identity.publicKeyHex },
        isStationary = { settings.isMotionAdaptiveEnabled && motionService.isStationary.value },
        nextFireMs = { locationService.nextFireTimeMs() }
    )

    enum class StartupPhase {
        SPLASH, CONNECTING, INITIALISING_ENCRYPTION, LOADING_GROUPS, READY
    }

    private val _startupPhase = MutableStateFlow(StartupPhase.SPLASH)
    val startupPhase: StateFlow<StartupPhase> = _startupPhase.asStateFlow()

    /**
     * A startup failure, shown on the Advanced Settings diagnostics row.
     *
     * Kept despite the name's v1 origins (it was the MLS init error): the
     * equivalent v2 failure is MarmotKit refusing to open or start, and the
     * row that displays it is still the right place for the detail. The
     * user-facing half is a banner, posted alongside.
     */
    private val _startupError = MutableStateFlow<String?>(null)
    val startupError: StateFlow<String?> = _startupError.asStateFlow()

    /**
     * Mirrors [MarmotKitService.accountIsReady].
     *
     * Deliberately duplicated rather than read through `marmot` at the call
     * site. Until the account reaches network-ready it has no published relay
     * list or KeyPackage, so creating a group and being invited both fail —
     * which means several screens need this value, and a screen reading it off
     * the service would observe a flow the UI layer otherwise never collects.
     * On iOS the equivalent mistake was made three times before the mirror
     * existed, so it is mirrored here from the start.
     */
    private val _accountIsReady = MutableStateFlow(false)
    val accountIsReady: StateFlow<Boolean> = _accountIsReady.asStateFlow()

    enum class WhistleState { IDLE, SENDING, SENT, FAILED }

    /** Drives the map's "Whistle" button feedback (manual force-publish). */
    private val _whistleState = MutableStateFlow(WhistleState.IDLE)
    val whistleState: StateFlow<WhistleState> = _whistleState.asStateFlow()

    /** True while a manual whistle is in flight; the next broadcast flips to SENT. */
    private var pendingWhistle = false

    private var didStart = false

    /**
     * Called once when the app first composes. Runs the full startup sequence:
     * adopt the stored identity into MarmotKit, load groups, subscribe.
     *
     * There is no separate relay-connect or MLS-init step under v2 — relays
     * are MarmotKit's to dial, and the MLS state machine lives inside it.
     */
    fun onAppear() {
        if (didStart) return
        didStart = true
        viewModelScope.launch { performFullStartup() }
    }

    private suspend fun performFullStartup() {
        val nsec = identity.exportNsec()
        if (nsec == null) {
            Timber.e("No identity available — cannot start MarmotKit")
            // Allow a later onAppear() to retry rather than latching the
            // failure permanently, and dismiss the splash so onboarding or the
            // empty state is actually visible behind it.
            didStart = false
            _startupPhase.value = StartupPhase.READY
            return
        }

        _startupPhase.value = StartupPhase.INITIALISING_ENCRYPTION

        // Adopts the key the app already holds, so the npub carries over the
        // v2 update. Idempotent — signs back into the existing account on
        // every launch after the first. `ensureStarted` rather than `start`
        // because WhistleForegroundService may have got here first.
        try {
            marmot.ensureStarted(adoptingNsec = nsec, expectedReference = identity.publicKeyHex)
        } catch (error: Throwable) {
            val message = error.message ?: error.toString()
            Timber.e(error, "MarmotKit start failed")
            _startupError.value = message
            // Previously only visible in Advanced Settings' MLS row, so a
            // failed start looked like an app that simply had no groups.
            notices.post(
                NoticeCenter.Banner(
                    cause = NoticeCenter.Cause.STARTUP_FAILED,
                    message = "Whistle couldn't start securely: $message",
                    actionTitle = "Retry",
                    action = {
                        didStart = false
                        onAppear()
                    },
                )
            )
            _startupPhase.value = StartupPhase.READY
            return
        }

        // Load persisted groups before the UI goes interactive, so the group
        // list never flashes its empty state on a device that has groups.
        _startupPhase.value = StartupPhase.LOADING_GROUPS
        marmot.refreshGroups()
        Timber.i("Loaded ${marmot.groups.value.size} group(s) from MarmotKit")
        marmot.refreshHistoryNotices()

        // Seed the local display name so the user's own map pin and chat
        // bubbles are named before any broadcast round trip.
        val pubkey = identity.publicKeyHex
        val name = settings.displayName
        if (pubkey != null && name.isNotEmpty()) {
            nicknameStore.set(name, pubkey)
        }

        _startupPhase.value = StartupPhase.READY

        // --- Everything below runs after the splash dismisses. ---
        // The UI is interactive now; these are background housekeeping tasks.

        observeServiceState()
        wireLocationPipeline()
        updateBackgroundServiceState()

        // Start the receive loop. Returns immediately — the subscriptions run
        // inside MarmotKit's runtime.
        marmot.startSubscriptions()

        if (name.isNotEmpty()) {
            broadcastDisplayName(name)
        }

        // Finish account setup. `beginOnboarding` stops at local-ready by
        // design, so until this runs the account has no published relay list
        // or KeyPackage and anything needing one fails with
        // `OnboardingRequired` — which is what "show my member code" hit.
        //
        // Deliberately after the splash rather than on the launch path: this
        // is the half that waits on relays, and the member-code screen already
        // gates on readiness, so opening it early degrades to "Publishing your
        // key…" instead of handing out a code no admin can invite with.
        try {
            Timber.i("Relays handed to MarmotKit: ${marmot.dialledRelayEndpoints.joinToString()}")
            val readiness = marmot.completeAccountSetup()
            Timber.i("Account setup readiness: $readiness")
        } catch (error: Throwable) {
            // Non-fatal — retried on next launch, and the readiness gate stops
            // a half-published account being shown as scannable.
            Timber.w(error, "Account setup did not complete")
        }

        // Catch up on anything that arrived while the app was closed. A
        // Welcome lands through this, not through the live subscription, which
        // was opened before the group existed.
        try {
            marmot.catchUpAccounts()
        } catch (error: Throwable) {
            Timber.w(error, "Catch-up failed (non-fatal)")
        }

        // Always dumped, success or failure. The iOS version logged this only
        // on the success path, so the one run that needed it — where setup
        // threw — printed nothing, and the counters that distinguish "relays
        // never connected" from "relays connected but the list would not
        // publish" were missing.
        Timber.i(marmot.relayDiagnostics())
        Timber.i(marmot.relayListDiagnostics())
        for (line in marmot.onboardingDiagnostics()) {
            Timber.i("onboarding $line")
        }
    }

    /**
     * Collect the service's published state into notices, re-broadcasts and
     * the background-service decision.
     *
     * One place for all of it so the collectors are started exactly once, by
     * one caller, after the service is up — scattered `launch` blocks inside
     * the startup sequence is how the iOS version first did it and it made the
     * ordering impossible to follow.
     */
    private fun observeServiceState() {
        // Re-announce the group photo, and our own nickname/avatar, when
        // membership changes, so a new joiner picks up existing members'
        // profiles without waiting for each of them to next launch or edit.
        // The group photo is guarded to the designated admin inside (a shared
        // value, so only one sender should push it); the nickname/avatar
        // re-announce has no such guard — every existing member's device
        // independently resends only its own profile, so there's no
        // duplicate-sender problem to avoid.
        viewModelScope.launch {
            marmot.lastGroupMembershipChangeId.filterNotNull().collect { (groupId, _) ->
                rebroadcastGroupAvatarIfDesignated(groupId)
                reannounceOwnProfile(groupId)
            }
        }

        // Broadcast display name and avatar, and trigger an immediate location
        // send, for a group we have just been added to.
        viewModelScope.launch {
            marmot.lastJoinedGroupId.filterNotNull().collect { groupId ->
                val displayName = settings.displayName
                if (displayName.isNotEmpty()) {
                    try {
                        marmot.sendNicknameUpdate(displayName, groupId)
                    } catch (error: Throwable) {
                        Timber.w("Failed to broadcast nickname to group $groupId: ${error.message}")
                    }
                }
                // The avatar goes to the new group only — unlike the nickname
                // it is never re-announced on launch, so joining is the one
                // chance the new group has to learn our face without waiting
                // for a change.
                identity.publicKeyHex?.let { pubkey ->
                    memberAvatarStore.ownPayload(pubkey)?.let { payload ->
                        try {
                            marmot.sendAvatarUpdate(payload, groupId)
                            Timber.i("Auto-broadcast avatar to newly joined group $groupId")
                        } catch (error: Throwable) {
                            Timber.w("Failed to broadcast avatar to group $groupId: ${error.message}")
                        }
                    }
                }
                // Reset the location throttle so the new group gets a pin
                // immediately rather than at the next interval.
                locationService.resetThrottle()
            }
        }

        // The receive loop's failures finally have somewhere to go. `lastError`
        // was published with no consumer at all, so anything it reported was
        // dropped on the floor.
        viewModelScope.launch {
            marmot.lastError.filterNotNull().collect { notices.postToast(it) }
        }

        // Account setup is a *state*, so it gets a banner rather than a toast:
        // until it completes, groups cannot be created and nobody can invite
        // this device, and a toast would vanish while that stayed true.
        viewModelScope.launch {
            marmot.accountIsReady.collect { ready ->
                _accountIsReady.value = ready
                notices.setBanner(NoticeCenter.Cause.ACCOUNT_SETUP_INCOMPLETE, active = !ready) {
                    NoticeCenter.Banner(
                        cause = NoticeCenter.Cause.ACCOUNT_SETUP_INCOMPLETE,
                        message = "Still publishing your account. You can't create or join groups until this finishes.",
                        actionTitle = "Retry",
                        action = { runCatching { marmot.completeAccountSetup() } },
                    )
                }
            }
        }

        // MarmotKit raises a durable notice when it cannot prove its history
        // is complete. A state, not an event, so a banner: it stays until the
        // user dismisses it, which is what releases the transport cursor.
        viewModelScope.launch {
            marmot.historyNotices.collect { found ->
                notices.setBanner(NoticeCenter.Cause.HISTORY_INCOMPLETE, active = found.isNotEmpty()) {
                    NoticeCenter.Banner(
                        cause = NoticeCenter.Cause.HISTORY_INCOMPLETE,
                        message = "Some earlier messages or locations may be missing on this device. " +
                            "This can follow a poor connection or an update.",
                        actionTitle = "Dismiss",
                        action = { marmot.dismissHistoryNotices(found.map { it.noticeId }) },
                    )
                }
            }
        }

        // A relay the user has enabled but MarmotKit refuses to dial is a
        // standing misconfiguration, not a transient failure — it needs
        // correcting in Settings, so it gets a banner. The per-row policy
        // label in Advanced Settings only helps someone already looking at
        // that screen.
        viewModelScope.launch {
            marmot.relayStatus
                .map { status -> status.policies.filterValues { it != "allowed" }.keys.sorted() }
                .distinctUntilChanged()
                .collect { unusable ->
                    notices.setBanner(NoticeCenter.Cause.RELAY_UNUSABLE, active = unusable.isNotEmpty()) {
                        NoticeCenter.Banner(
                            cause = NoticeCenter.Cause.RELAY_UNUSABLE,
                            message = if (unusable.size == 1) {
                                "${unusable[0]} can't be used. Remove it in Settings → Advanced."
                            } else {
                                "${unusable.size} relays can't be used. Check Settings → Advanced."
                            },
                        )
                    }
                }
        }

        // Keep WhistleForegroundService running exactly while there's
        // something to share, so the process survives backgrounding without a
        // notification sitting there for an empty account.
        viewModelScope.launch {
            marmot.groups.collect { updateBackgroundServiceState() }
        }
    }

    /**
     * Wire LocationService updates to broadcast location to all groups and
     * cache locally so the map shows the local user's pin.
     */
    private fun wireLocationPipeline() {
        locationService.intervalSeconds = settings.locationIntervalSeconds

        // Observe interval changes and re-apply at runtime, otherwise the user
        // can change the setting and the running LocationService keeps
        // publishing at the value snapshotted at startup. drop(1) skips the
        // initial replay.
        viewModelScope.launch {
            settings.locationIntervalSecondsFlow.drop(1).collect { newInterval ->
                locationService.intervalSeconds = newInterval
                locationService.resetThrottle()
                Timber.i("Interval changed to ${newInterval}s, throttle reset")
            }
        }

        locationService.onLocationUpdate = fun(location) {
            // Fuzz/battery/payload-build/broadcast logic lives in
            // LocationBroadcaster, shared with BackgroundSessionCoordinator's
            // headless path (WhistleForegroundService) so there is exactly one
            // implementation regardless of whether the UI is on screen.
            val isStationary = if (settings.isMotionAdaptiveEnabled) motionService.isStationary.value else null
            locationBroadcaster.broadcast(location, isStationary, viewModelScope) ?: return

            // A manual whistle resolves to SENT as soon as its forced fix is
            // broadcast (the timeout in whistle() only fires if none arrives).
            if (pendingWhistle) {
                pendingWhistle = false
                _whistleState.value = WhistleState.SENT
                scheduleWhistleReset()
            }
        }
        // Observe motion state: update multiplier and refresh map badge.
        viewModelScope.launch {
            motionService.isStationary.collect { stationary ->
                applyMotionMultiplier(stationary)
                locationViewModel.refresh()
            }
        }

        // Start if not paused
        if (!settings.isLocationPaused) {
            locationService.startUpdating()
            if (settings.isMotionAdaptiveEnabled) {
                motionService.startMonitoring()
            }
        }
    }

    /**
     * Force an immediate location publish, ignoring the throttle, motion
     * backoff, and pause state. Drives the map's "Whistle" button.
     */
    fun whistle() {
        if (_whistleState.value == WhistleState.SENDING) return
        _whistleState.value = WhistleState.SENDING
        pendingWhistle = true
        locationService.requestImmediateUpdate()

        // Resolve the button state even if no fix arrives (denied, no signal,
        // no active groups). The forced broadcast flips this to SENT first if
        // it lands; otherwise we report failure.
        viewModelScope.launch {
            delay(12_000)
            if (pendingWhistle) {
                pendingWhistle = false
                _whistleState.value = WhistleState.FAILED
                scheduleWhistleReset()
            }
        }
    }

    /** Return the button to rest a short moment after a terminal result. */
    private fun scheduleWhistleReset() {
        viewModelScope.launch {
            delay(2_000)
            val s = _whistleState.value
            if (s == WhistleState.SENT || s == WhistleState.FAILED) {
                _whistleState.value = WhistleState.IDLE
            }
        }
    }

    private fun applyMotionMultiplier(isStationary: Boolean) {
        val enabled = settings.isMotionAdaptiveEnabled
        val multiplier = if (enabled && isStationary) MotionService.STATIONARY_MULTIPLIER else 1.0
        locationService.motionMultiplier = multiplier
        Timber.i("Motion-adaptive: ${if (enabled) "on" else "off"}, stationary=$isStationary, multiplier=${multiplier}×")
    }

    /**
     * Re-read relay state and republish the account's declared relay list
     * after the user edits relays in Settings.
     *
     * **This does not change which relays this device dials.** The dialled
     * pool is fixed when the runtime opens, so a relay added or disabled here
     * takes effect for *this device* only after a restart — which is why
     * [MarmotKitService.RelayStatus] carries `pendingAdditions` and
     * `pendingRemovals` and the UI says so. What does take effect immediately
     * is the list other people discover us on, which is what gets republished.
     */
    fun applyRelaySettings() {
        viewModelScope.launch {
            val all = settings.relays.map { it.url }
            val enabled = settings.relays.filter { it.isEnabled }.map { it.url }
            try {
                marmot.publishRelayLists(defaultRelays = enabled)
            } catch (error: Throwable) {
                notices.report(error, fallback = "Couldn't update your relay list.") {
                    applyRelaySettings()
                }
            }
            marmot.refreshRelayStatus(all = all, enabled = enabled)
        }
    }

    /** Re-read relay state without changing anything. Safe to call on appear. */
    fun refreshRelayStatus() {
        viewModelScope.launch {
            marmot.refreshRelayStatus(
                all = settings.relays.map { it.url },
                enabled = settings.relays.filter { it.isEnabled }.map { it.url },
            )
        }
    }

    /**
     * Broadcast display name to all active groups.
     * Called from Settings when the user changes their name.
     */
    fun broadcastDisplayName(name: String) {
        viewModelScope.launch {
            for (group in marmot.groups.value.filter { it.isActive }) {
                try {
                    marmot.sendNicknameUpdate(name, group.mlsGroupId)
                } catch (error: Throwable) {
                    Timber.d("Failed to broadcast nickname to group ${group.mlsGroupId}: ${error.message}")
                }
            }
        }
    }

    /**
     * Set the local user's avatar from a picked image and announce it to every
     * active group. Returns false if the image could not be encoded within the
     * wire size cap, so the UI can tell the user rather than leaving them with
     * an avatar only they can see.
     */
    suspend fun setOwnAvatar(uri: Uri): Boolean {
        val pubkey = identity.publicKeyHex ?: return false
        val payload = memberAvatarStore.setOwnImage(uri, pubkey) ?: return false
        broadcastAvatar(payload)
        return true
    }

    /** Clear the local user's avatar and tell every active group to drop it. */
    suspend fun removeOwnAvatar() {
        val pubkey = identity.publicKeyHex ?: return
        broadcastAvatar(memberAvatarStore.removeOwnImage(pubkey))
    }

    // --- Group photo (admin-only) ---

    /**
     * Outcome of setting a group photo, so the UI can say *why* it failed.
     *
     * Deliberately not a Boolean: the first version returned one and the call
     * site dropped it, so every failure — oversized image, missing admin
     * rights — looked identical to success with no photo appearing.
     */
    enum class GroupAvatarUpdate { UPDATED, NOT_ADMIN, COULD_NOT_ENCODE }

    /** Set the group's shared photo and announce it. */
    suspend fun setGroupAvatar(uri: Uri, groupId: String): GroupAvatarUpdate {
        val pubkey = identity.publicKeyHex ?: return GroupAvatarUpdate.NOT_ADMIN
        if (!marmot.isAdmin(pubkey, groupId)) {
            Timber.w("Group avatar rejected locally: not an admin of $groupId")
            return GroupAvatarUpdate.NOT_ADMIN
        }
        val payload = sharedGroupAvatarStore.setImage(uri, groupId)
        if (payload == null) {
            Timber.e("Group avatar for $groupId could not be encoded within the size cap")
            return GroupAvatarUpdate.COULD_NOT_ENCODE
        }
        try {
            marmot.sendGroupAvatarUpdate(payload, groupId)
        } catch (error: Throwable) {
            notices.report(error, fallback = "Couldn't share the group photo.")
        }
        return GroupAvatarUpdate.UPDATED
    }

    /** Clear the group's shared photo and tell the group to drop it. */
    suspend fun removeGroupAvatar(groupId: String) {
        val pubkey = identity.publicKeyHex ?: return
        if (!marmot.isAdmin(pubkey, groupId)) return
        val payload = sharedGroupAvatarStore.removeImagePayload(groupId)
        try {
            marmot.sendGroupAvatarUpdate(payload, groupId)
        } catch (error: Throwable) {
            notices.report(error, fallback = "Couldn't remove the group photo for everyone.")
        }
    }

    /**
     * Re-announce the group photo when membership changes, so a new joiner
     * sees it without waiting for the next edit.
     *
     * Only the designated admin sends. Every admin observes the same
     * membership change, so without this a three-admin group would push three
     * copies of the image to every member.
     */
    private suspend fun rebroadcastGroupAvatarIfDesignated(groupId: String) {
        val pubkey = identity.publicKeyHex ?: return
        if (marmot.designatedBroadcaster(groupId) != pubkey) return
        val payload = sharedGroupAvatarStore.payload(groupId) ?: return
        try {
            marmot.sendGroupAvatarUpdate(payload, groupId)
            Timber.i("Re-announced group avatar to $groupId after membership change")
        } catch (error: Throwable) {
            Timber.w("Group avatar re-announce failed for $groupId: ${error.message}")
        }
    }

    /**
     * Re-announce our own nickname and avatar to one group after a membership
     * change there, so a newly-joined member picks up existing members'
     * profiles instead of only ever seeing their npub. Each device resends
     * only its own profile — no coordination needed, unlike the group photo
     * above.
     */
    private suspend fun reannounceOwnProfile(groupId: String) {
        val pubkey = identity.publicKeyHex ?: return
        val name = settings.displayName
        if (name.isNotEmpty()) {
            try {
                marmot.sendNicknameUpdate(name, groupId)
            } catch (error: Throwable) {
                Timber.w("Nickname re-announce failed for $groupId: ${error.message}")
            }
        }
        memberAvatarStore.ownPayload(pubkey)?.let { payload ->
            try {
                marmot.sendAvatarUpdate(payload, groupId)
                Timber.i("Re-announced own avatar to $groupId after membership change")
            } catch (error: Throwable) {
                Timber.w("Avatar re-announce failed for $groupId: ${error.message}")
            }
        }
    }

    /**
     * Send an avatar payload to every active group.
     *
     * Unlike nicknames this is deliberately *not* re-broadcast on launch: a
     * name is a few bytes, whereas an avatar is several KB per group per
     * launch. Change, join, and another member's membership-change re-announce
     * (see [reannounceOwnProfile]) are the only triggers.
     */
    private suspend fun broadcastAvatar(payload: AvatarPayload) {
        val groups = marmot.groups.value.filter { it.isActive }
        for (group in groups) {
            try {
                marmot.sendAvatarUpdate(payload, group.mlsGroupId)
            } catch (error: Throwable) {
                Timber.w("Failed to broadcast avatar to group ${group.mlsGroupId}: ${error.message}")
            }
        }
        val action = if (payload.isRemoval) "removal" else "update"
        Timber.i("Broadcast avatar $action to ${groups.size} group(s)")
    }

    /**
     * Called when location permission is granted from the UI.
     */
    fun onLocationPermissionGranted() {
        locationService.updatePermissionStatus(true)
        updateBackgroundServiceState()
    }

    /**
     * Called from MainActivity.onResume().
     *
     * Two things need doing on every foreground, and neither is covered by the
     * cold-start path: subscriptions may have been cancelled with the process
     * backgrounded, and anything that arrived while they were down does not
     * replay through them — only [MarmotKitService.catchUpAccounts] fetches it.
     * `startSubscriptions` is a no-op when the loop is already running, so
     * this is safe however the app got here.
     *
     * Guarded on READY so it can't race the initial startup sequence, which
     * starts subscriptions itself.
     */
    fun onForeground() {
        if (_startupPhase.value != StartupPhase.READY) return
        marmot.startSubscriptions()
        viewModelScope.launch {
            try {
                marmot.catchUpAccounts()
            } catch (error: Throwable) {
                Timber.w(error, "Catch-up on foreground failed (non-fatal)")
            }
            marmot.refreshGroups()
            marmot.refreshHistoryNotices()
        }
    }

    /**
     * Starts or stops [WhistleForegroundService] to match whether there's
     * anything to share right now ([BackgroundSessionCoordinator.shouldBeSharing]).
     * A persistent notification for an account with zero groups (or with
     * sharing explicitly paused) would be a nuisance for no benefit, so the
     * Service runs exactly while it's useful — not for the lifetime of the
     * process regardless of state.
     *
     * Not wired to live pause toggling: [AppSettings.isLocationPaused] has no
     * change flow today, matching [LocationService] itself, which also only
     * reads it at startup (SettingsScreen's toggle takes effect on next
     * launch) — pre-existing, unrelated to the migration.
     */
    private fun updateBackgroundServiceState() {
        if (backgroundSessionCoordinator.shouldBeSharing()) {
            WhistleForegroundService.start(context)
        } else {
            WhistleForegroundService.stop(context)
        }
    }

    /**
     * Replace the current identity with a new nsec, tearing down all state.
     */
    fun replaceIdentity(nsec: String) {
        viewModelScope.launch {
            replaceIdentityInternal(nsec)
        }
    }

    /**
     * Destroy the current identity and all associated state, generate a fresh
     * keypair, and restart. One-way operation.
     *
     * Fire-and-forget entry point for callers with nothing to review (no
     * active groups). Normal callers should go through [prepareBurnPlan] /
     * [executeBurnPlan] below so groups are left first.
     */
    fun burnIdentity() {
        viewModelScope.launch {
            val freshKeys = rust.nostr.sdk.Keys.generate()
            val freshNsec = freshKeys.secretKey().toBech32()
            settings.displayName = ""
            replaceIdentityInternal(freshNsec)
        }
    }

    /**
     * Compute what burning will do to every active group, before showing any
     * confirmation. A group where we're the sole admin can't just be left —
     * [MarmotKitService.leaveGroup] already refuses that — so those need an
     * explicit decision: promote another member, or accept that group ends
     * when we burn.
     */
    suspend fun prepareBurnPlan(): BurnPlan {
        val myPubkey = identity.publicKeyHex ?: return BurnPlan(emptyList(), emptyList(), emptyList())
        val leaving = mutableListOf<BurnPlan.LeavingGroup>()
        val promoteOrEnd = mutableListOf<BurnPlan.PromoteOrEndGroup>()
        val ending = mutableListOf<BurnPlan.EndingGroup>()
        for (group in marmot.groups.value.filter { it.isActive }) {
            val groupId = group.mlsGroupId
            // Read the group back live rather than trusting the cached row:
            // the admin list on a chat-list row can lag a promotion that just
            // landed, and this decides whether the group can simply be left.
            val fresh = runCatching { marmot.group(groupId) }.getOrNull()
            val adminPubkeys = fresh?.adminPubkeys ?: group.adminPubkeys
            val amSoleAdmin = adminPubkeys.contains(myPubkey) && adminPubkeys.size == 1
            val name = (fresh?.name ?: group.name).ifEmpty { "Unnamed Group" }
            if (!amSoleAdmin) {
                leaving.add(BurnPlan.LeavingGroup(groupId, name))
                continue
            }
            val members = runCatching { marmot.members(groupId) }.getOrDefault(emptyList())
            val candidates = members
                .filter { it != myPubkey }
                .map { BurnPlan.Candidate(it, nicknameStore.displayName(it)) }
                .sortedBy { it.displayName }
            if (candidates.isEmpty()) {
                ending.add(BurnPlan.EndingGroup(groupId, name))
            } else {
                promoteOrEnd.add(BurnPlan.PromoteOrEndGroup(groupId, name, candidates))
            }
        }
        return BurnPlan(leaving, promoteOrEnd, ending)
    }

    /**
     * Execute a reviewed burn plan: promote where chosen, leave everything
     * leavable, then burn. Never blocks on an individual group's failure — a
     * compromised key being burned is a worse problem than one frozen or
     * stranded group, so we log and continue rather than abort.
     */
    suspend fun executeBurnPlan(plan: BurnPlan, promotions: Map<String, String>) {
        val groupNames = mutableMapOf<String, String>()
        plan.leaving.forEach { groupNames[it.groupId] = it.groupName }
        plan.promoteOrEnd.forEach { groupNames[it.groupId] = it.groupName }

        Timber.i(
            "Burn plan starting: ${plan.leaving.size} leaving, ${plan.promoteOrEnd.size} promote-or-end, ${plan.ending.size} ending"
        )

        val toLeave = plan.leaving.map { it.groupId }.toMutableList()
        for (group in plan.promoteOrEnd) {
            val promoteePubkey = promotions[group.groupId]
            if (promoteePubkey == null) {
                Timber.i("Burn plan: ${group.groupName} (${group.groupId}) — no promotee chosen, group will end")
                continue
            }
            try {
                marmot.promoteToAdmin(promoteePubkey, group.groupId)
                Timber.i("Burn plan: promoted $promoteePubkey in ${group.groupName} (${group.groupId})")
                toLeave.add(group.groupId)
            } catch (error: Throwable) {
                Timber.w("Burn plan: promote FAILED for ${group.groupName} (${group.groupId}): ${error.message} — group will end")
            }
        }
        for (groupId in toLeave) {
            val name = groupNames[groupId] ?: groupId
            try {
                marmot.leaveGroup(groupId)
                Timber.i("Burn plan: left $name ($groupId) successfully")
            } catch (error: Throwable) {
                Timber.w("Burn plan: leave FAILED for $name ($groupId): ${error.message}")
            }
        }
        Timber.i("Burn plan complete, proceeding to destroy identity")
        val freshKeys = rust.nostr.sdk.Keys.generate()
        val freshNsec = freshKeys.secretKey().toBech32()
        settings.displayName = ""
        replaceIdentityInternal(freshNsec)
    }

    private suspend fun replaceIdentityInternal(nsec: String) {
        locationService.stopUpdating()

        // The account is removed through MarmotKit *before* the handle is
        // dropped. v1 wiped its own database here and that was the whole job;
        // MarmotKit keeps a separate store with its own signing key, so
        // skipping this would leave the old identity on the device — and
        // because startup matches an account by id, the next launch would sign
        // straight back into it and carry on as the previous user.
        _accountIsReady.value = false
        marmot.forgetCurrentAccount()
        marmot.shutdown()

        // Drop the handle and move to a fresh root. `shutdown()` does not
        // release the runtime's claim on the old root — the handle does, when
        // it is gone — and reusing the directory would then fail with
        // `RuntimeBusy`, telling the user their import failed when the key was
        // fine. The superseded directory is deleted on next launch.
        marmot.releaseRuntime()
        settings.advanceMarmotKitRootGeneration()

        // Clear identity-bound stores
        nicknameStore.clearAll()
        LocalGroupAvatarStore.removeAll()
        // Member avatars are photographs of real people — they must not survive
        // an identity burn any more than the groups they came from do.
        memberAvatarStore.removeAll()
        sharedGroupAvatarStore.removeAll()
        locationCache.clear()
        chatMessageCache.clear()

        // Reset identity-bound settings, including chat timestamps
        settings.lastEventTimestamp = 0u
        settings.processedEventIds.clear()
        settings.pendingGiftWrapEventIds.clear()
        settings.clearChatTimestamps()

        // v1's MLS database is not wiped here: it is no longer written to, and
        // MarmotKit's own store is dealt with above by `forgetCurrentAccount()`
        // plus the generation bump. A pre-v2 install upgrading still has
        // `whistle.db` on disk; removing it is a separate cleanup, not part of
        // identity replacement.

        // Destroy old key from encrypted storage before importing the new one,
        // so the old nsec is explicitly deleted rather than just overwritten.
        identity.destroyCurrentKey()
        identity.importKey(nsec)

        // Restart
        didStart = false
        _startupPhase.value = StartupPhase.SPLASH
        onAppear()
    }

    override fun onCleared() {
        super.onCleared()
        // The runtime deliberately outlives this ViewModel: it is a process
        // singleton and WhistleForegroundService shares it. Only the
        // subscriptions and location updates are torn down, and even those
        // restart from the foreground service's own path if it is running.
        marmot.stopSubscriptions()
        locationService.stopUpdating()
    }

    // MARK: - Deep links
    //
    // Both v1 deep links are gone, and neither has a v2 replacement.
    // `whistle://invite` carried an invite code a non-member acted on, and
    // protocol v2 has no out-of-group messaging for them to act *with*;
    // `whistle://addmember` carried a group id the prospect could only have
    // learned from such an invite. Adding a member is now always admin-side
    // and in-group (scan their member code), so there is nothing to route.
}

/**
 * Apply a random offset to a coordinate within [radiusMeters].
 * Uses uniform random bearing and area-uniform distance for a circular (not biased) distribution.
 *
 * Extracted as a top-level function for unit-test access.
 */
internal fun fuzzCoordinate(
    lat: Double,
    lon: Double,
    radiusMeters: Double,
    random: Random = Random
): Pair<Double, Double> {
    val bearing = random.nextDouble(0.0, 2 * PI)
    val u = random.nextDouble(0.0, 1.0)
    val distance = sqrt(u) * radiusMeters
    val earthRadius = 6_371_000.0
    val latRad = Math.toRadians(lat)
    val lonRad = Math.toRadians(lon)

    val newLatRad = asin(
        sin(latRad) * cos(distance / earthRadius) +
        cos(latRad) * sin(distance / earthRadius) * cos(bearing)
    )
    val newLonRad = lonRad + atan2(
        sin(bearing) * sin(distance / earthRadius) * cos(latRad),
        cos(distance / earthRadius) - sin(latRad) * sin(newLatRad)
    )
    return Pair(Math.toDegrees(newLatRad), Math.toDegrees(newLonRad))
}
