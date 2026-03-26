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

    private val locationManager: LocationManager =
        context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private var lastFireTime: Long = 0L

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
                    30_000L,  // min time between updates (ms)
                    10f,      // min distance (meters)
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
                    30_000L,
                    10f,
                    this
                )
            }
        } catch (e: Exception) {
            Timber.w("Network provider unavailable: ${e.message}")
        }

        _isUpdating.value = true
        Timber.i("LocationService started (interval=${intervalSeconds}s)")
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
        return (System.currentTimeMillis() - lastFireTime) >= intervalSeconds * 1000L
    }

    // LocationListener

    override fun onLocationChanged(location: Location) {
        if (!shouldFire()) {
            Timber.d("Location throttled (interval=${intervalSeconds}s)")
            return
        }
        lastFireTime = System.currentTimeMillis()
        Timber.i("Location firing — acc=${location.accuracy.toInt()}m provider=${location.provider}")
        onLocationUpdate?.invoke(location)
    }

    @Deprecated("Deprecated in API")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    override fun onProviderEnabled(provider: String) {}
    override fun onProviderDisabled(provider: String) {}
}
