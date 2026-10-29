package org.findmyfam.viewmodels

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.findmyfam.models.AppSettings
import org.findmyfam.services.MarmotKitService
import org.findmyfam.services.NoticeCenter
import org.findmyfam.shared.models.WhistleGroup
import timber.log.Timber
import javax.inject.Inject

/**
 * Drives the Groups tab group list — observes [MarmotKitService.groups].
 */
@HiltViewModel
class GroupListViewModel @Inject constructor(
    val marmot: MarmotKitService,
    val notices: NoticeCenter,
    val settings: AppSettings
) : ViewModel() {

    // --- Item model ---

    data class GroupListItem(
        val id: String,          // mlsGroupId
        val name: String,
        val memberCount: Int,
        val lastActivity: Long?, // epoch seconds
        val isActive: Boolean,
        val hasUnread: Boolean = false,
        /**
         * Whether the user has paused their own outbound sharing to this
         * group (see [AppSettings.pausedGroupIds]) — independent of [isActive].
         */
        val isSharingPaused: Boolean = false
    )

    // --- Published state ---

    private val _groups = MutableStateFlow<List<GroupListItem>>(emptyList())
    val groups: StateFlow<List<GroupListItem>> = _groups.asStateFlow()

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    val isAccountReady: StateFlow<Boolean> = marmot.accountIsReady

    init {
        // Observe MarmotKitService groups and rebuild list items
        viewModelScope.launch {
            marmot.groups.collect { whistleGroups ->
                refreshItems(whistleGroups)
            }
        }

        // When a new chat message arrives, persist the timestamp and mark unread immediately.
        viewModelScope.launch {
            marmot.lastChatMessageGroupId.collect { groupId ->
                if (groupId != null) {
                    settings.recordChatMessage(groupId)
                    _groups.value = _groups.value.map {
                        if (it.id == groupId) it.copy(hasUnread = true) else it
                    }
                }
            }
        }

        // Reflect per-group pause toggles immediately
        viewModelScope.launch {
            settings.pausedGroupIdsFlow.collect { paused ->
                _groups.value = _groups.value.map {
                    it.copy(isSharingPaused = it.id in paused)
                }
            }
        }
    }

    /** Mark a group as read — call when the user opens a group chat. */
    fun markAsRead(groupId: String) {
        settings.markGroupAsRead(groupId)
        _groups.value = _groups.value.map {
            if (it.id == groupId) it.copy(hasUnread = false) else it
        }
    }

    // --- Refresh ---

    fun refresh() {
        viewModelScope.launch {
            _isRefreshing.value = true
            try {
                // Catch up first, then re-read: a group we were added to while the app
                // was closed only appears once its Welcome has been processed.
                runCatching { marmot.catchUpAccounts() }
                    .onFailure { Timber.w(it, "Catch-up failed during pull-to-refresh") }
                marmot.refreshGroups()
            } finally {
                _isRefreshing.value = false
            }
        }
    }

    private suspend fun refreshItems(whistleGroups: List<WhistleGroup>) {
        val memberCounts = mutableMapOf<String, Int>()
        for (group in whistleGroups) {
            memberCounts[group.mlsGroupId] = runCatching {
                marmot.members(group.mlsGroupId).size
            }.getOrDefault(0)
        }

        val items = whistleGroups.map { group ->
            val lastMessageEpoch = group.lastMessageAt
            val lastChatEpoch = settings.getLastChatTimestamp(group.mlsGroupId)
            val lastRead = settings.getLastRead(group.mlsGroupId)
            val hasUnread = lastChatEpoch != null && lastChatEpoch > lastRead
            GroupListItem(
                id = group.mlsGroupId,
                name = group.name.ifEmpty { "Unnamed Group" },
                memberCount = memberCounts[group.mlsGroupId] ?: 0,
                lastActivity = lastMessageEpoch,
                isActive = group.isActive,
                hasUnread = hasUnread,
                isSharingPaused = group.mlsGroupId in settings.pausedGroupIds
            )
        }

        _groups.value = items
    }

    // --- Actions ---

    fun createGroup(name: String, onCreated: (String) -> Unit = {}) {
        viewModelScope.launch {
            try {
                val groupId = marmot.createGroup(name = name)

                val dn = settings.displayName
                if (dn.isNotEmpty()) {
                    runCatching {
                        marmot.sendNicknameUpdate(name = dn, groupIdHex = groupId)
                    }
                }

                onCreated(groupId)
            } catch (e: Exception) {
                Timber.e(e, "Failed to create group")
                notices.report(e, "Couldn't create group") {
                    createGroup(name, onCreated)
                }
            }
        }
    }

    fun leaveGroup(groupId: String) {
        viewModelScope.launch {
            try {
                marmot.leaveGroup(groupIdHex = groupId)
            } catch (e: Exception) {
                Timber.e(e, "Failed to leave group $groupId")
                notices.report(e, "Couldn't leave group") {
                    leaveGroup(groupId)
                }
            }
        }
    }
}
