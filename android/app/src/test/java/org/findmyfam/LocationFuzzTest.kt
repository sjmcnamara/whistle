package org.findmyfam

import org.findmyfam.viewmodels.fuzzCoordinate
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.*
import kotlin.random.Random

/**
 * Tests for the location fuzzing algorithm.
 * Validates geographic correctness, radius bounds, and distribution uniformity.
 */
class LocationFuzzTest {

    private val dublin = Pair(53.3498, -6.2603)       // Dublin, Ireland
    private val equator = Pair(0.0, 0.0)              // Null Island
    private val northPole = Pair(89.99, 0.0)          // Near north pole
    private val sydney = Pair(-33.8688, 151.2093)     // Sydney, Australia

    /** Haversine distance in meters between two lat/lon pairs. */
    private fun haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val r = 6_371_000.0
        val dLat = Math.toRadians(lat2 - lat1)
        val dLon = Math.toRadians(lon2 - lon1)
        val a = sin(dLat / 2).pow(2) +
                cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) * sin(dLon / 2).pow(2)
        return 2 * r * asin(sqrt(a))
    }

    @Test
    fun fuzzedCoordinate_staysWithinRadius_10m() {
        val radius = 10.0
        repeat(500) {
            val (lat, lon) = fuzzCoordinate(dublin.first, dublin.second, radius)
            val dist = haversineMeters(dublin.first, dublin.second, lat, lon)
            assertTrue("Distance $dist exceeded radius $radius", dist <= radius + 0.01)
        }
    }

    @Test
    fun fuzzedCoordinate_staysWithinRadius_200m() {
        val radius = 200.0
        repeat(500) {
            val (lat, lon) = fuzzCoordinate(dublin.first, dublin.second, radius)
            val dist = haversineMeters(dublin.first, dublin.second, lat, lon)
            assertTrue("Distance $dist exceeded radius $radius", dist <= radius + 0.1)
        }
    }

    @Test
    fun fuzzedCoordinate_staysWithinRadius_atEquator() {
        val radius = 50.0
        repeat(500) {
            val (lat, lon) = fuzzCoordinate(equator.first, equator.second, radius)
            val dist = haversineMeters(equator.first, equator.second, lat, lon)
            assertTrue("Distance $dist exceeded radius $radius at equator", dist <= radius + 0.01)
        }
    }

    @Test
    fun fuzzedCoordinate_staysWithinRadius_nearPole() {
        val radius = 50.0
        repeat(500) {
            val (lat, lon) = fuzzCoordinate(northPole.first, northPole.second, radius)
            val dist = haversineMeters(northPole.first, northPole.second, lat, lon)
            assertTrue("Distance $dist exceeded radius $radius near pole", dist <= radius + 0.1)
        }
    }

    @Test
    fun fuzzedCoordinate_staysWithinRadius_southernHemisphere() {
        val radius = 100.0
        repeat(500) {
            val (lat, lon) = fuzzCoordinate(sydney.first, sydney.second, radius)
            val dist = haversineMeters(sydney.first, sydney.second, lat, lon)
            assertTrue("Distance $dist exceeded radius $radius in Sydney", dist <= radius + 0.1)
        }
    }

    @Test
    fun fuzzedCoordinate_zeroRadius_returnsOriginal() {
        val (lat, lon) = fuzzCoordinate(dublin.first, dublin.second, 0.0)
        assertEquals(dublin.first, lat, 1e-10)
        assertEquals(dublin.second, lon, 1e-10)
    }

    @Test
    fun fuzzedCoordinate_producesVariedResults() {
        val results = (1..100).map {
            fuzzCoordinate(dublin.first, dublin.second, 200.0)
        }
        val uniqueLats = results.map { it.first }.toSet()
        val uniqueLons = results.map { it.second }.toSet()
        assertTrue("Expected varied latitudes, got ${uniqueLats.size}", uniqueLats.size > 50)
        assertTrue("Expected varied longitudes, got ${uniqueLons.size}", uniqueLons.size > 50)
    }

    @Test
    fun fuzzedCoordinate_uniformDistribution_notClusteredAtCenter() {
        // With area-uniform sampling (sqrt(u) * radius), fewer points should be
        // near the center than the periphery. Check that < 25% of points fall
        // within the inner 25% of the radius (which covers ~6.25% of the area).
        val radius = 200.0
        val innerRadius = radius * 0.25
        val n = 2000
        var innerCount = 0
        repeat(n) {
            val (lat, lon) = fuzzCoordinate(dublin.first, dublin.second, radius)
            val dist = haversineMeters(dublin.first, dublin.second, lat, lon)
            if (dist <= innerRadius) innerCount++
        }
        val innerFraction = innerCount.toDouble() / n
        // Area-uniform: expected fraction ~= (0.25)^2 = 0.0625
        assertTrue(
            "Too many points near center: $innerFraction (expected ~6.25%)",
            innerFraction < 0.15
        )
    }

    @Test
    fun fuzzedCoordinate_deterministic_withSeededRandom() {
        val rng = Random(42)
        val (lat1, lon1) = fuzzCoordinate(dublin.first, dublin.second, 100.0, rng)

        val rng2 = Random(42)
        val (lat2, lon2) = fuzzCoordinate(dublin.first, dublin.second, 100.0, rng2)

        assertEquals("Same seed should produce same lat", lat1, lat2, 1e-15)
        assertEquals("Same seed should produce same lon", lon1, lon2, 1e-15)
    }

    @Test
    fun fuzzedCoordinate_producesValidLatLon() {
        repeat(1000) {
            val (lat, lon) = fuzzCoordinate(dublin.first, dublin.second, 500.0)
            assertTrue("Latitude $lat out of range", lat in -90.0..90.0)
            assertTrue("Longitude $lon out of range", lon in -180.0..180.0)
        }
    }
}
