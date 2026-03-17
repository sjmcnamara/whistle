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

    // MARK: - Recording

    /// Record a processing failure for a group.
    /// - Returns: `true` if the group has reached the unhealthy threshold.
    @discardableResult
    func recordFailure(groupId: String) -> Bool {
        let count = (failureCounts[groupId] ?? 0) + 1
        failureCounts[groupId] = count

        if count >= Self.failureThreshold {
            unhealthyGroupIds.insert(groupId)
            FMFLogger.marmot.warning("Group \(groupId) marked unhealthy after \(count) consecutive failures")
            return true
        }
        return false
    }

    /// Record a successful event processing — resets the failure count.
    func recordSuccess(groupId: String) {
        let hadFailures = (failureCounts[groupId] ?? 0) > 0
        failureCounts[groupId] = 0
        if unhealthyGroupIds.remove(groupId) != nil {
            FMFLogger.marmot.info("Group \(groupId) recovered — removed from unhealthy set")
        } else if hadFailures {
            FMFLogger.marmot.debug("Group \(groupId) failure count reset after success")
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
}
