import Foundation

/// Tracks consecutive MLS processing failures per group to detect
/// permanently broken epoch state.
///
/// Not persisted — resets on app launch (a fresh start should clear
/// transient failures from the previous session).
@MainActor
final class GroupHealthTracker: ObservableObject {

    /// Number of consecutive failures before a group is considered unhealthy.
    static let failureThreshold = 5

    /// Groups that have exceeded the failure threshold.
    @Published private(set) var unhealthyGroupIds: Set<String> = []

    private var failureCounts: [String: Int] = [:]

    /// Counts of MLS failures by *type*, independent of any specific group.
    ///
    /// Exists for failure modes that carry no group id at the FFI boundary —
    /// MDK's `.previouslyFailed` result (a message it has permanently given
    /// up on) is the motivating case: it can't feed `failureCounts` above, so
    /// without this it was recorded nowhere and a permanently-stuck group kept
    /// reporting `healthy: true`. Surfaced in `DiagnosticsReport.recentFailures`.
    private var failureTypeCounts: [String: Int] = [:]

    /// Well-known values for `recordFailureType`, kept together so
    /// `DiagnosticsReport.recentFailures` entries are spelled consistently.
    enum FailureType {
        static let previouslyFailed = "previouslyFailed"
        static let unprocessable = "unprocessable"
    }

    // MARK: - Recording

    /// Record a processing failure for a group.
    /// - Returns: `true` if the group has reached the unhealthy threshold.
    @discardableResult
    func recordFailure(groupId: String) -> Bool {
        let count = (failureCounts[groupId] ?? 0) + 1
        failureCounts[groupId] = count

        if count >= Self.failureThreshold {
            unhealthyGroupIds.insert(groupId)
            WhistleLogger.marmot.warning("Group \(groupId) marked unhealthy after \(count) consecutive failures")
            return true
        }
        return false
    }

    /// Record a successful event processing — resets the failure count.
    func recordSuccess(groupId: String) {
        let hadFailures = (failureCounts[groupId] ?? 0) > 0
        failureCounts[groupId] = 0
        if unhealthyGroupIds.remove(groupId) != nil {
            WhistleLogger.marmot.info("Group \(groupId) recovered — removed from unhealthy set")
        } else if hadFailures {
            WhistleLogger.marmot.debug("Group \(groupId) failure count reset after success")
        }
    }

    /// Check whether a group is currently unhealthy.
    func isUnhealthy(groupId: String) -> Bool {
        unhealthyGroupIds.contains(groupId)
    }

    /// Current failure count for a group (exposed for testing).
    func failureCount(for groupId: String) -> Int {
        failureCounts[groupId] ?? 0
    }

    /// Record an MLS failure by type, when no group id is available to
    /// attribute it to (see `failureTypeCounts`). Deliberately not touched by
    /// `recordSuccess` — a later unrelated success in the same group must not
    /// erase the fact that MDK permanently gave up on a message.
    func recordFailureType(_ type: String) {
        failureTypeCounts[type, default: 0] += 1
        WhistleLogger.marmot.warning("Recorded unattributed MLS failure: \(type) (total: \(self.failureTypeCounts[type] ?? 0))")
    }

    /// Snapshot of failure-type counts, for `DiagnosticsReport.recentFailures`.
    func failureTypeCountsSnapshot() -> [String: Int] {
        failureTypeCounts
    }
}
