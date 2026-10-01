/// Nostr event kinds used by the Whistle protocol.
///
/// Outer event kinds (30443, 444, 445, 10051) originate from the Marmot MLS-over-Nostr
/// specification (MIP-00→03). Inner application message kinds (chat, location,
/// leaveRequest) are Whistle-specific payloads carried inside kind-445 MLS messages.
public enum MarmotKind {
    // MARK: - Marmot event kinds (MIP-00→03)

    /// MLS KeyPackage — addressable event (MIP-00, MDK 0.8.0+).
    public static let keyPackage: UInt16 = 30443
    /// Welcome — gift-wrapped invitation to join an MLS group.
    public static let welcome: UInt16 = 444
    /// Group event — all in-group traffic: Commits, location updates, chat.
    public static let groupEvent: UInt16 = 445
    /// KeyPackage relay list.
    public static let keyPackageRelayList: UInt16 = 10051

    /// NIP-59 Gift Wrap outer event kind.
    public static let giftWrap: UInt16 = 1059

    // MARK: - Whistle gift-wrapped rumor kinds (NIP-59, alongside Welcome 444)

    /// Join-request — a rumor an invitee gift-wraps to the inviter right after
    /// accepting an invite, carrying their KeyPackage so the admin can batch-add
    /// joiners in one MLS commit without a manual npub exchange. Whistle-specific;
    /// chosen outside the Marmot 443–445 and reserved MIP-05 446–449 kind ranges.
    /// Only seen after unwrapping the kind-1059 gift-wrap, so it never reaches relays.
    public static let joinRequest: UInt16 = 1080

    // MARK: - Whistle inner message kinds (inside kind-445 payloads)

    /// Chat message inner kind.
    public static let chat: UInt16 = 9
    /// Location update inner kind.
    public static let location: UInt16 = 1
    /// Leave request inner kind.
    public static let leaveRequest: UInt16 = 2

    // MARK: - Marmot protocol v2 (MarmotKit) inner kinds

    /// Inner kinds for the protocol-v2 stack, sent via MarmotKit's
    /// `send_custom_event` rather than a hand-built kind-445 event.
    ///
    /// Separate from the v1 constants above because **`chat` cannot stay 9**:
    /// MDK reserves kind 9 for its own CHAT type and `send_custom_event`
    /// rejects any reserved kind outright (`RESERVED_APP_EVENT_KINDS` /
    /// `validate_custom_event_kind` in `crates/marmot-app` — a pure
    /// kind-value check with no call-path exception). The full reserved set is
    /// 5, 7, 9, 447, 448, 449, 1009, 1018, 1068, 1200, 1201, 1202, 1210, 1984,
    /// 1985 and 4891; see CLAUDE.md's MDK 2.0 section for the named table.
    ///
    /// `location` and `leaveRequest` keep their v1 values, which are clear of
    /// every reserved kind. The two kind sets are never on the wire together:
    /// v1 and v2 are not wire-compatible, and v2 groups are created fresh.
    public enum V2 {
        /// 9 is reserved by MDK, so chat moves to an unreserved low value.
        public static let chat: UInt16 = 3
        public static let location: UInt16 = MarmotKind.location
        public static let leaveRequest: UInt16 = MarmotKind.leaveRequest
    }
}
