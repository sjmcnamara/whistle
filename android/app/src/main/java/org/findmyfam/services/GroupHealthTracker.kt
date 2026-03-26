package org.findmyfam.services

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Tracks consecutive MLS processing failures per group to detect
 * permanently broken epoch state.
 *
 * Not persisted -- resets on app launch (a fresh start should clear
 * transient failures from the previous session).
 */
@Singleton
class GroupHealthTracker @Inject constructor() {

    companion object {
        /** Number of consecutive failures before a group is considered unhealthy. */
        const val FAILURE_THRESHOLD = 5
    }

    /** Groups that have exceeded the failure threshold. */
    private val _unhealthyGroupIds = MutableStateFlow<Set<String>>(emptySet())
    val unhealthyGroupIds: StateFlow<Set<String>> = _unhealthyGroupIds.asStateFlow()

    private val failureCounts = mutableMapOf<String, Int>()

    /**
     * Record a processing failure for a group.
     * @return true if the group has reached the unhealthy threshold.
     */
    fun recordFailure(groupId: String): Boolean {
        val count = (failureCounts[groupId] ?: 0) + 1
        failureCounts[groupId] = count

        if (count >= FAILURE_THRESHOLD) {
            _unhealthyGroupIds.value = _unhealthyGroupIds.value + groupId
            Timber.w("Group $groupId marked unhealthy after $count consecutive failures")
            return true
        }
        return false
    }

    /**
     * Record a successful event processing -- resets the failure count.
     */
    fun recordSuccess(groupId: String) {
        val hadFailures = (failureCounts[groupId] ?: 0) > 0
        failureCounts[groupId] = 0
        if (groupId in _unhealthyGroupIds.value) {
            _unhealthyGroupIds.value = _unhealthyGroupIds.value - groupId
            Timber.i("Group $groupId recovered -- removed from unhealthy set")
        } else if (hadFailures) {
            Timber.d("Group $groupId failure count reset after success")
        }
    }

    /**
     * Check whether a group is currently unhealthy.
     */
    fun isUnhealthy(groupId: String): Boolean {
        return groupId in _unhealthyGroupIds.value
    }

    /**
     * Current failure count for a group (exposed for testing).
     */
    fun failureCount(groupId: String): Int {
        return failureCounts[groupId] ?: 0
    }
}
