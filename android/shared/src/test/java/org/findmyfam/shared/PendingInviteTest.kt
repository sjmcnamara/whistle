package org.findmyfam.shared

import org.findmyfam.shared.models.PendingInvite
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PendingInviteTest {

    @Test
    fun `id equals groupHint`() {
        val invite = PendingInvite(groupHint = "group123", inviterNpub = "npub1test")
        assertEquals("group123", invite.id)
    }

    @Test
    fun `createdAt defaults to now within 5 seconds`() {
        val before = System.currentTimeMillis() / 1000
        val invite = PendingInvite(groupHint = "g", inviterNpub = "npub1x")
        val after = System.currentTimeMillis() / 1000
        assertTrue(invite.createdAt in before..after + 5)
    }
}
