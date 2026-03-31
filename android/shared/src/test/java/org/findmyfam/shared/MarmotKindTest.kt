package org.findmyfam.shared

import kotlin.test.Test
import kotlin.test.assertEquals

class MarmotKindTest {

    @Test
    fun `keyPackage is 443`() {
        assertEquals(443u.toUShort(), MarmotKind.KEY_PACKAGE)
    }

    @Test
    fun `welcome is 444`() {
        assertEquals(444u.toUShort(), MarmotKind.WELCOME)
    }

    @Test
    fun `groupEvent is 445`() {
        assertEquals(445u.toUShort(), MarmotKind.GROUP_EVENT)
    }

    @Test
    fun `keyPackageRelayList is 10051`() {
        assertEquals(10051u.toUShort(), MarmotKind.KEY_PACKAGE_RELAY_LIST)
    }

    @Test
    fun `giftWrap is 1059`() {
        assertEquals(1059u.toUShort(), MarmotKind.GIFT_WRAP)
    }

    @Test
    fun `chat is 9`() {
        assertEquals(9u.toUShort(), MarmotKind.CHAT)
    }

    @Test
    fun `location is 1`() {
        assertEquals(1u.toUShort(), MarmotKind.LOCATION)
    }

    @Test
    fun `leaveRequest is 2`() {
        assertEquals(2u.toUShort(), MarmotKind.LEAVE_REQUEST)
    }
}
