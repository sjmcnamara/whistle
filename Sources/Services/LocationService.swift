import Foundation
import CoreLocation
import UIKit

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

    /// Multiplier applied to `intervalSeconds` when motion-adaptive mode is active
    /// and the device is stationary. Set by AppViewModel from MotionService.
    var motionMultiplier: Double = 1.0

    /// `intervalSeconds × motionMultiplier`, rounded to seconds.
    ///
    /// Reflects the current actual publish cadence — what we'd report in
    /// `LocationPayload.interval` so receivers grade staleness against the
    /// real cadence, not the user's configured value. Stationary device on a
    /// 10s setting → 40s here.
    var effectiveIntervalSeconds: Int {
        Self.effectiveIntervalSeconds(configured: intervalSeconds, multiplier: motionMultiplier)
    }

    /// Pure helper for the cadence formula — exposed for unit tests.
    /// `nonisolated` so test code can call it off the main actor.
    nonisolated static func effectiveIntervalSeconds(configured: Int, multiplier: Double) -> Int {
        Int((Double(configured) * multiplier).rounded())
    }

    // MARK: - Private state

    private let manager = CLLocationManager()

    /// Timestamp of the last callback invocation — used for throttling.
    /// Internal (not private) so `AppViewModel` can derive `nextFireDate`.
    var lastFireDate: Date?

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
            WhistleLogger.location.info("startUpdating: not authorized (status=\(self.authorizationStatus.rawValue)) — deferring")
            return
        }

        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
        isUpdating = true
        WhistleLogger.location.info("CLLocationManager started (interval=\(self.intervalSeconds)s)")
    }

    /// Stop all location monitoring.
    func stopUpdating() {
        wantsUpdating = false
        guard isUpdating else { return }
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        isUpdating = false
        lastFireDate = nil
        WhistleLogger.location.info("Location updates stopped")
    }

    // MARK: - Throttling

    /// Clear the last-fire timestamp so the next location update fires
    /// immediately. Called when the user changes the update interval so a
    /// shorter interval takes effect without waiting for the old one to elapse.
    func resetThrottle() {
        lastFireDate = nil
    }

    /// Returns `true` if enough time has elapsed since the last callback.
    /// Accounts for `motionMultiplier` when motion-adaptive mode is active.
    /// A pending force-fire (set by `requestImmediateUpdate()`) bypasses the
    /// interval entirely — the manual "whistle" ignores timer, backoff, and
    /// motion-aware state by design.
    private func shouldFire() -> Bool {
        if forceNextFire { return true }
        guard let last = lastFireDate else { return true }
        return Date().timeIntervalSince(last) >= TimeInterval(intervalSeconds) * motionMultiplier
    }

    /// Test-only shim so unit tests can exercise shouldFire() without CLLocation callbacks.
    func testShouldFire() -> Bool { shouldFire() }

    // MARK: - Manual whistle

    /// Set by `requestImmediateUpdate()`; consumed by the next fire. Lets a
    /// manual update bypass the throttle exactly once.
    private var forceNextFire = false

    /// Force a single location publish now, ignoring the throttle/backoff.
    ///
    /// When updates are already running we fire the freshest fix CoreLocation
    /// holds immediately (continuous updates keep it current) and also arm
    /// `forceNextFire` so the next incoming fix bypasses the throttle once.
    /// When paused/stopped we issue a one-shot `requestLocation()` for a fresh
    /// fix; `didFailWithError` falls back to the last known fix.
    func requestImmediateUpdate() {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            WhistleLogger.location.info("requestImmediateUpdate: not authorized — ignoring")
            return
        }
        forceNextFire = true
        if isUpdating, let fix = manager.location, fix.horizontalAccuracy >= 0 {
            WhistleLogger.location.info("Manual whistle: firing freshest fix immediately")
            fire(fix)
        } else {
            WhistleLogger.location.info("Manual whistle: requesting one-shot fix")
            manager.requestLocation()
        }
    }

    /// Commit a fix: stamp the throttle, clear any pending force, deliver it.
    private func fire(_ location: CLLocation) {
        lastFireDate = Date()
        forceNextFire = false
        onLocationUpdate?(location)
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
                WhistleLogger.location.info("Auth granted — starting deferred location updates")
                self.manager.startUpdatingLocation()
                self.manager.startMonitoringSignificantLocationChanges()
                self.isUpdating = true
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            let isForeground = UIApplication.shared.applicationState == .active
            let mode = isForeground ? "foreground" : "background"

            // Negative accuracy means CoreLocation has no valid fix — skip.
            guard location.horizontalAccuracy >= 0 else {
                WhistleLogger.location.debug("didUpdateLocations: invalid fix (acc=\(location.horizontalAccuracy)) — skipping")
                return
            }
            guard self.shouldFire() else {
                WhistleLogger.location.debug("didUpdateLocations (\(mode)) throttled — count=\(locations.count)")
                return
            }
            WhistleLogger.location.info("didUpdateLocations (\(mode)) firing — count=\(locations.count) acc=\(String(format: "%.0f", location.horizontalAccuracy))m")
            self.fire(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            WhistleLogger.location.error("Location error: \(error.localizedDescription)")
            // A one-shot whistle request that failed still wants to publish —
            // fall back to the last known fix so the manual update isn't lost.
            if self.forceNextFire, let fix = manager.location, fix.horizontalAccuracy >= 0 {
                WhistleLogger.location.info("Manual whistle: one-shot failed, firing last known fix")
                self.fire(fix)
            }
        }
    }
}
