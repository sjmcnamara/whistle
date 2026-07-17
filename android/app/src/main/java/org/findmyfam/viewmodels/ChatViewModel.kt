package org.findmyfam.viewmodels

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.findmyfam.shared.MarmotKind
import org.findmyfam.shared.models.ChatPayload
import org.findmyfam.services.ChatMessageCache
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
    private val myPubkeyHex: String,
    private val messageCache: ChatMessageCache
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

    // Soft-resync (catch-up) state for the decryption banner.
    private val _isResyncing = MutableStateFlow(false)
    val isResyncing: StateFlow<Boolean> = _isResyncing.asStateFlow()

    // Set after a resync attempt that ran but did not clear the failures —
    // signals the UI to point the user at the admin re-invite (hard) path.
    private val _resyncDidNotResolve = MutableStateFlow(false)
    val resyncDidNotResolve: StateFlow<Boolean> = _resyncDidNotResolve.asStateFlow()

    // --- Pagination ---

    private val pageSize: UInt = 50u
    // Offset into the RAW message store (all inner kinds — chat, location,
    // nickname), NOT the count of displayed chat bubbles. Location updates
    // dominate the store, so tracking this in displayed-chat units would make
    // paging overlap itself and stall.
    private var currentOffset: UInt = 0u
    // Safety cap on raw pages scanned in a single loadMore when a chat-sparse
    // history is mostly location updates (1000 raw messages / call).
    private val maxPagesPerLoadMore = 20
    private var _hasMore = true
    val hasMore: Boolean get() = _hasMore

    private val _isLoadingMore = MutableStateFlow(false)
    val isLoadingMore: StateFlow<Boolean> = _isLoadingMore.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    init {
        // Seed synchronously from the cache so re-entering a chat renders the
        // last-known thread immediately instead of flashing empty while MDK
        // reloads. loadMessages() (from the screen's LaunchedEffect) then merges
        // in anything new.
        messageCache.thread(groupId)?.let { cached ->
            _messages.value = cached.messages
            currentOffset = cached.offset
            _hasMore = cached.hasMore
        }

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

    // --- Resync ---

    /**
     * Soft resync triggered from the decryption banner: re-fetch and
     * re-process this group's recent commits so a missed epoch advance can be
     * applied. On success the health tracker clears the banner automatically;
     * on failure we flag the UI to suggest the admin re-invite path.
     */
    fun resync() {
        if (_isResyncing.value) return
        scope.launch {
            _isResyncing.value = true
            _resyncDidNotResolve.value = false
            val recovered = marmot.catchUpGroup(groupId)
            if (recovered) {
                loadMessages()
            } else {
                _resyncDidNotResolve.value = true
            }
            _isResyncing.value = false
        }
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
            // MDK returns newest-first; reverse so oldest is at the top.
            val recent = mdkMessages.mapNotNull { mapMessage(it) }.reversed()
            val recentRawCount = mdkMessages.size.toUInt()

            if (_messages.value.isEmpty()) {
                // Cold load: the recent page is the whole thread we know about.
                _messages.value = recent
                // Advance by the RAW page size consumed, not the mapped chat
                // count — the offset indexes the raw store (see currentOffset).
                currentOffset = recentRawCount
                _hasMore = mdkMessages.size == pageSize.toInt()
            } else {
                // A thread is already showing (seeded from cache, or the user
                // paged back). Merge the recent page in — picking up new/edited
                // bubbles — without dropping older pages already loaded, and
                // leave hasMore (the "load earlier" affordance) untouched since a
                // newest-end refresh says nothing about the start of history.
                _messages.value = merge(_messages.value, recent)
                if (recentRawCount > currentOffset) currentOffset = recentRawCount
            }
            _error.value = null
            persist()
        } catch (e: Exception) {
            _error.value = e.message
            Timber.e("Failed to load messages for group $groupId: $e")
        }
    }

    /**
     * Union two bubble lists by id (incoming wins, for fresh names/text) and
     * sort into chat order (oldest first), tie-breaking on id for stability.
     */
    private fun merge(
        existing: List<ChatMessageItem>,
        incoming: List<ChatMessageItem>
    ): List<ChatMessageItem> {
        val byId = LinkedHashMap<String, ChatMessageItem>()
        for (m in existing) byId[m.id] = m
        for (m in incoming) byId[m.id] = m
        return byId.values.sortedWith(compareBy({ it.timestamp }, { it.id }))
    }

    /**
     * Write the current thread state back to the shared cache so the next visit
     * to this group renders instantly.
     */
    private fun persist() {
        messageCache.store(
            groupId = groupId,
            messages = _messages.value,
            offset = currentOffset,
            hasMore = _hasMore
        )
    }

    /**
     * Load older messages and prepend them. Because location updates dominate
     * the raw store, a single raw page can contain zero chat messages — so this
     * keeps paging (advancing the raw offset) until it gathers at least one chat
     * bubble or reaches the start of history, up to a bounded scan.
     */
    suspend fun loadMore() {
        if (!_hasMore || _isLoadingMore.value) return
        _isLoadingMore.value = true
        try {
            val collected = mutableListOf<ChatMessageItem>()
            var pages = 0
            while (_hasMore && collected.isEmpty() && pages < maxPagesPerLoadMore) {
                pages++
                val mdkMessages = mls.getMessages(
                    mlsGroupId = groupId,
                    limit = pageSize,
                    offset = currentOffset,
                    sortOrder = "created_at_first"
                )
                // Advance by the RAW count so successive pages don't overlap.
                currentOffset += mdkMessages.size.toUInt()
                _hasMore = mdkMessages.size == pageSize.toInt()
                // Older page → its bubbles belong above anything gathered so far.
                collected.addAll(0, mdkMessages.mapNotNull { mapMessage(it) }.reversed())
            }
            // Dedupe against what's already shown (guards any overlap) and prepend.
            val existing = _messages.value.map { it.id }.toSet()
            val fresh = collected.filter { it.id !in existing }
            if (fresh.isNotEmpty()) {
                _messages.value = fresh + _messages.value
            }
            persist()
        } catch (e: Exception) {
            Timber.e("Failed to load more messages: $e")
        } finally {
            _isLoadingMore.value = false
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
                    kind = MarmotKind.CHAT
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
        persist()
    }
}
