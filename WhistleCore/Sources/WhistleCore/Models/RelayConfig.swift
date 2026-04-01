import Foundation

/// Configuration for a single Nostr relay.
public struct RelayConfig: Identifiable, Codable, Hashable {
    public let id: UUID
    public var url: String
    public var isEnabled: Bool

    public init(url: String, isEnabled: Bool = true) {
        self.id = UUID()
        self.url = url
        self.isEnabled = isEnabled
    }
}
