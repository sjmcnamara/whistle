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

    /// One-shot debounce that flips `isStationary` to false after
    /// `movingDebounceSeconds` of sustained motion. Necessary because
    /// `CMMotionActivityManager` is edge-triggered — it delivers a callback when
    /// the activity *changes*, not continuously — so during steady walking we
    /// may receive only the initial "walking" callback and never a second one to
    /// re-evaluate the elapsed time. Cancelled the moment a stationary reading
    /// arrives.
    private var movingDebounceTask: Task<Void, Never>?

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
                    // Stationary: apply immediately, clear moving streak + any
                    // pending debounce.
                    self.movingStartDate = nil
                    self.movingDebounceTask?.cancel()
                    self.movingDebounceTask = nil
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

                    // Already moving, or already counting toward the debounce —
                    // nothing to (re)schedule. The timer below owns the flip.
                    guard self.isStationary, self.movingStartDate == nil else { return }

                    self.movingStartDate = Date()
                    self.scheduleMovingDebounce()
                }
            }
        }
        WhistleLogger.location.info("Motion activity monitoring started")
    }

    /// Arms the one-shot debounce: after `movingDebounceSeconds`, if the moving
    /// streak is still intact (no stationary reading has cleared `movingStartDate`)
    /// and we're still flagged stationary, commit to "moving". Driven by a timer
    /// rather than a follow-up activity callback, which may never arrive during
    /// sustained motion.
    private func scheduleMovingDebounce() {
        movingDebounceTask?.cancel()
        movingDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.movingDebounceSeconds))
            guard let self, !Task.isCancelled else { return }
            guard self.movingStartDate != nil, self.isStationary else { return }
            self.isStationary = false
            self.movingDebounceTask = nil
            WhistleLogger.location.info("Motion state: moving (after \(Int(Self.movingDebounceSeconds))s debounce)")
        }
    }

    func stopMonitoring() {
        manager.stopActivityUpdates()
        movingDebounceTask?.cancel()
        movingDebounceTask = nil
        movingStartDate = nil
        isStationary = false
    }
}
