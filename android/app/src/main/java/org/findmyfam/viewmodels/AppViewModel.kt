package org.findmyfam.viewmodels

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import android.Manifest
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import kotlinx.coroutines.launch
import org.findmyfam.models.AppSettings
import org.findmyfam.shared.models.LocationPayload
import org.findmyfam.services.*
import timber.log.Timber
import javax.inject.Inject

/**
 * Root application ViewModel -- coordinates startup, owns service references.
 * Mirrors iOS AppViewModel.
 */
@HiltViewModel
class AppViewModel @Inject constructor(
    val identity: IdentityService,
    val relay: RelayService,
    val mls: MLSService,
    val marmotService: MarmotService,
    val settings: AppSettings,
    val nicknameStore: NicknameStore,
    val pendingInviteStore: PendingInviteStore,
    val pendingLeaveStore: PendingLeaveStore,
    val pendingWelcomeStore: PendingWelcomeStore,
    val locationCache: LocationCache,
    val healthTracker: GroupHealthTracker,
    val locationService: LocationService,
    val appLockService: AppLockService
) : ViewModel() {

    val locationViewModel = LocationViewModel(
        locationCache = locationCache,
        nicknameStore = nicknameStore,
        intervalSeconds = { settings.locationIntervalSeconds },
        myPubkeyHex = { identity.publicKeyHex }
    )

    enum class StartupPhase {
        SPLASH, CONNECTING, INITIALISING_ENCRYPTION, LOADING_GROUPS, READY
    }

    private val _startupPhase = MutableStateFlow(StartupPhase.SPLASH)
    val startupPhase: StateFlow<StartupPhase> = _startupPhase.asStateFlow()

    private val _mlsError = MutableStateFlow<String?>(null)
    val mlsError: StateFlow<String?> = _mlsError.asStateFlow()

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
     * Wire LocationService updates to broadcast location to all groups
     * and cache locally so the map shows the local user's pin.
     */
    private fun wireLocationPipeline() {
        locationService.intervalSeconds = settings.locationIntervalSeconds
        locationService.onLocationUpdate = fun(location) {
            val payload = LocationPayload(
                lat = location.latitude,
                lon = location.longitude,
                alt = location.altitude,
                acc = location.accuracy.toDouble(),
                ts = System.currentTimeMillis() / 1000
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
        }
        // Start if not paused
        if (!settings.isLocationPaused) {
            locationService.startUpdating()
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
        pendingInviteStore.removeAll()
        pendingLeaveStore.removeAll()
        pendingWelcomeStore.removeAll()
        locationCache.clear()

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
