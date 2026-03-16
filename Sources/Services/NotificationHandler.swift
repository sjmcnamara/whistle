import Foundation
import NostrSDK

/// Bridges Nostr relay subscription callbacks back to `MarmotService`.
///
/// `HandleNotification` runs on the relay connection's background thread,
/// so this handler captures relevant events and dispatches them to the
/// `@MainActor`-isolated `MarmotService` for processing.
final class NotificationHandler: HandleNotification {

    /// Callback invoked for each subscription event.
    /// Called on a background thread — implementations must hop to MainActor.
    private let onEvent: @Sendable (String, Event) -> Void

    init(onEvent: @escaping @Sendable (String, Event) -> Void) {
        self.onEvent = onEvent
    }

    // MARK: - HandleNotification

    func handleMsg(relayUrl: RelayUrl, msg: RelayMessage) async {
        // We only care about individual events, handled in `handle` below.
    }

    func handle(relayUrl: RelayUrl, subscriptionId: String, event: Event) async {
        onEvent(subscriptionId, event)
    }
}
