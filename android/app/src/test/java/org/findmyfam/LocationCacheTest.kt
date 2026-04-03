package org.findmyfam

import org.findmyfam.services.LocationCache
import org.findmyfam.shared.models.LocationPayload
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class LocationCacheTest {

    private lateinit var cache: LocationCache

    private val group1 = "group-aaa"
    private val group2 = "group-bbb"
    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)

    @Before
    fun setUp() {
        cache = LocationCache()
    }

    // region Insert / Update

    @Test
    fun `insert stores location`() {
        cache.update(group1, alice, makePayload(37.77, -122.42))
        assertEquals(1, cache.locations.value.size)
        assertEquals(37.77, cache.locations.value.values.first().payload.lat, 0.001)
    }

    @Test
    fun `update overwrites existing entry for same member and group`() {
        cache.update(group1, alice, makePayload(10.0, 20.0))
        cache.update(group1, alice, makePayload(30.0, 40.0))
        assertEquals(1, cache.locations.value.size)
        assertEquals(30.0, cache.locations.value.values.first().payload.lat, 0.001)
    }

    @Test
    fun `different members in same group stored separately`() {
        cache.update(group1, alice, makePayload(1.0, 1.0))
        cache.update(group1, bob, makePayload(2.0, 2.0))
        assertEquals(2, cache.locations.value.size)
    }

    @Test
    fun `same member in different groups stored separately`() {
        cache.update(group1, alice, makePayload(1.0, 1.0))
        cache.update(group2, alice, makePayload(2.0, 2.0))
        assertEquals(2, cache.locations.value.size)
        assertEquals(1.0, cache.locationsForGroup(group1).first().payload.lat, 0.001)
        assertEquals(2.0, cache.locationsForGroup(group2).first().payload.lat, 0.001)
    }

    // endregion

    // region Group filtering

    @Test
    fun `locationsForGroup returns only that group`() {
        cache.update(group1, alice, makePayload(1.0, 1.0))
        cache.update(group2, bob, makePayload(2.0, 2.0))

        val g1 = cache.locationsForGroup(group1)
        assertEquals(1, g1.size)
        assertEquals(alice, g1.first().memberPubkeyHex)

        val g2 = cache.locationsForGroup(group2)
        assertEquals(1, g2.size)
        assertEquals(bob, g2.first().memberPubkeyHex)
    }

    @Test
    fun `locationsForGroup returns empty for unknown group`() {
        cache.update(group1, alice, makePayload(1.0, 1.0))
        assertTrue(cache.locationsForGroup("unknown-group").isEmpty())
    }

    @Test
    fun `locations spans all groups`() {
        cache.update(group1, alice, makePayload(1.0, 1.0))
        cache.update(group2, bob, makePayload(2.0, 2.0))
        assertEquals(2, cache.locations.value.size)
    }

    // endregion

    // region Empty state

    @Test
    fun `empty cache is empty`() {
        assertTrue(cache.locations.value.isEmpty())
        assertTrue(cache.locationsForGroup(group1).isEmpty())
    }

    // endregion

    // region Remove

    @Test
    fun `removeLocation removes only specified member`() {
        cache.update(group1, alice, makePayload(1.0, 1.0))
        cache.update(group1, bob, makePayload(2.0, 2.0))
        cache.removeLocation(group1, alice)
        assertEquals(1, cache.locations.value.size)
        assertNull(cache.locations.value["$group1:$alice"])
        assertNotNull(cache.locations.value["$group1:$bob"])
    }

    @Test
    fun `removeLocation on absent key is a no-op`() {
        cache.update(group1, alice, makePayload(1.0, 1.0))
        cache.removeLocation(group1, bob) // bob not in cache
        assertEquals(1, cache.locations.value.size)
    }

    @Test
    fun `clearGroup removes only that group`() {
        cache.update(group1, alice, makePayload(1.0, 1.0))
        cache.update(group2, bob, makePayload(2.0, 2.0))
        cache.clearGroup(group1)
        assertTrue(cache.locationsForGroup(group1).isEmpty())
        assertEquals(1, cache.locationsForGroup(group2).size)
    }

    @Test
    fun `clear removes everything`() {
        cache.update(group1, alice, makePayload(1.0, 1.0))
        cache.update(group2, bob, makePayload(2.0, 2.0))
        cache.clear()
        assertTrue(cache.locations.value.isEmpty())
    }

    // endregion

    // region Helpers

    private fun makePayload(lat: Double, lon: Double) = LocationPayload(
        lat = lat,
        lon = lon,
        alt = 0.0,
        acc = 10.0,
        ts = System.currentTimeMillis() / 1000
    )

    // endregion
}
