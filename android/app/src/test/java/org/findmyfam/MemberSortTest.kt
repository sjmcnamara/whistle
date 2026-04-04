package org.findmyfam

import org.findmyfam.viewmodels.GroupDetailViewModel.MemberItem
import org.junit.Assert.*
import org.junit.Test

/**
 * Tests for the member list sorting logic used by GroupDetailViewModel.
 * Sort order: me first, then admins, then alphabetical by display name.
 */
class MemberSortTest {

    private val myPubkey = "a".repeat(64)

    private fun member(
        pubkey: String,
        name: String,
        isAdmin: Boolean = false,
        isMe: Boolean = false
    ) = MemberItem(
        id = pubkey,
        pubkeyHex = pubkey,
        displayName = name,
        isAdmin = isAdmin,
        isMe = isMe
    )

    private fun sortMembers(members: List<MemberItem>): List<MemberItem> {
        return members.sortedWith(
            compareByDescending<MemberItem> { it.isMe }
                .thenByDescending { it.isAdmin }
                .thenBy { it.displayName }
        )
    }

    @Test
    fun meAlwaysFirst() {
        val members = listOf(
            member("ccc", "Charlie"),
            member(myPubkey, "Me", isMe = true),
            member("bbb", "Alice")
        )
        val sorted = sortMembers(members)
        assertTrue(sorted[0].isMe)
    }

    @Test
    fun adminBeforeRegularMember() {
        val members = listOf(
            member("ccc", "Zara"),
            member("bbb", "Admin Bob", isAdmin = true),
            member("ddd", "Alice")
        )
        val sorted = sortMembers(members)
        assertEquals("Admin Bob", sorted[0].displayName)
    }

    @Test
    fun meBeforeAdmin() {
        val members = listOf(
            member("bbb", "Admin Bob", isAdmin = true),
            member(myPubkey, "Me", isMe = true)
        )
        val sorted = sortMembers(members)
        assertTrue(sorted[0].isMe)
        assertTrue(sorted[1].isAdmin)
    }

    @Test
    fun meAndAdmin_meFirst() {
        val members = listOf(
            member("bbb", "Admin Bob", isAdmin = true),
            member(myPubkey, "Me (Admin)", isAdmin = true, isMe = true),
            member("ccc", "Charlie")
        )
        val sorted = sortMembers(members)
        assertTrue(sorted[0].isMe)
    }

    @Test
    fun regularMembers_alphabetical() {
        val members = listOf(
            member("ccc", "Charlie"),
            member("ddd", "Alice"),
            member("eee", "Bob")
        )
        val sorted = sortMembers(members)
        assertEquals("Alice", sorted[0].displayName)
        assertEquals("Bob", sorted[1].displayName)
        assertEquals("Charlie", sorted[2].displayName)
    }

    @Test
    fun multipleAdmins_alphabetical() {
        val members = listOf(
            member("bbb", "Zara Admin", isAdmin = true),
            member("ccc", "Alice Admin", isAdmin = true),
            member("ddd", "Regular")
        )
        val sorted = sortMembers(members)
        assertEquals("Alice Admin", sorted[0].displayName)
        assertEquals("Zara Admin", sorted[1].displayName)
        assertEquals("Regular", sorted[2].displayName)
    }

    @Test
    fun singleMember_noError() {
        val members = listOf(member(myPubkey, "Me", isMe = true))
        val sorted = sortMembers(members)
        assertEquals(1, sorted.size)
        assertTrue(sorted[0].isMe)
    }

    @Test
    fun emptyList_noError() {
        val sorted = sortMembers(emptyList())
        assertTrue(sorted.isEmpty())
    }

    @Test
    fun fullScenario_correctOrder() {
        val members = listOf(
            member("fff", "Frank"),
            member("bbb", "Bob Admin", isAdmin = true),
            member(myPubkey, "Me", isMe = true),
            member("ddd", "Dave"),
            member("eee", "Eve Admin", isAdmin = true),
            member("aaa", "Alice")
        )
        val sorted = sortMembers(members)
        assertEquals("Me", sorted[0].displayName)         // me first
        assertEquals("Bob Admin", sorted[1].displayName)   // admins next, alphabetical
        assertEquals("Eve Admin", sorted[2].displayName)
        assertEquals("Alice", sorted[3].displayName)       // regular members, alphabetical
        assertEquals("Dave", sorted[4].displayName)
        assertEquals("Frank", sorted[5].displayName)
    }
}
