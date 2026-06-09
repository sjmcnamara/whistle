import Foundation
import UserNotifications

/// Fires a local notification when a group member's battery crosses below the alert threshold.
///
/// Tracks the last known battery level per member so it only fires once per crossing
/// (e.g. 21% → 19% fires; subsequent 18%, 15% updates do not re-fire until the level
/// recovers above the threshold and drops again).
@MainActor
final class BatteryAlertService {

    static let threshold = 20

    private var lastKnownBattery: [String: Int] = [:]
    private let myPubkeyHex: String
    private weak var nicknameStore: NicknameStore?

    /// Called when an alert should fire. Defaults to a real UNUserNotificationCenter delivery;
    /// replace in tests to capture alerts without touching the notification system.
    var deliver: (_ name: String, _ battery: Int, _ pubkeyHex: String) -> Void

    init(myPubkeyHex: String, nicknameStore: NicknameStore?) {
        self.myPubkeyHex = myPubkeyHex
        self.nicknameStore = nicknameStore
        self.deliver = { name, battery, pubkeyHex in
            let content = UNMutableNotificationContent()
            content.title = "Low Battery"
            content.body = "\(name)'s battery is at \(battery)%"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "battery.\(pubkeyHex)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    WhistleLogger.marmot.warning("Battery alert notification failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Call this whenever a location payload arrives for a group member.
    func check(pubkeyHex: String, battery: Int?) {
        guard let battery else { return }
        guard pubkeyHex != myPubkeyHex else { return }

        let previous = lastKnownBattery[pubkeyHex]
        lastKnownBattery[pubkeyHex] = battery

        guard battery < Self.threshold else { return }
        guard previous == nil || previous! >= Self.threshold else { return }

        let name = nicknameStore?.displayName(for: pubkeyHex) ?? String(pubkeyHex.prefix(8))
        deliver(name, battery, pubkeyHex)
    }

    /// Request notification authorisation. Call once during app startup.
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            WhistleLogger.marmot.info("Notification permission: \(granted ? "granted" : "denied")")
        }
    }
}
