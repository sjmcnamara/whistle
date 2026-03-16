import Foundation
import Combine

/// App-wide settings backed by UserDefaults.
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    static let defaultRelays: [RelayConfig] = [
        RelayConfig(url: "wss://relay.damus.io"),
        RelayConfig(url: "wss://nos.lol"),
        RelayConfig(url: "wss://relay.primal.net")
    ]

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

    private enum Keys {
        static let relays = "fmf.relays"
        static let locationInterval = "fmf.locationInterval"
        static let locationPaused = "fmf.locationPaused"
        static let displayName = "fmf.displayName"
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.relays),
           let decoded = try? JSONDecoder().decode([RelayConfig].self, from: data) {
            self.relays = decoded
        } else {
            self.relays = Self.defaultRelays
        }
        self.locationIntervalSeconds = UserDefaults.standard.integer(forKey: Keys.locationInterval)
            .nonZeroOr(3600)
        self.isLocationPaused = UserDefaults.standard.bool(forKey: Keys.locationPaused)
        self.displayName = UserDefaults.standard.string(forKey: Keys.displayName) ?? ""
    }

    private func save() {
        if let data = try? JSONEncoder().encode(relays) {
            UserDefaults.standard.set(data, forKey: Keys.relays)
        }
    }
}

private extension Int {
    func nonZeroOr(_ fallback: Int) -> Int {
        self == 0 ? fallback : self
    }
}
