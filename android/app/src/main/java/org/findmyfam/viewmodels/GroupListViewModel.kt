package org.findmyfam.viewmodels

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import build.marmot.mdk.Group
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.findmyfam.models.AppSettings
import org.findmyfam.models.InviteCode
import org.findmyfam.models.PendingInvite
import org.findmyfam.services.*
import timber.log.Timber
import javax.inject.Inject

/**
 * Drives the group list screen -- observes MarmotService groups,
 * exposes GroupListItem list, create/join/leave actions.
 */
@HiltViewModel
class GroupListViewModel @Inject constructor(
    private val marmotService: MarmotService,
    private val mlsService: MLSService,
    private val settings: AppSettings,
    private val pendingInviteStore: PendingInviteStore,
    private val pendingLeaveStore: PendingLeaveStore
) : ViewModel() {

    // --- Item model ---

    data class GroupListItem(
        val id: String,          // mlsGroupId
        val name: String,
        val memberCount: Int,
        val lastActivity: Long?, // epoch seconds
        val isActive: Boolean
    )

    // --- Published state ---

    private val _groups = MutableStateFlow<List<GroupListItem>>(emptyList())
    val groups: StateFlow<List<GroupListItem>> = _groups.asStateFlow()

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    val pendingInvites: StateFlow<List<PendingInvite>> = pendingInviteStore.pendingInvites
    val pendingLeaves: StateFlow<Set<String>> = pendingLeaveStore.pendingLeaves
    val unhealthyGroupIds: StateFlow<Set<String>> = marmotService.healthTracker.unhealthyGroupIds

    init {
        // Observe MarmotService groups and rebuild list items
        viewModelScope.launch {
            marmotService.groups.collect { mdkGroups ->
                refreshItems(mdkGroups)
            }
        }
    }

    // --- Refresh ---

    fun refresh() {
        viewModelScope.launch {
            _isRefreshing.value = true
            try {
                marmotService.refreshGroups()
            } finally {
                _isRefreshing.value = false
            }
        }
    }

    private suspend fun refreshItems(mdkGroups: List<Group>) {
        val items = mdkGroups.map { group ->
            val memberCount = try {
                mlsService.getMembers(group.mlsGroupId).size
            } catch (_: Exception) { 0 }
            GroupListItem(
                id = group.mlsGroupId,
                name = group.name.ifEmpty { "Unnamed Group" },
                memberCount = memberCount,
                lastActivity = group.lastMessageAt?.toLong(),  // ULong? -> Long?
                isActive = group.state == "active"
            )
        }.filter { !pendingLeaveStore.contains(it.id) }

        _groups.value = items

        // Clean up pending leaves for groups that no longer exist
        val activeIds = mdkGroups.map { it.mlsGroupId }.toSet()
        pendingLeaveStore.removeResolved(activeIds)
    }

    // --- Actions ---

    fun createGroup(name: String, onCreated: (String) -> Unit = {}) {
        viewModelScope.launch {
            try {
                _error.value = null
                val relays = marmotService.activeRelayUrls
                val groupId = marmotService.createGroup(name = name, relays = relays)

                // Broadcast our display name so other members see it immediately
                val dn = settings.displayName
                if (dn.isNotEmpty()) {
                    try {
                        marmotService.sendNicknameUpdate(name = dn, groupId = groupId)
                    } catch (_: Exception) { }
                }

                onCreated(groupId)
            } catch (e: Exception) {
                _error.value = e.message
                Timber.e("Failed to create group: $e")
            }
        }
    }

    fun joinGroup(inviteCode: String) {
        viewModelScope.launch {
            try {
                _error.value = null
                val invite = InviteCode.decode(inviteCode)

                marmotService.acceptInvite(inviteCode)

                // If the user previously left this group, clear the stale pending leave
                pendingLeaveStore.remove(invite.groupId)

                // Record as pending -- will be auto-removed when Welcome arrives
                pendingInviteStore.add(
                    PendingInvite(
                        groupHint = invite.groupId,
                        inviterNpub = invite.inviterNpub
                    )
                )
            } catch (e: Exception) {
                _error.value = e.message
                Timber.e("Failed to join group: $e")
            }
        }
    }

    fun requestLeaveGroup(groupId: String) {
        viewModelScope.launch {
            try {
                marmotService.sendLeaveRequest(groupId = groupId)
                pendingLeaveStore.add(groupId)
            } catch (e: Exception) {
                Timber.e("Failed to request leave for group $groupId: $e")
            }
        }
    }

    fun fetchMissedWelcomes() {
        viewModelScope.launch {
            marmotService.fetchMissedGiftWraps()
        }
    }
}
