package org.findmyfam.viewmodels

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.findmyfam.models.AppSettings
import org.findmyfam.services.MarmotKitService
import org.findmyfam.services.NicknameStore
import org.findmyfam.services.NoticeCenter
import rust.nostr.sdk.PublicKey
import timber.log.Timber

/**
 * Drives the group detail / management view — member list, invite, remove.
 *
 * Not a HiltViewModel — created per-group with explicit dependencies.
 */
class GroupDetailViewModel(
    val groupId: String,
    val marmot: MarmotKitService,
    private val nicknameStore: NicknameStore,
    private val myPubkeyHex: String,
    private val settings: AppSettings? = null,
    val notices: NoticeCenter
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

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _isAddingMember = MutableStateFlow(false)
    val isAddingMember: StateFlow<Boolean> = _isAddingMember.asStateFlow()

    private val _didAddMember = MutableStateFlow(false)
    val didAddMember: StateFlow<Boolean> = _didAddMember.asStateFlow()

    private val _addMemberNpub = MutableStateFlow("")
    val addMemberNpub: StateFlow<String> = _addMemberNpub.asStateFlow()

    private val _isLeaving = MutableStateFlow(false)
    val isLeaving: StateFlow<Boolean> = _isLeaving.asStateFlow()

    private val _didLeave = MutableStateFlow(false)
    val didLeave: StateFlow<Boolean> = _didLeave.asStateFlow()

    private val _isRenaming = MutableStateFlow(false)
    val isRenaming: StateFlow<Boolean> = _isRenaming.asStateFlow()

    /** Pubkey currently being hard-resynced (remove + re-add), for per-row spinner. */
    private val _resyncingMemberPubkey = MutableStateFlow<String?>(null)
    val resyncingMemberPubkey: StateFlow<String?> = _resyncingMemberPubkey.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    init {
        // Re-resolve display names when nicknames change
        scope.launch {
            nicknameStore.nicknames.collect {
                refreshDisplayNames()
            }
        }
    }

    val isAdmin: Boolean
        get() = _members.value.firstOrNull { it.isMe }?.isAdmin == true

    val diagnosticsGroupId: String
        get() = org.findmyfam.shared.models.DiagnosticsReport.shortHex(groupId)

    fun displayIdentifier(pubkeyHex: String): String {
        return try {
            val npub = PublicKey.parse(pubkeyHex).toBech32()
            "${npub.take(12)}…${npub.takeLast(4)}"
        } catch (_: Exception) {
            "${pubkeyHex.take(8)}…"
        }
    }

    fun fullNpub(pubkeyHex: String): String {
        return try {
            PublicKey.parse(pubkeyHex).toBech32()
        } catch (_: Exception) {
            pubkeyHex
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
                val group = marmot.group(groupId)
                if (group != null) {
                    _groupName.value = group.name.ifEmpty { "Unnamed Group" }
                }

                val memberPubkeys = marmot.members(groupId).distinct()
                val adminPubkeys = (group?.adminPubkeys ?: emptyList()).toSet()

                _members.value = memberPubkeys.map { pubkey ->
                    MemberItem(
                        id = pubkey,
                        pubkeyHex = pubkey,
                        displayName = nicknameStore.displayName(pubkey),
                        isAdmin = pubkey in adminPubkeys,
                        isMe = pubkey == myPubkeyHex
                    )
                }.sortedWith(
                    compareByDescending<MemberItem> { it.isMe }
                        .thenByDescending { it.isAdmin }
                        .thenBy { it.displayName }
                )
            } catch (e: Exception) {
                Timber.e(e, "Failed to load group detail for $groupId")
                notices.report(e, "Couldn't load group details")
            } finally {
                _isLoading.value = false
            }
        }
    }

    // --- Add member ---

    fun addMember() {
        val input = _addMemberNpub.value.trim()
        if (input.isEmpty()) return

        scope.launch {
            _isAddingMember.value = true
            try {
                val pubkeyHex: String = if (input.startsWith("npub")) {
                    runCatching { PublicKey.parse(input).toHex() }.getOrDefault(input)
                } else {
                    input
                }

                marmot.invite(listOf(pubkeyHex), groupId)
                _addMemberNpub.value = ""
                load()
                _didAddMember.value = true
            } catch (e: Exception) {
                Timber.e(e, "Failed to add member: $input")
                notices.report(e, "Couldn't add member") {
                    addMember()
                }
            } finally {
                _isAddingMember.value = false
            }
        }
    }

    // --- Promote member ---

    fun promoteToAdmin(pubkeyHex: String) {
        scope.launch {
            try {
                marmot.promoteToAdmin(pubkeyHex, groupId)
                load()
            } catch (e: Exception) {
                Timber.e(e, "Failed to promote member: $pubkeyHex")
                notices.report(e, "Couldn't make admin") {
                    promoteToAdmin(pubkeyHex)
                }
            }
        }
    }

    // --- Remove member ---

    fun removeMember(pubkeyHex: String) {
        scope.launch {
            try {
                marmot.removeMembers(listOf(pubkeyHex), groupId)
                load()
                Timber.i("Removed member ${pubkeyHex.take(8)} from group $groupId")
            } catch (e: Exception) {
                Timber.e(e, "Failed to remove member: $pubkeyHex")
                notices.report(e, "Couldn't remove member") {
                    removeMember(pubkeyHex)
                }
            }
        }
    }

    // --- Resync member (remove + re-add) ---

    fun resyncMember(pubkeyHex: String) {
        scope.launch {
            _resyncingMemberPubkey.value = pubkeyHex
            try {
                marmot.resyncMember(memberRef = pubkeyHex, groupIdHex = groupId)
                load()
                Timber.i("Resynced member ${pubkeyHex.take(8)} in group $groupId")
            } catch (e: MarmotKitService.ServiceError.AdminNotRestored) {
                // They are already back in the group, so retrying the whole
                // resync would remove and re-add them a second time as a plain
                // member. Retry only the promotion.
                Timber.e(e, "Resynced $pubkeyHex but could not restore admin")
                load()
                notices.report(e, "Couldn't make them an admin again") {
                    promoteToAdmin(pubkeyHex)
                }
            } catch (e: Exception) {
                Timber.e(e, "Failed to resync member: $pubkeyHex")
                notices.report(e, "Couldn't re-invite member") {
                    resyncMember(pubkeyHex)
                }
            } finally {
                _resyncingMemberPubkey.value = null
            }
        }
    }

    // --- Rename group ---

    fun renameGroup(newName: String) {
        val trimmed = newName.trim()
        if (trimmed.isEmpty()) return
        scope.launch {
            _isRenaming.value = true
            try {
                marmot.rename(groupId, trimmed)
                _groupName.value = trimmed
            } catch (e: Exception) {
                Timber.e(e, "Failed to rename group $groupId")
                notices.report(e, "Couldn't rename group") {
                    renameGroup(newName)
                }
            } finally {
                _isRenaming.value = false
            }
        }
    }

    // --- Leave group ---

    fun leaveGroup() {
        scope.launch {
            _isLeaving.value = true
            try {
                marmot.leaveGroup(groupId)
                _didLeave.value = true
            } catch (e: Exception) {
                Timber.e(e, "Failed to leave group $groupId")
                notices.report(e, "Couldn't leave group") {
                    leaveGroup()
                }
            } finally {
                _isLeaving.value = false
            }
        }
    }

    private fun refreshDisplayNames() {
        _members.value = _members.value.map {
            it.copy(displayName = nicknameStore.displayName(it.pubkeyHex))
        }.sortedWith(
            compareByDescending<MemberItem> { it.isMe }
                .thenByDescending { it.isAdmin }
                .thenBy { it.displayName }
        )
    }
}
