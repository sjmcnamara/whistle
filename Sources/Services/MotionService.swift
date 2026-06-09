import CoreMotion
import Combine

/// Monitors device motion activity and publishes whether the device is stationary.
///
/// Used by AppViewModel to scale the location publish interval: when stationary
/// the interval multiplies by `stationaryMultiplier` (4×) to save battery.
/// Activity updates require Motion & Fitness authorization (automatically
/// requested on first use; no explicit prompt needed on iOS 16+).
@MainActor
final class MotionService: ObservableObject {

    static let stationaryMultiplier: Double = 4.0

    /// Seconds of consecutive non-stationary readings required before declaring
    /// the device moving. Prevents brief vibration/noise from oscillating the
    /// multiplier and nullifying the 4× backoff.
    static let movingDebounceSeconds: TimeInterval = 30

    /// True when CMMotionActivityManager reports stationary with medium/high confidence.
    @Published private(set) var isStationary: Bool = false

    private let manager = CMMotionActivityManager()

    /// Timestamp of the first consecutive non-stationary reading in the current run.
    /// Nil when stationary or when no non-stationary reading has been seen yet.
    private var movingStartDate: Date?

    func startMonitoring() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            WhistleLogger.location.info("CMMotionActivityManager not available on this device")
            return
        }
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity, activity.confidence != .low else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if activity.stationary {
                    // Stationary: apply immediately, clear moving streak.
                    self.movingStartDate = nil
                    if !self.isStationary {
                        self.isStationary = true
                        WhistleLogger.location.info("Motion state: stationary")
                    }
                } else {
                    // Only count confirmed movement types toward the debounce.
                    // "Unknown" activity (stationary=false but no specific type)
                    // is GPS/vibration noise — ignoring it prevents the 30s debounce
                    // window from expiring on a physically-still device.
                    let definitelyMoving = activity.walking || activity.running
                        || activity.automotive || activity.cycling
                    guard definitelyMoving else { return }

                    if self.movingStartDate == nil {
                        self.movingStartDate = Date()
                    }
                    // Only commit to "moving" after sustained confirmed movement.
                    let elapsed = Date().timeIntervalSince(self.movingStartDate!)
                    if self.isStationary && elapsed >= Self.movingDebounceSeconds {
                        self.isStationary = false
                        WhistleLogger.location.info("Motion state: moving (after \(Int(elapsed))s debounce)")
                    }
                }
            }
        }
        WhistleLogger.location.info("Motion activity monitoring started")
    }

    func stopMonitoring() {
        manager.stopActivityUpdates()
        movingStartDate = nil
        isStationary = false
    }
}
