package org.findmyfam.services

import android.content.Context
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.DetectedActivity
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Monitors device motion activity via the Activity Transition API and exposes
 * whether the device is stationary.
 *
 * Used by AppViewModel to scale the location publish interval: when stationary
 * the interval is multiplied by [STATIONARY_MULTIPLIER] (4×) to save battery.
 * Transitions are battery-efficient — Android fires them only when the activity
 * type actually changes rather than polling continuously.
 *
 * Requires ACTIVITY_RECOGNITION permission (auto-granted on API < 29, runtime
 * permission on API 29+). The SettingsScreen requests it alongside location.
 */
@Singleton
class MotionService @Inject constructor(
    @ApplicationContext private val context: Context
) {
    companion object {
        const val STATIONARY_MULTIPLIER = 4.0
    }

    private val _isStationary = MutableStateFlow(false)
    val isStationary: StateFlow<Boolean> = _isStationary

    private val client = ActivityRecognition.getClient(context)
    private var pendingIntent: android.app.PendingIntent? = null
    private var isMonitoring = false

    fun startMonitoring() {
        if (isMonitoring) return

        val transitions = listOf(
            ActivityTransition.Builder()
                .setActivityType(DetectedActivity.STILL)
                .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_ENTER)
                .build(),
            ActivityTransition.Builder()
                .setActivityType(DetectedActivity.STILL)
                .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_EXIT)
                .build()
        )

        val pi = buildPendingIntent()
        pendingIntent = pi

        client.requestActivityTransitionUpdates(ActivityTransitionRequest(transitions), pi)
            .addOnSuccessListener {
                isMonitoring = true
                Timber.i("Motion activity monitoring started")
            }
            .addOnFailureListener { e ->
                Timber.w(e, "Failed to start motion activity monitoring")
            }
    }

    fun stopMonitoring() {
        val pi = pendingIntent ?: return
        client.removeActivityTransitionUpdates(pi)
            .addOnCompleteListener {
                isMonitoring = false
                _isStationary.value = false
                pendingIntent = null
                Timber.i("Motion activity monitoring stopped")
            }
    }

    /** Called by [MotionTransitionReceiver] when a transition is detected. */
    fun onTransition(entering: Boolean, activityType: Int) {
        if (activityType == DetectedActivity.STILL) {
            val stationary = entering
            if (_isStationary.value != stationary) {
                _isStationary.value = stationary
                Timber.i("Motion state: ${if (stationary) "stationary" else "moving"}")
            }
        }
    }

    private fun buildPendingIntent(): android.app.PendingIntent {
        val intent = android.content.Intent(context, MotionTransitionReceiver::class.java)
        return android.app.PendingIntent.getBroadcast(
            context,
            0,
            intent,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_MUTABLE
        )
    }
}
