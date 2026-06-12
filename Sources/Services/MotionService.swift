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

    /// How far back to look for a recent activity sample when seeding the initial
    /// stationary state on `startMonitoring()`. `CMMotionActivityManager` is
    /// edge-triggered, so a device that is already still at launch never receives a
    /// callback; the seed reads recent history instead of waiting for a transition.
    static let initialStateQueryWindowSeconds: TimeInterval = 120

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
        seedInitialStationaryState()
        WhistleLogger.location.info("Motion activity monitoring started")
    }

    /// Seed `isStationary` from recent motion history so we don't wait for an
    /// activity *transition* that may never arrive. `CMMotionActivityManager`
    /// only fires `startActivityUpdates` callbacks on a change — open the app
    /// while already still and no callback comes, leaving `isStationary` stuck at
    /// false until something forces a transition (previously only a pause/unpause
    /// restart did). Querying the recent history gives us the current state up
    /// front. Only ever *sets* stationary; never clears a live-detected state.
    private func seedInitialStationaryState() {
        let now = Date()
        let start = now.addingTimeInterval(-Self.initialStateQueryWindowSeconds)
        manager.queryActivityStarting(from: start, to: now, to: .main) { [weak self] activities, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Don't override state a live callback has already established
                // (e.g. movement detected while the query was in flight).
                guard !self.isStationary, self.movingStartDate == nil else { return }
                guard let latest = activities?.last(where: { $0.confidence != .low }) else { return }
                if latest.stationary {
                    self.isStationary = true
                    WhistleLogger.location.info("Motion state: stationary (seeded from history)")
                }
            }
        }
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
