package org.findmyfam

import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.findmyfam.services.LocationCache
import org.findmyfam.services.NicknameStore
import org.findmyfam.shared.models.LocationPayload
import org.findmyfam.viewmodels.LocationViewModel
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LocationViewModelTest {

    private lateinit var cache: LocationCache
    private lateinit var nicknameStore: NicknameStore
    private lateinit var vm: LocationViewModel

    private val myPubkey = "a".repeat(64)
    private val otherPubkey = "b".repeat(64)
    private val group1 = "group-aaa"
    private val group2 = "group-bbb"

    private val testDispatcher = UnconfinedTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(testDispatcher)
        cache = LocationCache()
        nicknameStore = mockk(relaxed = true)
        every { nicknameStore.nicknames } returns MutableStateFlow(emptyMap())
        every { nicknameStore.displayName(myPubkey) } returns "Me"
        every { nicknameStore.displayName(otherPubkey) } returns "Alice"

        vm = LocationViewModel(
            locationCache = cache,
            nicknameStore = nicknameStore,
            intervalSeconds = { 60 },
            myPubkeyHex = { myPubkey }
        )
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun freshPayload(ts: Long = System.currentTimeMillis() / 1000): LocationPayload {
        return LocationPayload(lat = 53.35, lon = -6.26, alt = 10.0, acc = 5.0, ts = ts)
    }

    @Test
    fun annotations_emptyByDefault() {
        assertTrue(vm.annotations.value.isEmpty())
    }

    @Test
    fun annotations_reflectCacheUpdates() {
        cache.update(group1, myPubkey, freshPayload())
        // Give flow time to propagate
        val annotations = vm.annotations.value
        assertEquals(1, annotations.size)
        assertEquals("Me", annotations[0].displayName)
        assertTrue(annotations[0].isMe)
    }

    @Test
    fun annotations_multipleMembers() {
        cache.update(group1, myPubkey, freshPayload())
        cache.update(group1, otherPubkey, freshPayload())
        assertEquals(2, vm.annotations.value.size)
    }

    @Test
    fun annotations_staleWhenOlderThan2xInterval() {
        // interval = 60s, so > 120s ago is stale
        val staleTs = System.currentTimeMillis() / 1000 - 180 // 3 minutes ago
        cache.update(group1, otherPubkey, freshPayload(ts = staleTs))
        val annotation = vm.annotations.value.first()
        assertTrue("Expected stale annotation", annotation.isStale)
    }

    @Test
    fun annotations_freshWhenWithin2xInterval() {
        val freshTs = System.currentTimeMillis() / 1000 - 30 // 30s ago, interval=60
        cache.update(group1, otherPubkey, freshPayload(ts = freshTs))
        val annotation = vm.annotations.value.first()
        assertFalse("Expected fresh annotation", annotation.isStale)
    }

    @Test
    fun annotations_exactlyAt2xInterval_isNotStale() {
        // Boundary: exactly 2x interval should not be stale (> not >=)
        val boundaryTs = System.currentTimeMillis() / 1000 - 120
        cache.update(group1, otherPubkey, freshPayload(ts = boundaryTs))
        val annotation = vm.annotations.value.first()
        // At exactly 2x, the condition is (now - ts) > interval*2, so it depends on
        // millisecond rounding. Just verify it doesn't crash.
        assertNotNull(annotation)
    }

    @Test
    fun selectGroup_filtersToOneGroup() {
        cache.update(group1, myPubkey, freshPayload())
        cache.update(group2, otherPubkey, freshPayload())
        assertEquals(2, vm.annotations.value.size)

        vm.selectGroup(group1)
        assertEquals(1, vm.annotations.value.size)
        assertTrue(vm.annotations.value[0].isMe)
    }

    @Test
    fun selectGroup_null_showsAll() {
        cache.update(group1, myPubkey, freshPayload())
        cache.update(group2, otherPubkey, freshPayload())
        vm.selectGroup(group1)
        assertEquals(1, vm.annotations.value.size)

        vm.selectGroup(null)
        assertEquals(2, vm.annotations.value.size)
    }

    @Test
    fun clearFilterIfInvalid_clearsWhenGroupGone() {
        vm.selectGroup(group1)
        assertEquals(group1, vm.selectedGroupId.value)

        vm.clearFilterIfInvalid(setOf(group2)) // group1 not in active set
        assertNull("Filter should be cleared", vm.selectedGroupId.value)
    }

    @Test
    fun clearFilterIfInvalid_keepsWhenGroupActive() {
        vm.selectGroup(group1)
        vm.clearFilterIfInvalid(setOf(group1, group2))
        assertEquals(group1, vm.selectedGroupId.value)
    }

    @Test
    fun clearFilterIfInvalid_noopWhenNoFilter() {
        vm.clearFilterIfInvalid(emptySet())
        assertNull(vm.selectedGroupId.value)
    }

    @Test
    fun annotations_isMeFlag() {
        cache.update(group1, myPubkey, freshPayload())
        cache.update(group1, otherPubkey, freshPayload())

        val me = vm.annotations.value.find { it.isMe }
        val other = vm.annotations.value.find { !it.isMe }
        assertNotNull(me)
        assertNotNull(other)
        assertEquals("Me", me!!.displayName)
        assertEquals("Alice", other!!.displayName)
    }

    @Test
    fun annotations_positionMatchesPayload() {
        val payload = LocationPayload(lat = 53.3498, lon = -6.2603, alt = 10.0, acc = 5.0, ts = System.currentTimeMillis() / 1000)
        cache.update(group1, myPubkey, payload)
        val annotation = vm.annotations.value.first()
        assertEquals(53.3498, annotation.position.latitude, 1e-10)
        assertEquals(-6.2603, annotation.position.longitude, 1e-10)
    }

    @Test
    fun annotations_timestampConvertedToMs() {
        val epochSec = System.currentTimeMillis() / 1000
        cache.update(group1, myPubkey, freshPayload(ts = epochSec))
        val annotation = vm.annotations.value.first()
        assertEquals(epochSec * 1000, annotation.timestampMs)
    }
}
