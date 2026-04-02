/// Nostr event kinds used by the Whistle protocol.
///
/// Outer event kinds (443, 444, 445, 10051) originate from the Marmot MLS-over-Nostr
/// specification (MIP-00→03). Inner application message kinds (chat, location,
/// leaveRequest) are Whistle-specific payloads carried inside kind-445 MLS messages.
public enum MarmotKind {
    // MARK: - Marmot event kinds (MIP-00→03)

    /// MLS KeyPackage — published by each user to advertise their MLS credentials.
    public static let keyPackage: UInt16 = 443
    /// Welcome — gift-wrapped invitation to join an MLS group.
    public static let welcome: UInt16 = 444
    /// Group event — all in-group traffic: Commits, location updates, chat.
    public static let groupEvent: UInt16 = 445
    /// KeyPackage relay list.
    public static let keyPackageRelayList: UInt16 = 10051

    /// NIP-59 Gift Wrap outer event kind.
    public static let giftWrap: UInt16 = 1059

    // MARK: - Whistle inner message kinds (inside kind-445 payloads)

    /// Chat message inner kind.
    public static let chat: UInt16 = 9
    /// Location update inner kind.
    public static let location: UInt16 = 1
    /// Leave request inner kind.
    public static let leaveRequest: UInt16 = 2
}
