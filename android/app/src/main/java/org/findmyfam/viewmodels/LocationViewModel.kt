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
    val isMe: Boolean
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
    private val myPubkeyHex: () -> String?
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

    private fun refresh() {
        val interval = intervalSeconds()
        val locs = locationCache.locations.value
        val groupFilter = _selectedGroupId.value
        val selfKey = myPubkeyHex()

        val filtered = if (groupFilter != null) {
            locs.values.filter { it.groupId == groupFilter }
        } else {
            locs.values.toList()
        }

        val now = System.currentTimeMillis()
        val annotations = filtered.map { loc ->
            val name = nicknameStore.displayName(loc.memberPubkeyHex)
            val isMe = selfKey != null && loc.memberPubkeyHex == selfKey
            val isStale = (now - loc.payload.ts * 1000) > interval * 1000L * 2
            MemberAnnotation(
                id = loc.id,
                position = LatLon(loc.payload.lat, loc.payload.lon),
                displayName = name,
                isStale = isStale,
                timestampMs = loc.payload.ts * 1000,
                isMe = isMe
            )
        }

        _annotations.value = annotations
    }
}
