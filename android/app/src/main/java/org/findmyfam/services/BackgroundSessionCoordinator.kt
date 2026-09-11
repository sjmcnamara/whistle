package org.findmyfam.services

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import org.findmyfam.models.AppSettings
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Starts everything needed for location sharing to keep working with no UI
 * on screen: relay connection, MLS init, group load, subscriptions, and the
 * location -> group broadcast wiring. Driven by [WhistleForegroundService]
 * (started once there's at least one active group) and by a boot receiver
 * after a reboot.
 *
 * This deliberately duplicates the shape of AppViewModel.onAppear() rather
 * than being called by it: onAppear() drives a splash-screen state machine
 * with UI-only steps (display-name broadcast, key-package publish, avatar
 * rebroadcast collectors) interleaved with this same startup work, and
 * merging the two risked losing that UI sequencing for the sake of a few
 * dozen lines of overlap that are already safe to run twice regardless --
 * every step here ([RelayService.hasConnectedRelays], [MLSService.initialise],
 * [MarmotService.ensureSubscriptionsActive], [LocationService.startUpdating],
 * [MotionService.startMonitoring]) is idempotent by construction, so it's
 * harmless if both this coordinator and AppViewModel.onAppear() end up
 * running in the same process (e.g. the Service started headlessly, then the
 * user opens the app). [LocationBroadcaster] holds the one piece that would
 * otherwise have actually duplicated *logic* (not just a startup call).
 */
@Singleton
class BackgroundSessionCoordinator @Inject constructor(
    @ApplicationContext private val context: Context,
    private val identity: IdentityService,
    private val relay: RelayService,
    private val mls: MLSService,
    private val marmotService: MarmotService,
    private val locationService: LocationService,
    private val motionService: MotionService,
    private val settings: AppSettings,
    private val locationBroadcaster: LocationBroadcaster,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile
    private var started = false

    /**
     * Whether there's actually anything to share right now. [IdentityService]
     * always has a non-null keypair (it generates one on first construction),
     * so that alone can't gate this -- an install that has never been opened,
     * and hence has zero groups, would otherwise still show a persistent
     * "sharing your location" notification after every reboot for no reason.
     * Shared by AppViewModel (decides whether to start/stop the Service) and
     * WhistleForegroundService (decides whether to stay running after a
     * headless start finds nothing to do).
     */
    fun shouldBeSharing(): Boolean {
        val hasLocationPermission =
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        return hasLocationPermission &&
            !settings.isLocationPaused &&
            marmotService.groups.value.any { it.isActive }
    }

    /**
     * Idempotent -- returns immediately if already started. The null check
     * below is defensive rather than a real gate ([IdentityService] always
     * has a keypair once constructed); [shouldBeSharing] is what actually
     * decides whether running this is worthwhile at all.
     */
    suspend fun ensureStarted() {
        if (started) return
        val keys = identity.keys.value ?: run {
            Timber.i("BackgroundSessionCoordinator: no identity -- nothing to start")
            return
        }

        val enabledRelays = settings.relays.filter { it.isEnabled }.map { it.url }

        coroutineScope {
            val relayJob = async {
                if (!relay.hasConnectedRelays()) {
                    relay.connect(keys = keys, relays = enabledRelays)
                }
            }
            val mlsJob = async {
                try {
                    mls.initialise()
                } catch (e: Exception) {
                    Timber.e(e, "BackgroundSessionCoordinator: MLS init failed")
                }
            }
            relayJob.await()
            mlsJob.await()
        }

        try {
            marmotService.refreshGroups()
        } catch (e: Exception) {
            Timber.e(e, "BackgroundSessionCoordinator: failed to load groups")
        }

        locationService.intervalSeconds = settings.locationIntervalSeconds
        locationService.onLocationUpdate = fun(location) {
            val isStationary = if (settings.isMotionAdaptiveEnabled) motionService.isStationary.value else null
            locationBroadcaster.broadcast(location, isStationary, scope)
        }

        marmotService.ensureSubscriptionsActive()

        try {
            marmotService.fetchMissedGiftWraps()
        } catch (e: Exception) {
            Timber.w(e, "BackgroundSessionCoordinator: fetchMissedGiftWraps failed (non-fatal)")
        }

        scope.launch {
            try {
                marmotService.rotateStaleGroups()
            } catch (e: Exception) {
                Timber.w("BackgroundSessionCoordinator: key rotation check failed: ${e.message}")
            }
        }

        if (!settings.isLocationPaused) {
            locationService.startUpdating()
            if (settings.isMotionAdaptiveEnabled) {
                motionService.startMonitoring()
            }
        }

        started = true
        Timber.i("BackgroundSessionCoordinator: started -- relay=${relay.connectionState.value}")
    }
}
