import Foundation

/// The user's Nostr identity — public-facing only.
/// The private key (nsec) lives exclusively in the Keychain, accessed via IdentityService.
public struct NostrIdentity: Equatable {
    /// Full bech32-encoded public key: "npub1..."
    public let npub: String

    /// Raw hex public key (for internal Nostr event authoring)
    public let publicKeyHex: String

    public init(npub: String, publicKeyHex: String) {
        self.npub = npub
        self.publicKeyHex = publicKeyHex
    }

    /// Abbreviated form for UI display: "npub1abc...xyz"
    public var shortNpub: String {
        guard npub.count > 16 else { return npub }
        return "\(npub.prefix(10))...\(npub.suffix(6))"
    }
}
