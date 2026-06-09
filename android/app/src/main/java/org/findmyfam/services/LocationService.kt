package org.findmyfam.services

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import androidx.core.content.ContextCompat
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Wraps Android LocationManager with throttling.
 * No Google Play Services dependency — works on GrapheneOS / degoogled devices.
 * Mirrors iOS LocationService.
 */
@Singleton
class LocationService @Inject constructor(
    @ApplicationContext private val context: Context
) : LocationListener {

    var onLocationUpdate: ((Location) -> Unit)? = null

    private val _isUpdating = MutableStateFlow(false)
    val isUpdating: StateFlow<Boolean> = _isUpdating.asStateFlow()

    private val _hasPermission = MutableStateFlow(false)
    val hasPermission: StateFlow<Boolean> = _hasPermission.asStateFlow()

    var intervalSeconds: Int = 3600

    /** Multiplier applied when motion-adaptive mode is active and device is stationary. */
    var motionMultiplier: Double = 1.0

    private val locationManager: LocationManager =
        context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private var lastFireTime: Long = 0L

    // Per-provider state for accuracy-aware selection. We subscribe to GPS and
    // NETWORK concurrently; without this, a low-accuracy NETWORK fix could
    // beat a soon-to-arrive GPS fix to the throttle gate.
    private var lastGpsFix: Location? = null
    private var lastNetworkFix: Location? = null

    fun updatePermissionStatus(granted: Boolean) {
        _hasPermission.value = granted
        if (granted && !_isUpdating.value) {
            startUpdating()
        }
    }

    private fun checkPermission(): Boolean {
        val fine = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)
        val coarse = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION)
        val granted = fine == PackageManager.PERMISSION_GRANTED || coarse == PackageManager.PERMISSION_GRANTED
        _hasPermission.value = granted
        return granted
    }

    @SuppressLint("MissingPermission")
    fun startUpdating() {
        if (_isUpdating.value) return
        if (!checkPermission()) {
            Timber.i("LocationService: no permission — deferring")
            return
        }

        // Request from GPS and network providers
        try {
            if (locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                locationManager.requestLocationUpdates(
                    LocationManager.GPS_PROVIDER,
                    0L,       // min time between updates (ms) — rely on time throttle only
                    0f,       // min distance (meters) — rely on time throttle only
                    this
                )
            }
        } catch (e: Exception) {
            Timber.w("GPS provider unavailable: ${e.message}")
        }

        try {
            if (locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                locationManager.requestLocationUpdates(
                    LocationManager.NETWORK_PROVIDER,
                    0L,
                    0f,
                    this
                )
            }
        } catch (e: Exception) {
            Timber.w("Network provider unavailable: ${e.message}")
        }

        _isUpdating.value = true
        Timber.i("LocationService started (interval=${intervalSeconds}s)")

        // Seed with last known location so the map shows a pin immediately
        // instead of waiting for the first GPS fix.
        try {
            val lastGps = locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER)
            val lastNet = locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
            val best = listOfNotNull(lastGps, lastNet).maxByOrNull { it.time }
            if (best != null) {
                Timber.i("Seeding with last known location: acc=${best.accuracy.toInt()}m provider=${best.provider}")
                lastFireTime = System.currentTimeMillis()
                onLocationUpdate?.invoke(best)
            }
        } catch (e: SecurityException) {
            Timber.w("Cannot get last known location: ${e.message}")
        }
    }

    fun stopUpdating() {
        locationManager.removeUpdates(this)
        _isUpdating.value = false
        lastFireTime = 0L
        Timber.i("LocationService stopped")
    }

    fun resetThrottle() {
        lastFireTime = 0L
    }

    private fun shouldFire(): Boolean {
        if (lastFireTime == 0L) return true
        return (System.currentTimeMillis() - lastFireTime) >= intervalSeconds * motionMultiplier * 1000L
    }

    // LocationListener

    override fun onLocationChanged(location: Location) {
        when (location.provider) {
            LocationManager.GPS_PROVIDER -> lastGpsFix = location
            LocationManager.NETWORK_PROVIDER -> lastNetworkFix = location
        }

        val now = System.currentTimeMillis()
        val pick = pickBestFix(
            gpsAccuracyM = lastGpsFix?.accuracy,
            gpsTimeMs = lastGpsFix?.time,
            netAccuracyM = lastNetworkFix?.accuracy,
            netTimeMs = lastNetworkFix?.time,
            nowMs = now,
        )
        val best = when (pick) {
            FixPick.GPS -> lastGpsFix
            FixPick.NETWORK -> lastNetworkFix
            FixPick.NONE -> null
        } ?: return

        if (!shouldFire()) {
            Timber.d("Location throttled (interval=${intervalSeconds}s)")
            return
        }
        lastFireTime = now
        Timber.i("Location firing — acc=${best.accuracy.toInt()}m provider=${best.provider}")
        onLocationUpdate?.invoke(best)
    }

    @Deprecated("Deprecated in API")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    override fun onProviderEnabled(provider: String) {}
    override fun onProviderDisabled(provider: String) {}
}

internal enum class FixPick { GPS, NETWORK, NONE }

/**
 * Pick which of two provider fixes to fire. Both-fresh → GPS (typically more
 * accurate). One-fresh → that one. Neither fresh → better accuracy wins.
 *
 * Pure function — testable without Android dependencies. Mirrors how
 * FusedLocationProviderClient blends GPS and Wi-Fi/cell, but stays GMS-free.
 */
internal fun pickBestFix(
    gpsAccuracyM: Float?,
    gpsTimeMs: Long?,
    netAccuracyM: Float?,
    netTimeMs: Long?,
    nowMs: Long,
    freshnessMs: Long = 30_000L,
): FixPick {
    val gpsFresh = gpsAccuracyM != null && gpsTimeMs != null && (nowMs - gpsTimeMs) < freshnessMs
    val netFresh = netAccuracyM != null && netTimeMs != null && (nowMs - netTimeMs) < freshnessMs

    return when {
        gpsFresh -> FixPick.GPS
        netFresh -> FixPick.NETWORK
        gpsAccuracyM != null && netAccuracyM != null ->
            if (gpsAccuracyM <= netAccuracyM) FixPick.GPS else FixPick.NETWORK
        gpsAccuracyM != null -> FixPick.GPS
        netAccuracyM != null -> FixPick.NETWORK
        else -> FixPick.NONE
    }
}
