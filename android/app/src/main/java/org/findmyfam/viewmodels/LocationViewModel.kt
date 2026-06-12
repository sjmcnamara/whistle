package org.findmyfam.viewmodels

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import org.findmyfam.services.LocationCache
import org.findmyfam.services.NicknameStore

/**
 * Annotation model for map display — one per visible member pin.
 */
data class MemberAnnotation(
    val id: String,
    val position: LatLon,
    val displayName: String,
    val isStale: Boolean,
    val timestampMs: Long,
    val isMe: Boolean,
    /** True when Movement Aware is active and this device is stationary. Own pin only. */
    val isStationary: Boolean = false,
    /**
     * Publisher's own update cadence in seconds (from `LocationPayload.interval`).
     * Null for pre-1.2.1 payloads that omit the field.
     */
    val intervalSeconds: Int? = null,
    /**
     * Estimated wall-clock time (ms) of this member's next publish — own pin
     * only, drives the count-down on the map pin. Null for other members, which
     * count up from `timestampMs` instead. Mirrors iOS `nextUpdateDate`.
     */
    val nextUpdateMs: Long? = null
)

/** Simple lat/lon pair — no Google Maps dependency. */
data class LatLon(val latitude: Double, val longitude: Double)

/**
 * Transforms LocationCache entries into map annotations.
 * Mirrors iOS LocationViewModel.
 */
class LocationViewModel(
    private val locationCache: LocationCache,
    private val nicknameStore: NicknameStore,
    private val intervalSeconds: () -> Int,
    private val myPubkeyHex: () -> String?,
    private val isStationary: () -> Boolean = { false },
    /** Estimated wall-clock ms of the own device's next publish (own pin count-down). */
    private val nextFireMs: () -> Long? = { null }
) {
    private val scope = CoroutineScope(Dispatchers.Main)

    private val _annotations = MutableStateFlow<List<MemberAnnotation>>(emptyList())
    val annotations: StateFlow<List<MemberAnnotation>> = _annotations.asStateFlow()

    private val _selectedGroupId = MutableStateFlow<String?>(null)
    val selectedGroupId: StateFlow<String?> = _selectedGroupId.asStateFlow()

    init {
        scope.launch {
            combine(
                locationCache.locations,
                nicknameStore.nicknames,
                _selectedGroupId
            ) { _, _, _ -> Unit }
                .collect { refresh() }
        }
    }

    fun selectGroup(groupId: String?) {
        _selectedGroupId.value = groupId
    }

    /** Clear the filter if the selected group is no longer in the active set. */
    fun clearFilterIfInvalid(activeGroupIds: Set<String>) {
        val current = _selectedGroupId.value ?: return
        if (current !in activeGroupIds) {
            _selectedGroupId.value = null
        }
    }

    fun refresh() {
        val interval = intervalSeconds()
        val locs = locationCache.locations.value
        val groupFilter = _selectedGroupId.value
        val selfKey = myPubkeyHex()

        val filtered = if (groupFilter != null) {
            locs.values.filter { it.groupId == groupFilter }
        } else {
            locs.values.toList()
        }

        val stationary = isStationary()
        val nextFire = nextFireMs()
        val annotations = filtered.map { loc ->
            val name = nicknameStore.displayName(loc.memberPubkeyHex)
            val isMe = selfKey != null && loc.memberPubkeyHex == selfKey
            MemberAnnotation(
                id = loc.id,
                position = LatLon(loc.payload.lat, loc.payload.lon),
                displayName = name,
                isStale = loc.isStale(interval),
                // Local-clock anchor; payload.ts is the publisher's stamp, which can drift cross-device.
                timestampMs = loc.receivedAt * 1000,
                isMe = isMe,
                isStationary = isMe && stationary,
                intervalSeconds = loc.payload.interval,
                nextUpdateMs = if (isMe) nextFire else null
            )
        }

        _annotations.value = annotations
    }
}
