import Foundation
import CoreLocation

/// Wraps `CLLocationManager` with throttling and background-mode support.
///
/// `LocationService` does **not** depend on `MarmotService` — it publishes
/// location updates via its `onLocationUpdate` callback.  `AppViewModel`
/// wires the callback to the Marmot publish pipeline.
@MainActor
final class LocationService: NSObject, ObservableObject {

    // MARK: - Public callback

    /// Called (at most once per `intervalSeconds`) with a new location.
    var onLocationUpdate: ((CLLocation) -> Void)?

    // MARK: - Published state

    /// Current authorisation status, exposed so the UI can prompt or show warnings.
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Whether the service is actively requesting location updates.
    @Published private(set) var isUpdating: Bool = false

    // MARK: - Configuration

    /// Minimum seconds between callback invocations. Set by AppViewModel from
    /// `AppSettings.locationIntervalSeconds`.
    var intervalSeconds: Int = 3600

    // MARK: - Private state

    private let manager = CLLocationManager()

    /// Timestamp of the last callback invocation — used for throttling.
    private var lastFireDate: Date?

    // MARK: - Init

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true

        // Seed the published status
        authorizationStatus = manager.authorizationStatus
    }

    // MARK: - Authorisation

    /// Request "When In Use" first. The Settings UI can later request "Always".
    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Request "Always" authorisation for background updates.
    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    // MARK: - Start / Stop

    /// Begin continuous + significant-change monitoring.
    func startUpdating() {
        guard !isUpdating else { return }
        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
        isUpdating = true
        FMFLogger.location.info("Location updates started (interval=\(self.intervalSeconds)s)")
    }

    /// Stop all location monitoring.
    func stopUpdating() {
        guard isUpdating else { return }
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        isUpdating = false
        lastFireDate = nil
        FMFLogger.location.info("Location updates stopped")
    }

    // MARK: - Throttling

    /// Returns `true` if enough time has elapsed since the last callback.
    private func shouldFire() -> Bool {
        guard let last = lastFireDate else { return true }
        return Date().timeIntervalSince(last) >= TimeInterval(intervalSeconds)
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            FMFLogger.location.info("Authorization changed: \(String(describing: status))")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            guard self.shouldFire() else { return }
            self.lastFireDate = Date()
            self.onLocationUpdate?(location)
            FMFLogger.location.debug("Location fired: \(location.coordinate.latitude), \(location.coordinate.longitude)")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            FMFLogger.location.error("Location error: \(error.localizedDescription)")
        }
    }
}
