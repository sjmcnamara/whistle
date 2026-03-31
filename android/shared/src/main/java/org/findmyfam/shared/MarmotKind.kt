package org.findmyfam.shared

/**
 * Nostr event kinds used by the Marmot protocol.
 */
object MarmotKind {
    /** MLS KeyPackage — published by each user to advertise their MLS credentials. */
    const val KEY_PACKAGE: UShort = 443u

    /** Welcome — gift-wrapped invitation to join an MLS group. */
    const val WELCOME: UShort = 444u

    /** Group event — all in-group traffic: Commits, location updates, chat. */
    const val GROUP_EVENT: UShort = 445u

    /** KeyPackage relay list. */
    const val KEY_PACKAGE_RELAY_LIST: UShort = 10051u

    /** NIP-59 Gift Wrap outer event kind. */
    const val GIFT_WRAP: UShort = 1059u

    // Inner application message kinds (inside kind-445 payloads)

    /** Chat message inner kind. */
    const val CHAT: UShort = 9u

    /** Location update inner kind. */
    const val LOCATION: UShort = 1u

    /** Leave request inner kind. */
    const val LEAVE_REQUEST: UShort = 2u
}
