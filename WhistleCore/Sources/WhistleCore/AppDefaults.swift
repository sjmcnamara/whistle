/// Shared constants and preference key strings for the FindMyFam app.
/// Referenced by both AppSettings (platform-specific) and the shared library.
public enum AppDefaults {

    /// Default Nostr relays used on first launch.
    public static let defaultRelays: [String] = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net"
    ]

    /// Default location sharing interval in seconds (1 hour).
    public static let defaultLocationIntervalSeconds: Int = 3600

    /// Default MLS group key rotation interval in days (1 week).
    public static let defaultKeyRotationIntervalDays: Int = 7

    /// UserDefaults key strings.
    /// All keys use the "fmf." prefix for namespacing.
    public enum Keys {
        public static let relays = "fmf.relays"
        public static let displayName = "fmf.displayName"
        public static let locationInterval = "fmf.locationInterval"
        public static let locationPaused = "fmf.locationPaused"
        public static let appLockEnabled = "fmf.appLockEnabled"
        public static let appLockReauthOnForeground = "fmf.appLockReauthOnForeground"
        public static let lastEventTimestamp = "fmf.lastEventTimestamp"
        public static let processedEventIds = "fmf.processedEventIds"
        public static let pendingLeaveRequests = "fmf.pendingLeaveRequests"
        public static let pendingGiftWrapEventIds = "fmf.pendingGiftWrapEventIds"
        public static let keyRotationIntervalDays = "fmf.keyRotationIntervalDays"
    }
}
