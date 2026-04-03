package org.findmyfam

import org.findmyfam.services.GroupHealthTracker
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class GroupHealthTrackerTest {

    private lateinit var tracker: GroupHealthTracker

    @Before
    fun setUp() {
        tracker = GroupHealthTracker()
    }

    // region Initial state

    @Test
    fun `group is initially healthy`() {
        assertFalse(tracker.isUnhealthy("group-1"))
        assertEquals(0, tracker.failureCount("group-1"))
        assertTrue(tracker.unhealthyGroupIds.value.isEmpty())
    }

    // endregion

    // region Failure counting

    @Test
    fun `failures below threshold do not mark group unhealthy`() {
        repeat(GroupHealthTracker.FAILURE_THRESHOLD - 1) {
            val reached = tracker.recordFailure("group-1")
            assertFalse(reached)
        }
        assertFalse(tracker.isUnhealthy("group-1"))
        assertEquals(GroupHealthTracker.FAILURE_THRESHOLD - 1, tracker.failureCount("group-1"))
    }

    @Test
    fun `failure at threshold marks group unhealthy`() {
        repeat(GroupHealthTracker.FAILURE_THRESHOLD) {
            tracker.recordFailure("group-1")
        }
        assertTrue(tracker.isUnhealthy("group-1"))
        assertTrue("group-1" in tracker.unhealthyGroupIds.value)
    }

    @Test
    fun `recordFailure returns true only at threshold`() {
        repeat(GroupHealthTracker.FAILURE_THRESHOLD - 1) {
            assertFalse(tracker.recordFailure("group-1"))
        }
        assertTrue(tracker.recordFailure("group-1"))
    }

    @Test
    fun `recordFailure returns true for every call beyond threshold`() {
        repeat(GroupHealthTracker.FAILURE_THRESHOLD) { tracker.recordFailure("group-1") }
        // Beyond threshold — still returns true
        assertTrue(tracker.recordFailure("group-1"))
        assertEquals(GroupHealthTracker.FAILURE_THRESHOLD + 1, tracker.failureCount("group-1"))
    }

    // endregion

    // region Recovery

    @Test
    fun `success resets failure count`() {
        tracker.recordFailure("group-1")
        tracker.recordFailure("group-1")
        assertEquals(2, tracker.failureCount("group-1"))

        tracker.recordSuccess("group-1")
        assertEquals(0, tracker.failureCount("group-1"))
    }

    @Test
    fun `success removes group from unhealthy set`() {
        repeat(GroupHealthTracker.FAILURE_THRESHOLD) { tracker.recordFailure("group-1") }
        assertTrue(tracker.isUnhealthy("group-1"))

        tracker.recordSuccess("group-1")
        assertFalse(tracker.isUnhealthy("group-1"))
        assertFalse("group-1" in tracker.unhealthyGroupIds.value)
    }

    @Test
    fun `success on healthy group is a no-op`() {
        tracker.recordSuccess("group-1") // never failed
        assertFalse(tracker.isUnhealthy("group-1"))
        assertEquals(0, tracker.failureCount("group-1"))
    }

    @Test
    fun `can fail again after recovery`() {
        repeat(GroupHealthTracker.FAILURE_THRESHOLD) { tracker.recordFailure("group-1") }
        tracker.recordSuccess("group-1")
        assertFalse(tracker.isUnhealthy("group-1"))

        repeat(GroupHealthTracker.FAILURE_THRESHOLD) { tracker.recordFailure("group-1") }
        assertTrue(tracker.isUnhealthy("group-1"))
    }

    // endregion

    // region Multi-group isolation

    @Test
    fun `multiple groups are independent`() {
        repeat(GroupHealthTracker.FAILURE_THRESHOLD) { tracker.recordFailure("group-1") }
        tracker.recordFailure("group-2")

        assertTrue(tracker.isUnhealthy("group-1"))
        assertFalse(tracker.isUnhealthy("group-2"))
    }

    @Test
    fun `recovery of one group does not affect another`() {
        repeat(GroupHealthTracker.FAILURE_THRESHOLD) { tracker.recordFailure("group-1") }
        tracker.recordFailure("group-2")

        tracker.recordSuccess("group-1")

        assertFalse(tracker.isUnhealthy("group-1"))
        assertEquals(1, tracker.failureCount("group-2"))
    }

    @Test
    fun `unhealthy set contains only unhealthy groups`() {
        repeat(GroupHealthTracker.FAILURE_THRESHOLD) { tracker.recordFailure("group-1") }
        repeat(GroupHealthTracker.FAILURE_THRESHOLD - 1) { tracker.recordFailure("group-2") }

        val unhealthy = tracker.unhealthyGroupIds.value
        assertTrue("group-1" in unhealthy)
        assertFalse("group-2" in unhealthy)
    }

    // endregion
}
