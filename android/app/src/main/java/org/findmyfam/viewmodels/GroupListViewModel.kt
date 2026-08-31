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
import org.findmyfam.shared.models.InviteCode
import org.findmyfam.shared.models.PendingInvite
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
    private val pendingLeaveStore: PendingLeaveStore,
    private val pendingWelcomeStore: PendingWelcomeStore
) : ViewModel() {

    // --- Item model ---

    data class GroupListItem(
        val id: String,          // mlsGroupId
        val name: String,
        val memberCount: Int,
        val lastActivity: Long?, // epoch seconds
        val isActive: Boolean,
        val hasUnread: Boolean = false
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
    val pendingWelcomes: StateFlow<List<PendingWelcomeItem>> = pendingWelcomeStore.pendingWelcomes

    private val _pendingAdminActionGroupIds = MutableStateFlow<Set<String>>(emptySet())
    val pendingAdminActionGroupIds: StateFlow<Set<String>> = _pendingAdminActionGroupIds.asStateFlow()

    /** Dismiss a stale pending invite that will never be accepted. */
    fun cancelPendingInvite(groupHint: String) {
        pendingInviteStore.remove(groupHint)
    }

    /** Accept an unsolicited welcome after user approval. */
    fun approvePendingWelcome(mlsGroupId: String) {
        viewModelScope.launch {
            try {
                marmotService.approvePendingWelcome(mlsGroupId)
            } catch (e: Exception) {
                _error.value = e.message
                Timber.e("Failed to approve welcome for group $mlsGroupId: $e")
            }
        }
    }

    /** Decline an unsolicited welcome. */
    fun declinePendingWelcome(mlsGroupId: String) {
        viewModelScope.launch {
            try {
                marmotService.declinePendingWelcome(mlsGroupId)
            } catch (e: Exception) {
                _error.value = e.message
                Timber.e("Failed to decline welcome for group $mlsGroupId: $e")
            }
        }
    }

    val unhealthyGroupIds: StateFlow<Set<String>> = marmotService.healthTracker.unhealthyGroupIds

    init {
        // Observe MarmotService groups and rebuild list items
        viewModelScope.launch {
            marmotService.groups.collect { mdkGroups ->
                refreshItems(mdkGroups)
            }
        }
        // A pendingWelcomes emission alone doesn't recompute _groups -- its
        // pendingWelcomeIds filter only runs inside refreshItems. Without this, a
        // group added to pendingWelcomeStore (e.g. by a resync re-add) keeps
        // showing its stale prior entry -- inactive row AND a new "Accept" row for
        // the same group -- until an unrelated marmotService.groups emission
        // happens to rerun the filter.
        viewModelScope.launch {
            pendingWelcomeStore.pendingWelcomes.collect {
                refreshItems(marmotService.groups.value)
            }
        }
        // When a new chat message arrives, persist the timestamp and mark unread immediately.
        // Persisting here means refreshItems can use a chat-only timestamp rather than
        // MDK's lastMessageAt, which advances for location/nickname events too.
        viewModelScope.launch {
            marmotService.lastChatMessageGroupId.collect { change ->
                val groupId = change?.first
                if (groupId != null) {
                    settings.recordChatMessage(groupId)
                    _groups.value = _groups.value.map {
                        if (it.id == groupId) it.copy(hasUnread = true) else it
                    }
                }
            }
        }
    }

    /** Mark a group as read — call when the user opens a group chat. */
    fun markAsRead(groupId: String) {
        settings.markGroupAsRead(groupId)
        // Update list immediately to clear bold
        _groups.value = _groups.value.map {
            if (it.id == groupId) it.copy(hasUnread = false) else it
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
        // Fetch member counts first — this is the only async work.
        val memberCounts = mutableMapOf<String, Int>()
        for (group in mdkGroups) {
            memberCounts[group.mlsGroupId] = try {
                mlsService.getMembers(group.mlsGroupId).size
            } catch (_: Exception) { 0 }
        }
        // Read timestamps AFTER all awaits so any markGroupAsRead calls that happened
        // during suspension are reflected — avoids showing already-read groups as unread.
        val items = mdkGroups.map { group ->
            val lastMessageEpoch = group.lastMessageAt?.toLong()
            val lastChatEpoch = settings.getLastChatTimestamp(group.mlsGroupId)
            val lastRead = settings.getLastRead(group.mlsGroupId)
            val hasUnread = lastChatEpoch != null && lastChatEpoch > lastRead
            GroupListItem(
                id = group.mlsGroupId,
                name = group.name.ifEmpty { "Unnamed Group" },
                memberCount = memberCounts[group.mlsGroupId] ?: 0,
                lastActivity = lastMessageEpoch,
                isActive = group.state == "active",
                hasUnread = hasUnread
            )
        }.filter { !pendingLeaveStore.contains(it.id) }

        val pendingWelcomeIds = pendingWelcomeStore.pendingWelcomes.value.map { it.mlsGroupId }.toSet()

        _groups.value = items.filter { it.id !in pendingWelcomeIds }

        // Recompute admin action badges
        _pendingAdminActionGroupIds.value = settings.pendingLeaveRequests
            .filter { it.value.isNotEmpty() }.keys

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
                val invite = InviteCode.fromUri(inviteCode)
                val rawCode = invite.encode()

                marmotService.acceptInvite(rawCode)

                // If the user previously left this group, clear the stale pending leave
                pendingLeaveStore.remove(invite.groupId)

                // Record as pending -- will be auto-removed when Welcome arrives
                pendingInviteStore.add(
                    PendingInvite(
                        groupHint = invite.groupId,
                        inviterNpub = invite.inviterNpub
                    )
                )

                // Poll for the Welcome gift-wrap — the admin may add us at any
                // point in the next 2 minutes. Mirrors iOS JoinGroupView polling.
                pollForWelcome(invite.groupId)
            } catch (e: Exception) {
                _error.value = e.message
                Timber.e("Failed to join group: $e")
            }
        }
    }

    /**
     * Poll fetchMissedGiftWraps every 2s for up to 2 minutes, checking
     * whether the expected group has appeared in the groups list.
     */
    private fun pollForWelcome(expectedGroupId: String) {
        viewModelScope.launch {
            for (i in 0 until 60) {
                kotlinx.coroutines.delay(2000)
                try {
                    marmotService.fetchMissedGiftWraps()
                } catch (_: Exception) { }
                // Check if the group appeared
                if (_groups.value.any { it.id == expectedGroupId }) {
                    Timber.i("Welcome received for group $expectedGroupId after ${(i + 1) * 2}s")
                    return@launch
                }
            }
            Timber.w("Welcome polling timed out for group $expectedGroupId")
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
