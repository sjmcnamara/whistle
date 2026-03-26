package org.findmyfam.viewmodels

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.findmyfam.models.ChatPayload
import org.findmyfam.services.MLSService
import org.findmyfam.services.MarmotService
import org.findmyfam.services.NicknameStore
import org.findmyfam.services.innerKind
import org.findmyfam.services.plaintextContent
import org.json.JSONObject
import build.marmot.mdk.Message
import timber.log.Timber

/**
 * Drives the single-group chat thread -- loads messages from MDK,
 * observes incoming message notifications, and sends new messages.
 *
 * Not a HiltViewModel -- created per-group with explicit dependencies.
 */
class ChatViewModel(
    val groupId: String,
    private val marmot: MarmotService,
    private val mls: MLSService,
    private val nicknameStore: NicknameStore,
    private val myPubkeyHex: String
) {
    // --- Item model ---

    data class ChatMessageItem(
        val id: String,
        val senderPubkeyHex: String,
        val senderDisplayName: String,
        val text: String,
        val timestamp: Long, // epoch seconds
        val isMe: Boolean
    )

    // --- Published state ---

    private val _messages = MutableStateFlow<List<ChatMessageItem>>(emptyList())
    val messages: StateFlow<List<ChatMessageItem>> = _messages.asStateFlow()

    private val _draftText = MutableStateFlow("")
    val draftText: StateFlow<String> = _draftText.asStateFlow()

    private val _isSending = MutableStateFlow(false)
    val isSending: StateFlow<Boolean> = _isSending.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _memberNames = MutableStateFlow("")
    val memberNames: StateFlow<String> = _memberNames.asStateFlow()

    // --- Pagination ---

    private val pageSize: UInt = 50u
    private var currentOffset: UInt = 0u
    private var _hasMore = true
    val hasMore: Boolean get() = _hasMore

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    init {
        // Observe incoming chat messages for this group
        scope.launch {
            marmot.lastChatMessageGroupId.collect { updatedGroupId ->
                if (updatedGroupId == groupId) {
                    loadMessages()
                }
            }
        }

        // Re-resolve display names when nicknames change
        scope.launch {
            nicknameStore.nicknames.collect {
                refreshDisplayNames()
                loadMemberNames()
            }
        }

        // Refresh member names when membership changes
        scope.launch {
            marmot.lastGroupMembershipChangeId.collect { change ->
                if (change?.first == groupId) {
                    loadMemberNames()
                }
            }
        }
    }

    fun updateDraftText(text: String) {
        _draftText.value = text
    }

    // --- Load messages ---

    suspend fun loadMessages() {
        try {
            val mdkMessages = mls.getMessages(
                mlsGroupId = groupId,
                limit = pageSize,
                offset = null,
                sortOrder = "created_at_first"
            )
            _messages.value = mdkMessages.mapNotNull { mapMessage(it) }.reversed()
            currentOffset = _messages.value.size.toUInt()
            _hasMore = mdkMessages.size == pageSize.toInt()
            _error.value = null
        } catch (e: Exception) {
            _error.value = e.message
            Timber.e("Failed to load messages for group $groupId: $e")
        }
    }

    suspend fun loadMore() {
        if (!_hasMore) return
        try {
            val mdkMessages = mls.getMessages(
                mlsGroupId = groupId,
                limit = pageSize,
                offset = currentOffset,
                sortOrder = "created_at_first"
            )
            val newItems = mdkMessages.mapNotNull { mapMessage(it) }.reversed()
            _messages.value = newItems + _messages.value
            currentOffset += newItems.size.toUInt()
            _hasMore = mdkMessages.size == pageSize.toInt()
        } catch (e: Exception) {
            Timber.e("Failed to load more messages: $e")
        }
    }

    suspend fun loadMemberNames() {
        try {
            val pubkeys = mls.getMembers(groupId).distinct()
            val names = pubkeys.map { nicknameStore.displayName(it) }
            _memberNames.value = names.joinToString(", ")
        } catch (e: Exception) {
            _memberNames.value = ""
            Timber.e("Failed to load member names for group $groupId: $e")
        }
    }

    // --- Send ---

    fun sendMessage() {
        val text = _draftText.value.trim()
        if (text.isEmpty()) return

        scope.launch {
            _isSending.value = true
            try {
                val payload = ChatPayload(text = text)
                val json = payload.toJson()
                marmot.sendMessage(
                    content = json,
                    groupId = groupId,
                    kind = MarmotService.MarmotKind.CHAT
                )
                _draftText.value = ""
                loadMessages()
            } catch (e: Exception) {
                _error.value = e.message
                Timber.e("Failed to send message: $e")
            } finally {
                _isSending.value = false
            }
        }
    }

    // --- Mapping ---

    private fun mapMessage(message: Message): ChatMessageItem? {
        val content = message.plaintextContent ?: return null

        // Only map "chat" type messages (skip nickname broadcasts, etc.)
        try {
            val json = JSONObject(content)
            val type = json.optString("type", "chat")
            if (type != "chat") return null
        } catch (_: Exception) {
            // Not JSON -- treat as plain text
        }

        // Try parsing as ChatPayload for rich metadata, fall back to raw text
        val parsed = try {
            val payload = ChatPayload.fromJson(content)
            payload.text to payload.ts
        } catch (_: Exception) {
            content to message.createdAt.toLong()
        }
        val text = parsed.first
        val timestamp = parsed.second

        return ChatMessageItem(
            id = message.id,
            senderPubkeyHex = message.senderPubkey,
            senderDisplayName = nicknameStore.displayName(message.senderPubkey),
            text = text,
            timestamp = timestamp,
            isMe = message.senderPubkey == myPubkeyHex
        )
    }

    /**
     * Re-map display names in-place without reloading from MDK.
     */
    private fun refreshDisplayNames() {
        _messages.value = _messages.value.map { msg ->
            msg.copy(senderDisplayName = nicknameStore.displayName(msg.senderPubkeyHex))
        }
    }
}
