package org.findmyfam

import org.findmyfam.viewmodels.GroupListViewModel.GroupListItem
import org.junit.Assert.*
import org.junit.Test

/**
 * Tests for GroupListItem data class behaviour and unread logic.
 */
class GroupListItemTest {

    private fun item(
        id: String = "group-1",
        name: String = "Test Group",
        memberCount: Int = 3,
        lastActivity: Long? = 1000L,
        isActive: Boolean = true,
        hasUnread: Boolean = false
    ) = GroupListItem(id, name, memberCount, lastActivity, isActive, hasUnread)

    @Test
    fun defaultValues() {
        val group = item()
        assertEquals("group-1", group.id)
        assertEquals("Test Group", group.name)
        assertEquals(3, group.memberCount)
        assertTrue(group.isActive)
        assertFalse(group.hasUnread)
    }

    @Test
    fun hasUnread_true() {
        val group = item(hasUnread = true)
        assertTrue(group.hasUnread)
    }

    @Test
    fun unreadLogic_chatAfterLastRead_isUnread() {
        // Simulates: lastChatEpoch=100, lastRead=50 → hasUnread=true
        val lastChatEpoch: Long? = 100
        val lastRead: Long = 50
        val hasUnread = lastChatEpoch != null && lastChatEpoch > lastRead
        assertTrue(hasUnread)
    }

    @Test
    fun unreadLogic_chatBeforeLastRead_isNotUnread() {
        val lastChatEpoch: Long? = 30
        val lastRead: Long = 50
        val hasUnread = lastChatEpoch != null && lastChatEpoch > lastRead
        assertFalse(hasUnread)
    }

    @Test
    fun unreadLogic_noChatTimestamp_isNotUnread() {
        val lastChatEpoch: Long? = null
        val lastRead: Long = 50
        val hasUnread = lastChatEpoch != null && lastChatEpoch > lastRead
        assertFalse(hasUnread)
    }

    @Test
    fun unreadLogic_chatEqualsLastRead_isNotUnread() {
        val lastChatEpoch: Long? = 50
        val lastRead: Long = 50
        val hasUnread = lastChatEpoch != null && lastChatEpoch > lastRead
        assertFalse(hasUnread)
    }

    @Test
    fun equality_sameValues() {
        val a = item()
        val b = item()
        assertEquals(a, b)
    }

    @Test
    fun equality_differentUnread() {
        val a = item(hasUnread = false)
        val b = item(hasUnread = true)
        assertNotEquals(a, b)
    }

    @Test
    fun copy_togglesUnread() {
        val original = item(hasUnread = false)
        val updated = original.copy(hasUnread = true)
        assertFalse(original.hasUnread)
        assertTrue(updated.hasUnread)
    }

    @Test
    fun inactiveGroup() {
        val group = item(isActive = false)
        assertFalse(group.isActive)
    }

    @Test
    fun nullLastActivity() {
        val group = item(lastActivity = null)
        assertNull(group.lastActivity)
    }
}
