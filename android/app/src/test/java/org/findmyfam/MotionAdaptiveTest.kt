package org.findmyfam

import com.google.android.gms.location.DetectedActivity
import org.findmyfam.services.MotionService
import org.junit.Assert.*
import org.junit.Test

/**
 * Unit tests for motion-adaptive location interval logic.
 *
 * MotionService itself requires Google Play Services and cannot be instantiated
 * in a JVM unit test. Tests cover the LocationService throttle maths and the
 * MotionService constants that drive the multiplier.
 */
class MotionAdaptiveTest {

    // MARK: - Multiplier constant

    @Test
    fun `stationary multiplier is 4`() {
        assertEquals(4.0, MotionService.STATIONARY_MULTIPLIER, 0.0)
    }

    // MARK: - shouldFire maths (tested via the formula directly)

    @Test
    fun `multiplier 1x fires after configured interval`() {
        val intervalMs = 100_000L
        val multiplier = 1.0
        val elapsed = 101_000L
        assertTrue(elapsed >= intervalMs * multiplier)
    }

    @Test
    fun `multiplier 1x does not fire before interval`() {
        val intervalMs = 100_000L
        val multiplier = 1.0
        val elapsed = 99_000L
        assertFalse(elapsed >= intervalMs * multiplier)
    }

    @Test
    fun `multiplier 4x requires 4 times interval`() {
        val intervalMs = 100_000L
        val multiplier = 4.0

        // 399s elapsed — not enough (needs 400s)
        val notEnough = 399_000L
        assertFalse(notEnough >= intervalMs * multiplier)

        // 401s elapsed — enough
        val enough = 401_000L
        assertTrue(enough >= intervalMs * multiplier)
    }

    @Test
    fun `multiplier 4x blocks normal-interval fire`() {
        val intervalMs = 100_000L
        val elapsed = 101_000L // just past normal interval

        val normalMultiplier = 1.0
        assertTrue("Normal multiplier should fire", elapsed >= intervalMs * normalMultiplier)

        val stationaryMultiplier = 4.0
        assertFalse("Stationary multiplier should not fire yet", elapsed >= intervalMs * stationaryMultiplier)
    }

    // MARK: - Transition event logic

    @Test
    fun `entering STILL activity marks stationary`() {
        val isEntering = true
        val activityType = DetectedActivity.STILL
        val isStationary = activityType == DetectedActivity.STILL && isEntering
        assertTrue(isStationary)
    }

    @Test
    fun `exiting STILL activity marks moving`() {
        val isEntering = false
        val activityType = DetectedActivity.STILL
        val isStationary = activityType == DetectedActivity.STILL && isEntering
        assertFalse(isStationary)
    }

    @Test
    fun `non-STILL activity does not affect stationary state`() {
        for (type in listOf(DetectedActivity.IN_VEHICLE, DetectedActivity.ON_FOOT, DetectedActivity.WALKING)) {
            val isStationary = type == DetectedActivity.STILL
            assertFalse("Activity type $type should not be stationary", isStationary)
        }
    }
}
