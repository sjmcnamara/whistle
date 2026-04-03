package org.findmyfam.shared.models

/**
 * Shared constants and preference key strings for the FindMyFam app.
 * Referenced by both AppSettings (platform-specific) and the shared library.
 */
object AppDefaults {

    /** Default Nostr relays used on first launch. */
    val defaultRelays: List<String> = listOf(
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net"
    )

    /** Default location sharing interval in seconds (1 hour). */
    const val defaultLocationIntervalSeconds: Int = 3600

    /** Default MLS group key rotation interval in days (1 week). */
    const val defaultKeyRotationIntervalDays: Int = 7

    /**
     * SharedPreferences / UserDefaults key strings.
     * All keys use the "fmf." prefix for namespacing.
     */
    object Keys {
        const val relays = "fmf.relays"
        const val displayName = "fmf.displayName"
        const val locationInterval = "fmf.locationInterval"
        const val locationPaused = "fmf.locationPaused"
        const val appLockEnabled = "fmf.appLockEnabled"
        const val appLockReauthOnForeground = "fmf.appLockReauthOnForeground"
        const val lastEventTimestamp = "fmf.lastEventTimestamp"
        const val processedEventIds = "fmf.processedEventIds"
        const val pendingLeaveRequests = "fmf.pendingLeaveRequests"
        const val pendingGiftWrapEventIds = "fmf.pendingGiftWrapEventIds"
        const val keyRotationIntervalDays = "fmf.keyRotationIntervalDays"
        const val appearance = "fmf.appearance"
        const val locationFuzzMeters = "fmf.locationFuzzMeters"
    }
}
