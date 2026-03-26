package org.findmyfam.services

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.findmyfam.models.LocationPayload
import org.findmyfam.models.MemberLocation
import javax.inject.Inject
import javax.inject.Singleton

/**
 * In-memory cache of the latest location for each group member.
 *
 * MarmotService writes to this cache when it receives location messages.
 * The map UI observes it to display member pins.
 */
@Singleton
class LocationCache @Inject constructor() {

    /**
     * Latest location per member, keyed by "groupId:pubkeyHex".
     */
    private val _locations = MutableStateFlow<Map<String, MemberLocation>>(emptyMap())
    val locations: StateFlow<Map<String, MemberLocation>> = _locations.asStateFlow()

    /**
     * Update or insert a member's location.
     */
    fun update(groupId: String, memberPubkeyHex: String, payload: LocationPayload) {
        val key = "$groupId:$memberPubkeyHex"
        val location = MemberLocation(
            groupId = groupId,
            memberPubkeyHex = memberPubkeyHex,
            payload = payload
        )
        _locations.value = _locations.value + (key to location)
    }

    /**
     * All locations for a specific group.
     */
    fun locationsForGroup(groupId: String): List<MemberLocation> {
        return _locations.value.values.filter { it.groupId == groupId }
    }

    /**
     * Remove a specific member's location from a group.
     */
    fun removeLocation(groupId: String, memberPubkeyHex: String) {
        val key = "$groupId:$memberPubkeyHex"
        _locations.value = _locations.value - key
    }

    /**
     * Remove all cached locations for a specific group.
     */
    fun clearGroup(groupId: String) {
        _locations.value = _locations.value.filter { it.value.groupId != groupId }
    }

    /**
     * Remove all cached locations.
     */
    fun clear() {
        _locations.value = emptyMap()
    }
}
