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

    /// Whether the caller has asked us to be updating. When `true` but
    /// `isUpdating` is `false`, we're waiting for authorization.
    private var wantsUpdating: Bool = false

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
    ///
    /// If authorization has not been granted yet, this records the intent
    /// so that updates start automatically once the user grants permission.
    func startUpdating() {
        wantsUpdating = true

        guard !isUpdating else { return }

        // Only actually start CLLocationManager if we have permission.
        // Calling startUpdatingLocation() with .notDetermined silently
        // does nothing on iOS 17+ — no callbacks, no errors.
        guard authorizationStatus == .authorizedWhenInUse ||
              authorizationStatus == .authorizedAlways else {
            FMFLogger.location.info("startUpdating: not authorized (status=\(self.authorizationStatus.rawValue)) — deferring")
            return
        }

        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
        isUpdating = true
        FMFLogger.location.info("CLLocationManager started (interval=\(self.intervalSeconds)s)")
    }

    /// Stop all location monitoring.
    func stopUpdating() {
        wantsUpdating = false
        guard isUpdating else { return }
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        isUpdating = false
        lastFireDate = nil
        FMFLogger.location.info("Location updates stopped")
    }

    // MARK: - Throttling

    /// Clear the last-fire timestamp so the next location update fires
    /// immediately. Called when the user changes the update interval so a
    /// shorter interval takes effect without waiting for the old one to elapse.
    func resetThrottle() {
        lastFireDate = nil
    }

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

            // If we were waiting for authorization and it's now granted,
            // start the location updates we previously deferred.
            let isAuthorized = status == .authorizedWhenInUse || status == .authorizedAlways
            if isAuthorized && self.wantsUpdating && !self.isUpdating {
                FMFLogger.location.info("Auth granted — starting deferred location updates")
                self.manager.startUpdatingLocation()
                self.manager.startMonitoringSignificantLocationChanges()
                self.isUpdating = true
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            guard self.shouldFire() else { return }
            self.lastFireDate = Date()
            self.onLocationUpdate?(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            FMFLogger.location.error("Location error: \(error.localizedDescription)")
        }
    }
}
