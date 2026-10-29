package org.findmyfam.services

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.findmyfam.models.AppSettings
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Starts everything needed for location sharing to keep working with no UI on
 * screen: the MarmotKit runtime, group load, subscriptions, and the location →
 * group broadcast wiring. Driven by [WhistleForegroundService] (started once
 * there's at least one active group) and by a boot receiver after a reboot.
 *
 * This deliberately duplicates the shape of `AppViewModel.onAppear()` rather
 * than being called by it: onAppear() drives a splash-screen state machine with
 * UI-only steps (notice banners, display-name broadcast, avatar rebroadcast
 * collectors) interleaved with this same startup work, and merging the two
 * risked losing that UI sequencing for the sake of a few dozen lines of overlap
 * that are already safe to run twice — every step here
 * ([MarmotKitService.ensureStarted], [MarmotKitService.startSubscriptions],
 * [LocationService.startUpdating], [MotionService.startMonitoring]) is
 * idempotent by construction, so it is harmless if both this coordinator and
 * onAppear() run in the same process (the Service started headlessly, then the
 * user opens the app). [LocationBroadcaster] holds the one piece that would
 * otherwise have actually duplicated *logic* rather than just a startup call.
 *
 * The idempotence is load-bearing in a way it was not under v1, and the reason
 * is worth stating: both paths share one [MarmotKitService] (see `AppModule`),
 * because a MarmotKit runtime owns its root directory exclusively and a second
 * one on the same root fails with `RuntimeBusy`. So this cannot simply build
 * its own.
 */
@Singleton
class BackgroundSessionCoordinator @Inject constructor(
    @ApplicationContext private val context: Context,
    private val identity: IdentityService,
    private val marmot: MarmotKitService,
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
            marmot.groups.value.any { it.isActive }
    }

    /**
     * Idempotent -- returns immediately if already started. The null check
     * below is defensive rather than a real gate ([IdentityService] always has
     * a keypair once constructed); [shouldBeSharing] is what actually decides
     * whether running this is worthwhile at all.
     */
    suspend fun ensureStarted() {
        if (started) return
        val nsec = identity.exportNsec() ?: run {
            Timber.i("BackgroundSessionCoordinator: no identity -- nothing to start")
            return
        }

        try {
            marmot.ensureStarted(adoptingNsec = nsec, expectedReference = identity.publicKeyHex)
        } catch (error: Exception) {
            // No notice is posted: there is no UI to post to, and
            // AppViewModel's own startup will report it with a retry banner if
            // and when the user opens the app.
            Timber.e(error, "BackgroundSessionCoordinator: MarmotKit start failed")
            return
        }

        try {
            marmot.refreshGroups()
        } catch (error: Exception) {
            Timber.e(error, "BackgroundSessionCoordinator: failed to load groups")
        }

        locationService.intervalSeconds = settings.locationIntervalSeconds
        locationService.onLocationUpdate = fun(location) {
            val isStationary = if (settings.isMotionAdaptiveEnabled) motionService.isStationary.value else null
            locationBroadcaster.broadcast(location, isStationary, scope)
        }

        marmot.startSubscriptions()

        scope.launch {
            // Setup has to finish before this device can be invited or create
            // a group, and it is the half that waits on relays. Run here too,
            // not only in AppViewModel: an install whose first launch after
            // the update is a reboot would otherwise sit un-published until
            // the user next opened the app.
            runCatching { marmot.completeAccountSetup() }
                .onFailure { Timber.w(it, "BackgroundSessionCoordinator: account setup did not complete") }
            runCatching { marmot.catchUpAccounts() }
                .onFailure { Timber.w(it, "BackgroundSessionCoordinator: catch-up failed (non-fatal)") }
        }

        if (!settings.isLocationPaused) {
            locationService.startUpdating()
            if (settings.isMotionAdaptiveEnabled) {
                motionService.startMonitoring()
            }
        }

        started = true
        Timber.i("BackgroundSessionCoordinator: started")
    }
}
