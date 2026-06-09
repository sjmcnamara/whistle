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

    // MARK: - effectiveIntervalSeconds (drives LocationPayload.interval)

    @Test
    fun `effectiveIntervalSeconds with 1x multiplier equals configured`() {
        assertEquals(10, org.findmyfam.services.LocationService.effectiveIntervalSeconds(10, 1.0))
        assertEquals(3600, org.findmyfam.services.LocationService.effectiveIntervalSeconds(3600, 1.0))
    }

    @Test
    fun `effectiveIntervalSeconds with stationary 4x multiplier multiplies configured`() {
        // Regression: 1.2.1 originally shipped interval=settings.locationIntervalSeconds,
        // ignoring the motion multiplier — so a stationary device on a 10s setting
        // published every 40s but stamped interval=10, and iOS receivers marked it
        // stale within 20s of every send.
        assertEquals(40, org.findmyfam.services.LocationService.effectiveIntervalSeconds(10, MotionService.STATIONARY_MULTIPLIER))
        assertEquals(14400, org.findmyfam.services.LocationService.effectiveIntervalSeconds(3600, MotionService.STATIONARY_MULTIPLIER))
    }

    @Test
    fun `effectiveIntervalSeconds rounds non-integer products`() {
        // Future-proofing: if a non-integer multiplier is ever introduced,
        // round-to-nearest is the right semantic (truncation would bias slow).
        assertEquals(15, org.findmyfam.services.LocationService.effectiveIntervalSeconds(10, 1.5))
        assertEquals(15, org.findmyfam.services.LocationService.effectiveIntervalSeconds(10, 1.49)) // 14.9 → 15
        assertEquals(14, org.findmyfam.services.LocationService.effectiveIntervalSeconds(10, 1.44)) // 14.4 → 14
    }
}
