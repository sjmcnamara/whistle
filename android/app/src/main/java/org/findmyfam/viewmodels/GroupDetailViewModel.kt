package org.findmyfam.viewmodels

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.findmyfam.services.*
import rust.nostr.sdk.PublicKey
import timber.log.Timber

/**
 * Drives the group detail / management view -- member list, invite, remove.
 *
 * Not a HiltViewModel -- created per-group with explicit dependencies.
 */
class GroupDetailViewModel(
    val groupId: String,
    private val marmot: MarmotService,
    private val mls: MLSService,
    private val nicknameStore: NicknameStore,
    private val myPubkeyHex: String,
    private val pendingLeaveStore: PendingLeaveStore,
    private val settings: org.findmyfam.models.AppSettings? = null
) {
    // --- Item model ---

    data class MemberItem(
        val id: String,           // pubkeyHex
        val pubkeyHex: String,
        val displayName: String,
        val isAdmin: Boolean,
        val isMe: Boolean
    )

    // --- Published state ---

    private val _groupName = MutableStateFlow("")
    val groupName: StateFlow<String> = _groupName.asStateFlow()

    private val _members = MutableStateFlow<List<MemberItem>>(emptyList())
    val members: StateFlow<List<MemberItem>> = _members.asStateFlow()

    private val _inviteCode = MutableStateFlow<String?>(null)
    val inviteCode: StateFlow<String?> = _inviteCode.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _isAddingMember = MutableStateFlow(false)
    val isAddingMember: StateFlow<Boolean> = _isAddingMember.asStateFlow()

    private val _didAddMember = MutableStateFlow(false)
    val didAddMember: StateFlow<Boolean> = _didAddMember.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _addMemberNpub = MutableStateFlow("")
    val addMemberNpub: StateFlow<String> = _addMemberNpub.asStateFlow()

    private val _isLeaving = MutableStateFlow(false)
    val isLeaving: StateFlow<Boolean> = _isLeaving.asStateFlow()

    private val _didRequestLeave = MutableStateFlow(false)
    val didRequestLeave: StateFlow<Boolean> = _didRequestLeave.asStateFlow()

    private val _isRenaming = MutableStateFlow(false)
    val isRenaming: StateFlow<Boolean> = _isRenaming.asStateFlow()

    private val _leaveRequestMembers = MutableStateFlow<Set<String>>(emptySet())
    val leaveRequestMembers: StateFlow<Set<String>> = _leaveRequestMembers.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    init {
        // Re-resolve display names when nicknames change
        scope.launch {
            nicknameStore.nicknames.collect {
                refreshDisplayNames()
            }
        }
    }

    fun updateAddMemberNpub(value: String) {
        _addMemberNpub.value = value
    }

    // --- Load ---

    fun load() {
        scope.launch {
            _isLoading.value = true
            try {
                // Load group metadata
                val group = mls.getGroup(groupId)
                if (group != null) {
                    _groupName.value = group.name.ifEmpty { "Unnamed Group" }
                }

                // Load member pubkeys and admin list
                val memberPubkeys = mls.getMembers(groupId).distinct()
                val adminPubkeys = (group?.adminPubkeys ?: emptyList()).toSet()

                _members.value = memberPubkeys.map { pubkey ->
                    MemberItem(
                        id = pubkey,
                        pubkeyHex = pubkey,
                        displayName = nicknameStore.displayName(pubkey),
                        isAdmin = pubkey in adminPubkeys,
                        isMe = pubkey == myPubkeyHex
                    )
                }.sortedWith(compareByDescending<MemberItem> { it.isMe }
                    .thenByDescending { it.isAdmin }
                    .thenBy { it.displayName })

                // Populate leave request members from stored settings
                _leaveRequestMembers.value = settings?.pendingLeaveRequests?.get(groupId) ?: emptySet()

                _error.value = null
            } catch (e: Exception) {
                _error.value = e.message
                Timber.e("Failed to load group detail for $groupId: $e")
            } finally {
                _isLoading.value = false
            }
        }
    }

    // --- Invite ---

    fun generateInvite() {
        try {
            val relays = marmot.activeRelayUrls
            val relay = relays.firstOrNull() ?: run {
                _error.value = "No connected relays"
                return
            }
            _inviteCode.value = marmot.generateInviteCode(groupId = groupId, relayUrl = relay)
            _error.value = null
        } catch (e: Exception) {
            _error.value = e.message
            Timber.e("Failed to generate invite: $e")
        }
    }

    // --- Add member ---

    fun addMember() {
        val input = _addMemberNpub.value.trim()
        if (input.isEmpty()) return

        scope.launch {
            _isAddingMember.value = true
            try {
                // Resolve npub -> hex if needed
                val pubkeyHex: String = if (input.startsWith("npub")) {
                    val pk = PublicKey.parse(publicKey = input)
                    pk.toHex()
                } else {
                    input
                }

                marmot.addMember(pubkeyHex = pubkeyHex, groupId = groupId)
                _addMemberNpub.value = ""
                _error.value = null

                // Reload member list
                load()
                Timber.i("Added member ${pubkeyHex.take(8)} to group $groupId")

                _didAddMember.value = true
            } catch (e: Exception) {
                _error.value = e.message
                Timber.e("Failed to add member: $e")
            } finally {
                _isAddingMember.value = false
            }
        }
    }

    // --- Remove member ---

    fun removeMember(pubkeyHex: String) {
        scope.launch {
            try {
                val result = mls.removeMembers(
                    mlsGroupId = groupId,
                    memberPublicKeys = listOf(pubkeyHex)
                )
                mls.mergePendingCommit(mlsGroupId = groupId)

                // Publish the evolution event
                val evolutionEventJson = result.evolutionEventJson
                marmot.publishGroupEvent(evolutionEventJson)

                // Clear the leave request since it's processed
                settings?.removePendingLeaveRequest(groupId, pubkeyHex)
                _leaveRequestMembers.value = _leaveRequestMembers.value - pubkeyHex

                load()
                Timber.i("Removed member ${pubkeyHex.take(8)} from group $groupId")
            } catch (e: Exception) {
                _error.value = e.message
                Timber.e("Failed to remove member: $e")
            }
        }
    }

    /**
     * Whether the current user is an admin of this group.
     */
    val isAdmin: Boolean
        get() = _members.value.firstOrNull { it.isMe }?.isAdmin ?: false

    // --- Leave group ---

    fun requestLeave() {
        scope.launch {
            _isLeaving.value = true
            try {
                marmot.sendLeaveRequest(groupId = groupId)
                pendingLeaveStore.add(groupId)
                _didRequestLeave.value = true
                _error.value = null
            } catch (e: Exception) {
                _error.value = e.message
                Timber.e("Failed to send leave request: $e")
            } finally {
                _isLeaving.value = false
            }
        }
    }

    // --- Rename group ---

    fun renameGroup(newName: String) {
        val trimmed = newName.trim()
        if (trimmed.isEmpty() || trimmed == _groupName.value) return

        scope.launch {
            _isRenaming.value = true
            try {
                marmot.renameGroup(groupId = groupId, newName = trimmed)
                _groupName.value = trimmed
                _error.value = null
            } catch (e: Exception) {
                _error.value = e.message
                Timber.e("Failed to rename group: $e")
            } finally {
                _isRenaming.value = false
            }
        }
    }

    // --- Nickname refresh ---

    private fun refreshDisplayNames() {
        _members.value = _members.value.map { m ->
            m.copy(displayName = nicknameStore.displayName(m.pubkeyHex))
        }
    }
}
