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
}
