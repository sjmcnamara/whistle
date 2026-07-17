package org.findmyfam.services

import org.findmyfam.viewmodels.ChatViewModel
import javax.inject.Inject
import javax.inject.Singleton

/**
 * In-memory cache of loaded chat threads, keyed by group id.
 *
 * A [ChatViewModel] is created per-group via `remember(groupId)` in the chat
 * composable and is discarded when the chat is popped off the nav back stack,
 * then rebuilt (empty) when re-entered. Without a cache that would flash an
 * empty thread and re-decrypt the recent page from MDK every visit. This cache
 * lets a freshly-created [ChatViewModel] seed itself synchronously with the
 * last-known messages so the thread renders instantly; a background refresh
 * then merges in anything new.
 *
 * Purely in-memory -- the durable store remains MDK's encrypted SQLite DB.
 */
@Singleton
class ChatMessageCache @Inject constructor() {

    /**
     * A cached thread: the displayed bubbles plus the pagination cursor so
     * "load earlier" continues from where the deepest load reached.
     */
    data class Thread(
        val messages: List<ChatViewModel.ChatMessageItem>,
        // Offset into MDK's raw message store (see ChatViewModel.currentOffset).
        val offset: UInt,
        // Whether older messages remain to be paged in.
        val hasMore: Boolean
    )

    private val threads = mutableMapOf<String, Thread>()

    /** The cached thread for a group, if one has been loaded this session. */
    fun thread(groupId: String): Thread? = threads[groupId]

    /** Store (or replace) the cached thread for a group. */
    fun store(groupId: String, messages: List<ChatViewModel.ChatMessageItem>, offset: UInt, hasMore: Boolean) {
        threads[groupId] = Thread(messages = messages, offset = offset, hasMore = hasMore)
    }

    /** Drop a single group's cached thread. */
    fun clearGroup(groupId: String) {
        threads.remove(groupId)
    }

    /** Drop all cached threads (e.g. on logout / identity reset). */
    fun clear() {
        threads.clear()
    }
}
