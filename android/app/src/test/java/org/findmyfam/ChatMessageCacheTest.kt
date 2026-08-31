package org.findmyfam

import org.findmyfam.services.ChatMessageCache
import org.findmyfam.viewmodels.ChatViewModel.ChatMessageItem
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/**
 * Tests for ChatMessageCache -- the in-memory, per-group chat thread cache that
 * lets a freshly-created ChatViewModel render instantly on re-entry.
 * Parity with iOS ChatMessageCacheTests.
 */
class ChatMessageCacheTest {

    private lateinit var cache: ChatMessageCache
    private val group1 = "group-aaa"
    private val group2 = "group-bbb"
    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)

    @Before
    fun setUp() {
        cache = ChatMessageCache()
    }

    private fun item(
        id: String,
        text: String = "hi",
        sender: String = alice,
        isMe: Boolean = false,
        ts: Long = 1_000L
    ) = ChatMessageItem(
        id = id,
        senderPubkeyHex = sender,
        senderDisplayName = if (isMe) "Me" else "Alice",
        text = text,
        timestamp = ts,
        isMe = isMe
    )

    @Test
    fun thread_isNull_whenNothingStored() {
        assertNull(cache.thread(group1))
    }

    @Test
    fun store_thenThread_returnsSameMessages() {
        val messages = listOf(item(id = "m1"), item(id = "m2", sender = bob))
        cache.store(group1, messages, offset = 5u, hasMore = true)

        val thread = cache.thread(group1)
        assertEquals(messages, thread?.messages)
        assertEquals(5u, thread?.offset)
        assertEquals(true, thread?.hasMore)
    }

    @Test
    fun store_preservesPaginationCursor() {
        cache.store(group1, listOf(item(id = "m1")), offset = 42u, hasMore = false)

        val thread = cache.thread(group1)
        assertEquals(42u, thread?.offset)
        assertEquals(false, thread?.hasMore)
    }

    @Test
    fun store_replacesExistingThread() {
        cache.store(group1, listOf(item(id = "m1")), offset = 1u, hasMore = true)
        cache.store(group1, listOf(item(id = "m2"), item(id = "m3")), offset = 9u, hasMore = false)

        val thread = cache.thread(group1)
        assertEquals(listOf("m2", "m3"), thread?.messages?.map { it.id })
        assertEquals(9u, thread?.offset)
        assertEquals(false, thread?.hasMore)
    }

    @Test
    fun groups_areIsolated() {
        cache.store(group1, listOf(item(id = "a1")), offset = 1u, hasMore = true)
        cache.store(group2, listOf(item(id = "b1")), offset = 2u, hasMore = false)

        assertEquals(listOf("a1"), cache.thread(group1)?.messages?.map { it.id })
        assertEquals(listOf("b1"), cache.thread(group2)?.messages?.map { it.id })
    }

    @Test
    fun clearGroup_dropsOnlyThatGroup() {
        cache.store(group1, listOf(item(id = "a1")), offset = 1u, hasMore = true)
        cache.store(group2, listOf(item(id = "b1")), offset = 2u, hasMore = false)

        cache.clearGroup(group1)

        assertNull(cache.thread(group1))
        assertNotNull(cache.thread(group2))
    }

    @Test
    fun clearGroup_isNoOp_forUnknownGroup() {
        cache.store(group1, listOf(item(id = "a1")), offset = 1u, hasMore = true)
        cache.clearGroup("does-not-exist")
        assertNotNull(cache.thread(group1))
    }

    @Test
    fun clear_dropsEveryThread() {
        cache.store(group1, listOf(item(id = "a1")), offset = 1u, hasMore = true)
        cache.store(group2, listOf(item(id = "b1")), offset = 2u, hasMore = false)

        cache.clear()

        assertNull(cache.thread(group1))
        assertNull(cache.thread(group2))
    }

    @Test
    fun store_emptyMessages_isDistinctFromUnstored() {
        cache.store(group1, emptyList(), offset = 0u, hasMore = false)
        val thread = cache.thread(group1)
        assertNotNull("an empty-but-loaded thread must be cached, not treated as absent", thread)
        assertEquals(0, thread?.messages?.size)
    }
}
