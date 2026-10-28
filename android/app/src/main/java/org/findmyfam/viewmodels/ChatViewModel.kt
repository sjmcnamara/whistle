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
import org.findmyfam.shared.models.WhistleMessage
import org.findmyfam.services.ChatMessageCache
import org.findmyfam.services.MarmotKitService
import org.findmyfam.services.NicknameStore
import org.findmyfam.services.NoticeCenter
import timber.log.Timber

/**
 * Drives the single-group chat thread -- loads messages from MDK,
 * observes incoming message notifications, and sends new messages.
 *
 * Not a HiltViewModel -- created per-group with explicit dependencies.
 */
class ChatViewModel(
    val groupId: String,
    private val marmot: MarmotKitService,
    private val nicknameStore: NicknameStore,
    private val myPubkeyHex: String,
    private val messageCache: ChatMessageCache,
    private val notices: NoticeCenter
) {
    // --- Item model ---

    data class ChatMessageItem(
        val id: String,
        val senderPubkeyHex: String,
        val senderDisplayName: String,
        val text: String,
        val timestamp: Long, // epoch seconds
        val isMe: Boolean,
        /** MLS epoch, for ordering — see [inChatOrder]. */
        val sourceEpoch: Long? = null,
        /**
         * A membership or rename event rather than something someone typed.
         * Rendered as a centred line, not a bubble.
         */
        val isSystemEvent: Boolean = false
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
    // The oldest RAW message loaded so far, used as the paging cursor. It is a
    // raw message rather than a displayed bubble: location updates dominate
    // the store, and a cursor taken from the bubbles alone would skip every
    // raw row between them. Not cached — a stale cursor is worse than none, so
    // a cache-seeded thread takes a fresh one on its first loadMessages().
    private var oldestLoaded: WhistleMessage? = null
    // Safety cap on raw pages scanned in a single loadMore when a chat-sparse
    // history is mostly location updates.
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
            _hasMore = cached.hasMore
        }

        // Observe incoming chat messages for this group
        scope.launch {
            marmot.lastChatMessageGroupId.collect { changedGroupId ->
                if (changedGroupId == groupId) {
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
     * Soft resync triggered from the decryption banner. v1 re-fetched this one
     * group's commits; v2 has no per-group equivalent and does not need one —
     * `catchUpAccounts` drains everything outstanding, and MarmotKit reports an
     * unrecoverable group as a typed error rather than leaving the caller to
     * infer it from repeated failures.
     */
    fun resync() {
        if (_isResyncing.value) return
        scope.launch {
            _isResyncing.value = true
            _resyncDidNotResolve.value = false
            try {
                marmot.catchUpAccounts()
                loadMessages()
            } catch (e: Exception) {
                Timber.e(e, "Resync failed for group $groupId")
                _resyncDidNotResolve.value = true
            }
            _isResyncing.value = false
        }
    }

    // --- Load messages ---

    suspend fun loadMessages() {
        try {
            val (page, hasMoreBefore) = marmot.messages(groupId, before = null, limit = pageSize)
            // Newest-first from the store; reverse so oldest is at the top.
            val recent = page.mapNotNull { mapMessage(it) }.reversed()

            if (_messages.value.isEmpty()) {
                // Cold load: the recent page is the whole thread we know about.
                _messages.value = recent
                oldestLoaded = page.lastOrNull()
                _hasMore = hasMoreBefore
            } else {
                // A thread is already showing (seeded from cache, or the user
                // paged back). Merge the recent page in without dropping older
                // pages, and leave hasMore untouched: a newest-end refresh says
                // nothing about the start of history.
                _messages.value = merge(_messages.value, recent)
                // Only ever move the cursor backwards. A newest-end refresh
                // stops short of history already paged in, so adopting its
                // tail would rewind the cursor and re-walk seen pages.
                if (oldestLoaded == null) oldestLoaded = page.lastOrNull()
            }
            persist()
        } catch (e: Exception) {
            Timber.e(e, "Failed to load messages for group $groupId")
            notices.report(e, "Couldn't load messages") { loadMessages() }
        }
    }

    /**
     * Union two bubble lists by id (incoming wins, for fresh names/text) and
     * sort into chat order.
     */
    private fun merge(
        existing: List<ChatMessageItem>,
        incoming: List<ChatMessageItem>
    ): List<ChatMessageItem> {
        val byId = LinkedHashMap<String, ChatMessageItem>()
        for (m in existing) byId[m.id] = m
        for (m in incoming) byId[m.id] = m
        return byId.values.sortedWith(inChatOrder)
    }

    private fun persist() {
        messageCache.store(groupId = groupId, messages = _messages.value, hasMore = _hasMore)
    }

    /**
     * Load older messages and prepend them. Because location updates dominate
     * the raw store, a single raw page can contain zero chat messages — so this
     * keeps walking the cursor back until it gathers at least one new bubble or
     * reaches the start of history, up to a bounded scan.
     */
    suspend fun loadMore() {
        val cursor = oldestLoaded
        if (!_hasMore || _isLoadingMore.value || cursor == null) return
        _isLoadingMore.value = true
        try {
            // Dupes are filtered inside the loop: filtering afterwards would let
            // a page of already-shown messages end the scan having added
            // nothing, and "load earlier" would appear to do nothing.
            val seen = _messages.value.map { it.id }.toMutableSet()
            val collected = mutableListOf<ChatMessageItem>()
            var walking: WhistleMessage? = cursor
            var pages = 0
            while (_hasMore && collected.isEmpty() && pages < maxPagesPerLoadMore) {
                val before = walking ?: break
                pages++
                val (page, hasMoreBefore) = marmot.messages(groupId, before = before, limit = pageSize)
                _hasMore = hasMoreBefore
                // An empty page means history is exhausted.
                val tail = page.lastOrNull() ?: break
                walking = tail
                oldestLoaded = tail
                // Older page → its bubbles belong above anything gathered so far.
                val mapped = page.mapNotNull { mapMessage(it) }.reversed().filter { seen.add(it.id) }
                collected.addAll(0, mapped)
            }
            if (collected.isNotEmpty()) {
                _messages.value = collected + _messages.value
            }
            persist()
        } catch (e: Exception) {
            Timber.e(e, "Failed to load more messages")
            // Silence would look like there is nothing older, not a failure.
            notices.report(e, "Couldn't load earlier messages") { loadMore() }
        } finally {
            _isLoadingMore.value = false
        }
    }

    suspend fun loadMemberNames() {
        try {
            val pubkeys = marmot.members(groupId).distinct()
            _memberNames.value = pubkeys.joinToString(", ") { nicknameStore.displayName(it) }
        } catch (e: Exception) {
            _memberNames.value = ""
            Timber.e(e, "Failed to load member names for group $groupId")
        }
    }

    // --- Send ---

    fun sendMessage() {
        val text = _draftText.value.trim()
        if (text.isEmpty()) return

        scope.launch {
            _isSending.value = true
            try {
                val outcome = marmot.sendChat(ChatPayload(text = text), groupId)
                _draftText.value = ""
                loadMessages()
                // A send that reached no relay still succeeds and still appears
                // in the timeline, so without this it looks delivered when
                // nobody else has it.
                if (outcome is MarmotKitService.SendOutcome.Queued) {
                    notices.postToast("Saved, but not sent yet — no relay reachable.") {
                        resendQueued(text)
                    }
                }
            } catch (e: Exception) {
                Timber.e(e, "Failed to send message")
                // The draft stays in place so Retry has something to send.
                notices.report(e, "Message not sent") { sendMessage() }
            } finally {
                _isSending.value = false
            }
        }
    }

    /**
     * Retry for a message that was stored but never published. Re-sends the
     * same text rather than re-running [sendMessage], whose draft is already
     * cleared. A duplicate is possible if the original drains from the queue at
     * the same moment — preferred to the message silently never arriving.
     */
    private suspend fun resendQueued(text: String) {
        try {
            val outcome = marmot.sendChat(ChatPayload(text = text), groupId)
            loadMessages()
            if (outcome is MarmotKitService.SendOutcome.Queued) {
                notices.postToast("Still no relay reachable.")
            }
        } catch (e: Exception) {
            notices.report(e, "Message not sent")
        }
    }

    // --- Mapping ---

    private fun mapMessage(message: WhistleMessage): ChatMessageItem? {
        // Membership and rename events share this timeline. Shown as a system
        // line using MarmotKit's own resolved text ("Member added"), never as
        // a bubble: the raw plaintext is JSON, and attributing it to whoever
        // performed the action made it read as a message they had typed.
        if (message.isSystemEvent) {
            val text = message.systemText?.takeIf { it.isNotEmpty() } ?: return null
            return ChatMessageItem(
                id = message.id,
                senderPubkeyHex = message.senderPubkey,
                senderDisplayName = nicknameStore.displayName(message.senderPubkey),
                text = text,
                timestamp = message.createdAt,
                isMe = false,
                sourceEpoch = message.sourceEpoch,
                isSystemEvent = true
            )
        }

        // Kind is the authority on what a row is. `payloadType` reads a field
        // out of the plaintext, absent on anything we did not write, so it
        // cannot exclude foreign kinds.
        if (message.kind != MarmotKind.ProtocolV2.CHAT.toInt()) return null

        // Skip nickname/avatar payloads. A null type is plain text from an
        // older client — treat as chat.
        val type = message.payloadType
        if (type != null && type != "chat") return null

        val parsed = try {
            val payload = ChatPayload.fromJson(message.content)
            payload.text to payload.ts
        } catch (_: Exception) {
            message.content to message.createdAt
        }

        return ChatMessageItem(
            id = message.id,
            senderPubkeyHex = message.senderPubkey,
            senderDisplayName = nicknameStore.displayName(message.senderPubkey),
            text = parsed.first,
            timestamp = parsed.second,
            isMe = message.senderPubkey == myPubkeyHex,
            sourceEpoch = message.sourceEpoch
        )
    }

    /** Re-map display names in place without reloading. */
    private fun refreshDisplayNames() {
        _messages.value = _messages.value.map { msg ->
            msg.copy(senderDisplayName = nicknameStore.displayName(msg.senderPubkeyHex))
        }
        persist()
    }

    companion object {
        /**
         * Chat order: time, then epoch, then id.
         *
         * Epoch is the load-bearing part. `timestamp` has one-second
         * resolution, so the commits behind one "promote and leave" action
         * share it, and breaking the tie on a hash ordered them arbitrarily —
         * on iOS that put them in the exact reverse of what happened. Id stays
         * the final tiebreaker so the sort is total and stable.
         */
        val inChatOrder: Comparator<ChatMessageItem> = Comparator { a, b ->
            if (a.timestamp != b.timestamp) return@Comparator a.timestamp.compareTo(b.timestamp)
            val ea = a.sourceEpoch
            val eb = b.sourceEpoch
            if (ea != null && eb != null && ea != eb) return@Comparator ea.compareTo(eb)
            a.id.compareTo(b.id)
        }
    }
}
