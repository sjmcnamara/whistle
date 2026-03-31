import Foundation
import Combine
import FindMyFamCore

/// App-wide settings backed by UserDefaults.
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    static let defaultRelays: [RelayConfig] = AppDefaults.defaultRelays.map { RelayConfig(url: $0) }

    @Published var relays: [RelayConfig] {
        didSet { save() }
    }

    /// Location update interval in seconds (default 1 hour).
    @Published var locationIntervalSeconds: Int {
        didSet { UserDefaults.standard.set(locationIntervalSeconds, forKey: Keys.locationInterval) }
    }

    /// Whether location sharing is currently paused.
    @Published var isLocationPaused: Bool {
        didSet { UserDefaults.standard.set(isLocationPaused, forKey: Keys.locationPaused) }
    }

    /// User's chosen display name (broadcast to groups as nickname).
    @Published var displayName: String {
        didSet { UserDefaults.standard.set(displayName, forKey: Keys.displayName) }
    }

    /// Whether app lock is enabled.
    @Published var isAppLockEnabled: Bool {
        didSet { UserDefaults.standard.set(isAppLockEnabled, forKey: Keys.appLockEnabled) }
    }

    /// When enabled, require unlock every time the app returns to foreground.
    @Published var isAppLockReauthOnForeground: Bool {
        didSet { UserDefaults.standard.set(isAppLockReauthOnForeground, forKey: Keys.appLockReauthOnForeground) }
    }

    /// Timestamp (epoch seconds) of the last successfully processed Nostr event.
    /// Used to resume subscriptions with a `since` filter after offline periods.
    @Published var lastEventTimestamp: UInt64 {
        didSet { UserDefaults.standard.set(Int64(bitPattern: lastEventTimestamp), forKey: Keys.lastEventTimestamp) }
    }

    /// Set of event IDs that have been processed to prevent reprocessing on restart.
    @Published var processedEventIds: Set<String> {
        didSet { saveProcessedEventIds() }
    }

    /// Pending leave requests per group — stored until processed by admin.
    @Published var pendingLeaveRequests: [String: Set<String>] {
        didSet { savePendingLeaveRequests() }
    }

    /// Gift-wrap (welcome) event IDs that have failed due to missing key package.
    /// Re-tried after key package refresh.
    @Published var pendingGiftWrapEventIds: Set<String> {
        didSet { savePendingGiftWrapEventIds() }
    }

    /// How often (in days) MLS group keys are automatically rotated via self-update.
    /// Default: 7 days. Range: 1–30.
    @Published var keyRotationIntervalDays: Int {
        didSet { UserDefaults.standard.set(keyRotationIntervalDays, forKey: Keys.keyRotationIntervalDays) }
    }

    /// Rotation interval converted to seconds for the MDK API.
    var keyRotationIntervalSecs: UInt64 {
        UInt64(keyRotationIntervalDays) * 24 * 3600
    }

    private typealias Keys = AppDefaults.Keys

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.relays),
           let decoded = try? JSONDecoder().decode([RelayConfig].self, from: data) {
            self.relays = decoded
        } else {
            self.relays = Self.defaultRelays
        }
        self.locationIntervalSeconds = UserDefaults.standard.integer(forKey: Keys.locationInterval)
            .nonZeroOr(AppDefaults.defaultLocationIntervalSeconds)
        self.isLocationPaused = UserDefaults.standard.bool(forKey: Keys.locationPaused)
        self.displayName = UserDefaults.standard.string(forKey: Keys.displayName) ?? ""
        self.isAppLockEnabled = UserDefaults.standard.bool(forKey: Keys.appLockEnabled)
        self.isAppLockReauthOnForeground = UserDefaults.standard.bool(forKey: Keys.appLockReauthOnForeground)
        let storedTimestamp = UserDefaults.standard.integer(forKey: Keys.lastEventTimestamp)
        self.lastEventTimestamp = UInt64(bitPattern: Int64(storedTimestamp))

        self.keyRotationIntervalDays = UserDefaults.standard.integer(forKey: Keys.keyRotationIntervalDays)
            .nonZeroOr(AppDefaults.defaultKeyRotationIntervalDays)

        if let data = UserDefaults.standard.data(forKey: Keys.processedEventIds),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            self.processedEventIds = decoded
        } else {
            self.processedEventIds = []
        }

        if let data = UserDefaults.standard.data(forKey: Keys.pendingLeaveRequests),
           let decoded = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            self.pendingLeaveRequests = decoded
        } else {
            self.pendingLeaveRequests = [:]
        }

        if let data = UserDefaults.standard.data(forKey: Keys.pendingGiftWrapEventIds),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            self.pendingGiftWrapEventIds = decoded
        } else {
            self.pendingGiftWrapEventIds = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(relays) {
            UserDefaults.standard.set(data, forKey: Keys.relays)
        }
    }

    private func saveProcessedEventIds() {
        if let data = try? JSONEncoder().encode(processedEventIds) {
            UserDefaults.standard.set(data, forKey: Keys.processedEventIds)
        }
    }

    private func savePendingLeaveRequests() {
        if let data = try? JSONEncoder().encode(pendingLeaveRequests) {
            UserDefaults.standard.set(data, forKey: Keys.pendingLeaveRequests)
        }
    }

    private func savePendingGiftWrapEventIds() {
        if let data = try? JSONEncoder().encode(pendingGiftWrapEventIds) {
            UserDefaults.standard.set(data, forKey: Keys.pendingGiftWrapEventIds)
        }
    }
}

private extension Int {
    func nonZeroOr(_ fallback: Int) -> Int {
        self == 0 ? fallback : self
    }
}
