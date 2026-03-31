package org.findmyfam.shared.models

/**
 * The user's Nostr identity — public-facing only.
 * The private key (nsec) lives exclusively in secure storage, accessed via IdentityService.
 */
data class NostrIdentity(
    /** Full bech32-encoded public key: "npub1..." */
    val npub: String,

    /** Raw hex public key (for internal Nostr event authoring). */
    val publicKeyHex: String
) {
    /** Abbreviated form for UI display: "npub1abc...xyz" */
    val shortNpub: String
        get() = if (npub.length > 16) "${npub.take(10)}...${npub.takeLast(6)}" else npub
}
