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

    /// True when CMMotionActivityManager reports stationary with medium/high confidence.
    @Published private(set) var isStationary: Bool = false

    private let manager = CMMotionActivityManager()

    func startMonitoring() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            FMFLogger.location.info("CMMotionActivityManager not available on this device")
            return
        }
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity, activity.confidence != .low else { return }
            Task { @MainActor [weak self] in
                let stationary = activity.stationary
                if self?.isStationary != stationary {
                    self?.isStationary = stationary
                    FMFLogger.location.info("Motion state: \(stationary ? "stationary" : "moving")")
                }
            }
        }
        FMFLogger.location.info("Motion activity monitoring started")
    }

    func stopMonitoring() {
        manager.stopActivityUpdates()
        isStationary = false
    }
}
