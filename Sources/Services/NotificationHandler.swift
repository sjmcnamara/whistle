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

    /// Callback invoked when a relay signals end-of-stored-events for a subscription.
    /// Called on a background thread — implementations must hop to MainActor.
    private let onEose: @Sendable (String) -> Void

    init(onEvent: @escaping @Sendable (String, Event) -> Void,
         onEose: @escaping @Sendable (String) -> Void) {
        self.onEvent = onEvent
        self.onEose = onEose
    }

    // MARK: - HandleNotification

    func handleMsg(relayUrl: RelayUrl, msg: RelayMessage) async {
        if case .endOfStoredEvents(let subscriptionId) = msg.asEnum() {
            onEose(subscriptionId)
        }
    }

    func handle(relayUrl: RelayUrl, subscriptionId: String, event: Event) async {
        onEvent(subscriptionId, event)
    }
}
