import Foundation
import Combine
import SwiftUI
import WhistleCore

/// User's preferred appearance mode.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

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

    /// User's preferred appearance (system / light / dark).
    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// How often (in days) MLS group keys are automatically rotated via self-update.
    /// Default: 7 days. Range: 1–30.
    @Published var keyRotationIntervalDays: Int {
        didSet { UserDefaults.standard.set(keyRotationIntervalDays, forKey: Keys.keyRotationIntervalDays) }
    }

    /// Location fuzzing radius in metres. 0 = off (exact location shared).
    /// When non-zero, a random offset within this radius is applied before broadcasting.
    @Published var locationFuzzMeters: Int {
        didSet { UserDefaults.standard.set(locationFuzzMeters, forKey: Keys.locationFuzzMeters) }
    }

    /// SwiftUI color scheme derived from the appearance preference.
    /// Returns `nil` for `.system` so the OS default is used.
    var colorScheme: ColorScheme? {
        switch appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
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
        self.appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: Keys.appearance) ?? "") ?? .system
        self.isAppLockEnabled = UserDefaults.standard.bool(forKey: Keys.appLockEnabled)
        self.isAppLockReauthOnForeground = UserDefaults.standard.bool(forKey: Keys.appLockReauthOnForeground)
        let storedTimestamp = UserDefaults.standard.integer(forKey: Keys.lastEventTimestamp)
        self.lastEventTimestamp = UInt64(bitPattern: Int64(storedTimestamp))

        self.keyRotationIntervalDays = UserDefaults.standard.integer(forKey: Keys.keyRotationIntervalDays)
            .nonZeroOr(AppDefaults.defaultKeyRotationIntervalDays)
        self.locationFuzzMeters = UserDefaults.standard.integer(forKey: Keys.locationFuzzMeters)

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
