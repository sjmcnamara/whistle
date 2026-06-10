package org.findmyfam.services

import android.content.Context
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.DetectedActivity
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
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

        /**
         * Seconds of confirmed non-stationary activity required before flipping
         * the multiplier back from 4× to 1×. Mirrors iOS `movingDebounceSeconds`
         * so a spurious EXIT_STILL — phone bumped on a desk, indoor noise — doesn't
         * yank the publish cadence back to full rate.
         */
        const val MOVING_DEBOUNCE_SECONDS = 30L
    }

    private val _isStationary = MutableStateFlow(false)
    val isStationary: StateFlow<Boolean> = _isStationary

    private val client = ActivityRecognition.getClient(context)
    private var pendingIntent: android.app.PendingIntent? = null
    private var isMonitoring = false

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var pendingMovingJob: Job? = null

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
                pendingMovingJob?.cancel()
                pendingMovingJob = null
                _isStationary.value = false
                pendingIntent = null
                Timber.i("Motion activity monitoring stopped")
            }
    }

    /**
     * Called by [MotionTransitionReceiver] when a transition is detected.
     *
     * Apply ENTER_STILL immediately (stationary is the battery-friendly state —
     * we want to claim it as fast as possible). Apply EXIT_STILL only after
     * [MOVING_DEBOUNCE_SECONDS] of confirmed moving, so a spurious transition
     * doesn't cancel the 4× backoff. A subsequent ENTER_STILL cancels the
     * pending flip.
     */
    fun onTransition(entering: Boolean, activityType: Int) {
        if (activityType != DetectedActivity.STILL) return

        if (entering) {
            pendingMovingJob?.cancel()
            pendingMovingJob = null
            if (!_isStationary.value) {
                _isStationary.value = true
                Timber.i("Motion state: stationary")
            }
            return
        }

        // Exiting STILL — debounce.
        if (!_isStationary.value) return // already moving; nothing to do
        if (pendingMovingJob?.isActive == true) return // already waiting

        pendingMovingJob = scope.launch {
            delay(MOVING_DEBOUNCE_SECONDS * 1000)
            _isStationary.value = false
            Timber.i("Motion state: moving (after ${MOVING_DEBOUNCE_SECONDS}s debounce)")
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
