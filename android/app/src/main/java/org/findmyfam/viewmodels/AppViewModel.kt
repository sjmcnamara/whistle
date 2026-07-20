package org.findmyfam.viewmodels

import android.content.Context
import android.net.Uri
import android.os.BatteryManager
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.delay
import android.Manifest
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import kotlinx.coroutines.launch
import org.findmyfam.models.AppSettings
import org.findmyfam.shared.models.AvatarPayload
import org.findmyfam.shared.models.GroupAvatarPayload
import org.findmyfam.shared.models.LocationPayload
import org.findmyfam.services.*
import timber.log.Timber
import javax.inject.Inject
import kotlin.math.*
import kotlin.random.Random

/**
 * Root application ViewModel -- coordinates startup, owns service references.
 * Mirrors iOS AppViewModel.
 */
@HiltViewModel
class AppViewModel @Inject constructor(
    @ApplicationContext private val context: Context,
    val identity: IdentityService,
    val relay: RelayService,
    val mls: MLSService,
    val marmotService: MarmotService,
    val settings: AppSettings,
    val nicknameStore: NicknameStore,
    val memberAvatarStore: MemberAvatarStore,
    val sharedGroupAvatarStore: SharedGroupAvatarStore,
    val pendingInviteStore: PendingInviteStore,
    val pendingLeaveStore: PendingLeaveStore,
    val pendingWelcomeStore: PendingWelcomeStore,
    val joinRequestStore: JoinRequestStore,
    val locationCache: LocationCache,
    val chatMessageCache: ChatMessageCache,
    val healthTracker: GroupHealthTracker,
    val locationService: LocationService,
    val motionService: MotionService,
    val appLockService: AppLockService
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

    private val _mlsError = MutableStateFlow<String?>(null)
    val mlsError: StateFlow<String?> = _mlsError.asStateFlow()

    enum class WhistleState { IDLE, SENDING, SENT, FAILED }

    /** Drives the map's "Whistle" button feedback (manual force-publish). */
    private val _whistleState = MutableStateFlow(WhistleState.IDLE)
    val whistleState: StateFlow<WhistleState> = _whistleState.asStateFlow()

    /** True while a manual whistle is in flight; the next broadcast flips to SENT. */
    private var pendingWhistle = false

    private var didStart = false

    /**
     * Called once when the app first composes. Runs the full startup sequence:
     * relay connect + MLS init (parallel), then loads groups and starts subscriptions.
     */
    fun onAppear() {
        if (didStart) return
        didStart = true

        viewModelScope.launch {
            val keys = identity.keys.value
            if (keys == null) {
                Timber.e("No identity available -- cannot connect to relays")
                _startupPhase.value = StartupPhase.READY
                return@launch
            }

            // Connect to relays and initialise MLS in parallel
            _startupPhase.value = StartupPhase.CONNECTING

            val enabledRelays = settings.relays.filter { it.isEnabled }.map { it.url }

            val relayJob = async { relay.connect(keys = keys, relays = enabledRelays) }
            val mlsJob = async {
                try {
                    mls.initialise()
                } catch (e: Exception) {
                    Timber.e(e, "MLSService init failed")
                    _mlsError.value = e.message
                }
            }

            relayJob.await()
            _startupPhase.value = StartupPhase.INITIALISING_ENCRYPTION
            mlsJob.await()

            _startupPhase.value = StartupPhase.LOADING_GROUPS

            // Load groups from MDK
            try {
                marmotService.refreshGroups()
            } catch (e: Exception) {
                Timber.e(e, "Failed to load groups")
            }

            // Seed local display name into NicknameStore
            val pubkey = identity.publicKeyHex
            val name = settings.displayName
            if (pubkey != null && name.isNotEmpty()) {
                nicknameStore.set(name, pubkey)
            }

            // Broadcast display name to all existing groups on startup
            if (name.isNotEmpty()) {
                broadcastDisplayName(name)
            }

            // Publish a fresh key package so this device is always "joinable"
            // by npub (admin can scan our QR and add us directly).
            val enabledRelayUrls = settings.relays.filter { it.isEnabled }.map { it.url }
            if (enabledRelayUrls.isNotEmpty()) {
                try {
                    marmotService.publishKeyPackage(enabledRelayUrls)
                    Timber.i("Published key package on startup to ${enabledRelayUrls.size} relay(s)")
                } catch (e: Exception) {
                    Timber.w(e, "Key package publish failed (non-fatal)")
                }
            }

            // Start real-time subscriptions
            marmotService.startSubscriptions()

            // Fetch any gift-wraps (Welcomes) that arrived while offline
            try {
                marmotService.fetchMissedGiftWraps()
            } catch (e: Exception) {
                Timber.w(e, "fetchMissedGiftWraps failed (non-fatal)")
            }

            // Re-announce the group photo when membership changes, so a new
            // joiner sees it without waiting for the next edit. Guarded to the
            // designated admin inside — every admin observes the same change.
            viewModelScope.launch {
                marmotService.lastGroupMembershipChangeId.collect { change ->
                    change?.let { rebroadcastGroupAvatarIfDesignated(it.first) }
                }
            }

            // Broadcast display name and trigger immediate location send for newly joined groups
            viewModelScope.launch {
                marmotService.lastJoinedGroupId.collect { groupId ->
                    if (groupId != null) {
                        val displayName = settings.displayName
                        if (displayName.isNotEmpty()) {
                            try {
                                marmotService.sendNicknameUpdate(
                                    name = displayName,
                                    groupId = groupId
                                )
                            } catch (e: Exception) {
                                Timber.w("Failed to broadcast nickname to group $groupId: ${e.message}")
                            }
                        }
                        // Avatar goes to the new group only — unlike the nickname it is
                        // never re-announced on launch, so joining is the one chance the
                        // new group has to learn our face without waiting for a change.
                        identity.publicKeyHex?.let { pubkey ->
                            memberAvatarStore.ownPayload(pubkey)?.let { payload ->
                                try {
                                    marmotService.sendAvatarUpdate(payload, groupId)
                                    Timber.i("Auto-broadcast avatar to newly joined group $groupId")
                                } catch (e: Exception) {
                                    Timber.w("Failed to broadcast avatar to group $groupId: ${e.message}")
                                }
                            }
                        }
                        // Reset location throttle so the new group gets a pin immediately
                        locationService.resetThrottle()
                    }
                }
            }

            // Run key rotation check
            viewModelScope.launch {
                try {
                    marmotService.rotateStaleGroups()
                } catch (e: Exception) {
                    Timber.w("Key rotation check failed: ${e.message}")
                }
            }

            // Wire location pipeline: LocationService → MarmotService (all groups)
            wireLocationPipeline()

            _startupPhase.value = StartupPhase.READY
            Timber.i("Startup complete -- relay: ${relay.connectionState.value}, MLS: ${mls.isInitialised}")
        }
    }

    /**
     * Apply a random offset to a coordinate within [radiusMeters].
     * Delegates to the top-level pure function for testability.
     */
    private fun fuzzedCoordinate(lat: Double, lon: Double, radiusMeters: Double): Pair<Double, Double> {
        return fuzzCoordinate(lat, lon, radiusMeters)
    }

    /**
     * Wire LocationService updates to broadcast location to all groups
     * and cache locally so the map shows the local user's pin.
     */
    private fun wireLocationPipeline() {
        locationService.intervalSeconds = settings.locationIntervalSeconds

        // Mirror iOS AppViewModel.swift:173 — observe interval changes and
        // re-apply at runtime, otherwise the user can change the setting in
        // Settings and the running LocationService keeps publishing at the
        // value snapshot at startup. drop(1) skips the initial replay.
        viewModelScope.launch {
            settings.locationIntervalSecondsFlow.drop(1).collect { newInterval ->
                locationService.intervalSeconds = newInterval
                locationService.resetThrottle()
                Timber.i("Interval changed to ${newInterval}s, throttle reset")
            }
        }

        locationService.onLocationUpdate = fun(location) {
            val fuzzRadius = settings.locationFuzzMeters
            val lat: Double
            val lon: Double
            if (fuzzRadius > 0) {
                val fuzzed = fuzzedCoordinate(location.latitude, location.longitude, fuzzRadius.toDouble())
                lat = fuzzed.first
                lon = fuzzed.second
                Timber.d("Location fuzzed by up to ${fuzzRadius}m")
            } else {
                lat = location.latitude
                lon = location.longitude
            }

            val battery = (context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager)
                ?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                ?.takeIf { it in 0..100 }

            val payload = LocationPayload(
                lat = lat,
                lon = lon,
                alt = location.altitude,
                acc = if (fuzzRadius > 0) max(location.accuracy.toDouble(), fuzzRadius.toDouble()) else location.accuracy.toDouble(),
                ts = System.currentTimeMillis() / 1000,
                batt = battery,
                interval = locationService.effectiveIntervalSeconds, // reflects motion multiplier so receivers grade staleness against real cadence
                // Only meaningful while Movement Aware is on; otherwise send null
                // ("unknown") rather than false, which would claim we're moving.
                stationary = if (settings.isMotionAdaptiveEnabled) motionService.isStationary.value else null
            )
            val myPubkey = identity.publicKeyHex ?: return
            val groups = marmotService.groups.value.filter { it.isActive }
            for (group in groups) {
                // Cache locally so the map shows our own pin
                locationCache.update(group.mlsGroupId, myPubkey, payload)
                // Broadcast to group
                viewModelScope.launch {
                    try {
                        marmotService.sendLocationUpdate(payload, group.mlsGroupId)
                    } catch (e: Exception) {
                        Timber.e("Failed to send location to group ${group.mlsGroupId}: ${e.message}")
                    }
                }
            }

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
     * Disconnect and reconnect to relays using current settings.
     * Called when the user toggles, adds, or removes relays.
     */
    fun reconnectRelays() {
        viewModelScope.launch {
            val keys = identity.keys.value ?: run {
                Timber.w("Cannot reconnect — no identity keys")
                return@launch
            }
            relay.disconnect()
            val enabledRelays = settings.relays.filter { it.isEnabled }.map { it.url }
            relay.connect(keys = keys, relays = enabledRelays)
        }
    }

    /**
     * Broadcast display name to all active groups.
     * Called from Settings when the user changes their name.
     */
    fun broadcastDisplayName(name: String) {
        val groups = marmotService.groups.value
        for (group in groups) {
            viewModelScope.launch {
                try {
                    marmotService.sendNicknameUpdate(name, group.mlsGroupId)
                } catch (e: Exception) {
                    Timber.d("Failed to broadcast nickname to group ${group.mlsGroupId}: ${e.message}")
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
     * Set the group's shared photo and announce it. Returns false if the image
     * could not be encoded within the wire cap, or if we are not an admin.
     */
    suspend fun setGroupAvatar(uri: Uri, groupId: String): Boolean {
        val pubkey = identity.publicKeyHex ?: return false
        if (!marmotService.isAdmin(pubkey, groupId)) return false
        val payload = sharedGroupAvatarStore.setImage(uri, groupId) ?: return false
        try {
            marmotService.sendGroupAvatarUpdate(payload, groupId)
        } catch (e: Exception) {
            Timber.w("Failed to broadcast group avatar for $groupId: ${e.message}")
        }
        return true
    }

    /** Clear the group's shared photo and tell the group to drop it. */
    suspend fun removeGroupAvatar(groupId: String) {
        val pubkey = identity.publicKeyHex ?: return
        if (!marmotService.isAdmin(pubkey, groupId)) return
        val payload = sharedGroupAvatarStore.removeImagePayload(groupId)
        try {
            marmotService.sendGroupAvatarUpdate(payload, groupId)
        } catch (e: Exception) {
            Timber.w("Failed to broadcast group avatar removal for $groupId: ${e.message}")
        }
    }

    /**
     * Re-announce the group photo when membership changes, so a new joiner sees
     * it without waiting for the next edit.
     *
     * Only the designated admin sends. Every admin observes the same membership
     * change, so without this a three-admin group would push three copies of
     * the image to every member.
     */
    private suspend fun rebroadcastGroupAvatarIfDesignated(groupId: String) {
        val pubkey = identity.publicKeyHex ?: return
        if (marmotService.designatedBroadcaster(groupId) != pubkey) return
        val payload = sharedGroupAvatarStore.payload(groupId) ?: return
        try {
            marmotService.sendGroupAvatarUpdate(payload, groupId)
            Timber.i("Re-announced group avatar to $groupId after membership change")
        } catch (e: Exception) {
            Timber.w("Group avatar re-announce failed for $groupId: ${e.message}")
        }
    }

    /**
     * Send an avatar payload to every active group.
     *
     * Unlike nicknames this is deliberately *not* re-broadcast on launch: a name
     * is a few bytes, whereas an avatar is several KB per group per launch.
     * Change and join are the only triggers.
     */
    private suspend fun broadcastAvatar(payload: AvatarPayload) {
        val groups = marmotService.groups.value.filter { it.isActive }
        for (group in groups) {
            try {
                marmotService.sendAvatarUpdate(payload, group.mlsGroupId)
            } catch (e: Exception) {
                Timber.w("Failed to broadcast avatar to group ${group.mlsGroupId}: ${e.message}")
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
     * Destroy the current identity and all associated state, generate a
     * fresh keypair, and restart. One-way operation.
     */
    fun burnIdentity() {
        viewModelScope.launch {
            val freshKeys = rust.nostr.sdk.Keys.generate()
            val freshNsec = freshKeys.secretKey().toBech32()
            settings.displayName = ""
            replaceIdentityInternal(freshNsec)
        }
    }

    private suspend fun replaceIdentityInternal(nsec: String) {
        // Stop everything
        locationService.stopUpdating()
        marmotService.stopSubscriptions()
        relay.disconnect()

        // Clear stores
        nicknameStore.clearAll()
        // Member avatars are photographs of real people — they must not survive
        // an identity burn any more than the groups they came from do.
        memberAvatarStore.removeAll()
        sharedGroupAvatarStore.removeAll()
        pendingInviteStore.removeAll()
        pendingLeaveStore.removeAll()
        pendingWelcomeStore.removeAll()
        joinRequestStore.removeAll()
        locationCache.clear()
        chatMessageCache.clear()

        // Clear settings — including pendingLeaveRequests and chat timestamps
        settings.lastEventTimestamp = 0u
        settings.processedEventIds.clear()
        settings.pendingGiftWrapEventIds.clear()
        settings.pendingLeaveRequests = mutableMapOf()
        settings.clearChatTimestamps()

        // Reset MLS database — overwrites files with zeros before deletion
        mls.resetDatabase()

        // Destroy old key from encrypted storage before importing new one
        identity.destroyCurrentKey()

        // Import the new key
        identity.importKey(nsec)

        // Restart
        didStart = false
        _startupPhase.value = StartupPhase.SPLASH
        onAppear()
    }

    override fun onCleared() {
        super.onCleared()
        marmotService.stopSubscriptions()
        locationService.stopUpdating()
    }
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
