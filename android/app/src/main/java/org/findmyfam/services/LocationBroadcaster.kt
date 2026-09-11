package org.findmyfam.services

import android.content.Context
import android.location.Location
import android.os.BatteryManager
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.findmyfam.models.AppSettings
import org.findmyfam.shared.models.LocationPayload
import org.findmyfam.viewmodels.fuzzCoordinate
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.max

/**
 * Turns a raw location fix into a [LocationPayload] (with fuzzing + battery
 * level applied) and broadcasts it to every active group, caching it locally
 * so the map shows our own pin.
 *
 * Extracted out of AppViewModel.wireLocationPipeline so the exact same
 * fuzz/battery/broadcast logic runs whether the fix arrives while the UI is
 * open (AppViewModel wires this in directly, then layers whistle-button
 * feedback on top) or headlessly (BackgroundSessionCoordinator, driven by
 * WhistleForegroundService with no UI on screen at all). One implementation,
 * so the two paths can't quietly drift apart.
 */
@Singleton
class LocationBroadcaster @Inject constructor(
    @ApplicationContext private val context: Context,
    private val identity: IdentityService,
    private val marmotService: MarmotService,
    private val locationCache: LocationCache,
    private val locationService: LocationService,
    private val settings: AppSettings,
) {
    /**
     * Builds a payload from [location] and broadcasts + caches it to every
     * active group on [scope]. Returns the payload that was broadcast, or
     * null if there's no identity to publish under (nothing was sent).
     */
    fun broadcast(
        location: Location,
        isStationary: Boolean?,
        scope: CoroutineScope,
    ): LocationPayload? {
        val fuzzRadius = settings.locationFuzzMeters
        val lat: Double
        val lon: Double
        if (fuzzRadius > 0) {
            val fuzzed = fuzzCoordinate(location.latitude, location.longitude, fuzzRadius.toDouble())
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
            stationary = isStationary
        )
        val myPubkey = identity.publicKeyHex ?: return null
        val groups = marmotService.groups.value.filter { it.isActive }
        for (group in groups) {
            // Cache locally so the map shows our own pin
            locationCache.update(group.mlsGroupId, myPubkey, payload)
            // Broadcast to group
            scope.launch {
                try {
                    marmotService.sendLocationUpdate(payload, group.mlsGroupId)
                } catch (e: Exception) {
                    Timber.e("Failed to send location to group ${group.mlsGroupId}: ${e.message}")
                }
            }
        }
        return payload
    }
}
