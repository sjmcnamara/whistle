package org.findmyfam.shared.models

/**
 * Shared constants and preference key strings for the FindMyFam app.
 * Referenced by both AppSettings (platform-specific) and the shared library.
 */
object AppDefaults {

    /**
     * Default Nostr relays used on first launch.
     *
     * `wss://relay.damus.io` was the first entry here and is deliberately
     * gone: MarmotKit enforces a relay safety policy at the dial boundary and
     * refuses "retired" hosts outright — failing identity creation rather than
     * skipping them — and damus.io is one. Verified on device against
     * `classifyRelayEndpoints`: `relay.damus.io=retired`, `nos.lol=allowed`,
     * `relay.primal.net=allowed`. A user's own saved list is filtered at
     * runtime for the same reason; this list only stops a fresh install
     * walking into it.
     */
    val defaultRelays: List<String> = listOf(
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
        const val pendingGiftWrapEventIds = "fmf.pendingGiftWrapEventIds"
        const val pausedGroupIds = "fmf.pausedGroupIds"
        const val keyRotationIntervalDays = "fmf.keyRotationIntervalDays"
        const val appearance = "fmf.appearance"
        const val locationFuzzMeters = "fmf.locationFuzzMeters"
        const val motionAdaptive = "fmf.motionAdaptive"
        const val marmotKitRootGeneration = "fmf.marmotKitRootGeneration"
    }
}
