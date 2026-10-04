package org.findmyfam.shared

/**
 * Nostr event kinds used by the Whistle protocol.
 *
 * Outer event kinds (30443, 444, 445, 10051) originate from the Marmot MLS-over-Nostr
 * specification (MIP-00→03). Inner application message kinds (CHAT, LOCATION,
 * LEAVE_REQUEST) are Whistle-specific payloads carried inside kind-445 MLS messages.
 */
object MarmotKind {
    // Marmot event kinds (MIP-00→03)

    /** MLS KeyPackage — addressable event (MIP-00, MDK 0.8.0+). */
    const val KEY_PACKAGE: UShort = 30443u

    /** Welcome — gift-wrapped invitation to join an MLS group. */
    const val WELCOME: UShort = 444u

    /** Group event — all in-group traffic: Commits, location updates, chat. */
    const val GROUP_EVENT: UShort = 445u

    /** KeyPackage relay list. */
    const val KEY_PACKAGE_RELAY_LIST: UShort = 10051u

    /** NIP-59 Gift Wrap outer event kind. */
    const val GIFT_WRAP: UShort = 1059u

    // Whistle gift-wrapped rumor kinds (NIP-59, alongside Welcome 444)

    /**
     * Join-request — a rumor an invitee gift-wraps to the inviter right after
     * accepting an invite, carrying their KeyPackage so the admin can batch-add
     * joiners in one MLS commit without a manual npub exchange. Whistle-specific;
     * chosen outside the Marmot 443–445 and reserved MIP-05 446–449 kind ranges.
     * Only seen after unwrapping the kind-1059 gift-wrap, so it never reaches relays.
     */
    const val JOIN_REQUEST: UShort = 1080u

    // Whistle inner message kinds (inside kind-445 payloads)

    /** Chat message inner kind. */
    const val CHAT: UShort = 9u

    /** Location update inner kind. */
    const val LOCATION: UShort = 1u

    /** Leave request inner kind. */
    const val LEAVE_REQUEST: UShort = 2u

    /**
     * Inner kinds under Marmot protocol v2.
     *
     * MDK reserves a fixed set of inner kinds and `send_custom_event` rejects
     * any of them outright — the check is purely value-based, with no
     * call-path exception. The reserved set is 5, 7, 9, 447, 448, 449, 1009,
     * 1018, 1068, 1200, 1201, 1202, 1210, 1984, 1985 and 4891.
     *
     * `CHAT` therefore moves from 9, which collides with MDK's own CHAT, to
     * an unreserved low value. `LOCATION` and `LEAVE_REQUEST` are clear of
     * every reserved value and keep their numbering.
     */
    object ProtocolV2 {
        /** 9 is reserved by MDK, so chat moves to an unreserved low value. */
        const val CHAT: UShort = 3u
        const val LOCATION: UShort = LOCATION_V1
        const val LEAVE_REQUEST: UShort = LEAVE_REQUEST_V1
    }

    // Aliases so `ProtocolV2` can reference these without a forward reference.
    private const val LOCATION_V1: UShort = 1u
    private const val LEAVE_REQUEST_V1: UShort = 2u
}
