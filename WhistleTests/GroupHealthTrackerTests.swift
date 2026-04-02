import XCTest
@testable import Whistle

@MainActor
final class GroupHealthTrackerTests: XCTestCase {

    private var tracker: GroupHealthTracker!

    override func setUp() {
        tracker = GroupHealthTracker()
    }

    func testInitiallyHealthy() {
        XCTAssertFalse(tracker.isUnhealthy(groupId: "group-1"))
        XCTAssertEqual(tracker.failureCount(for: "group-1"), 0)
        XCTAssertTrue(tracker.unhealthyGroupIds.isEmpty)
    }

    func testFailureBelowThreshold() {
        for _ in 0..<(GroupHealthTracker.failureThreshold - 1) {
            let reachedThreshold = tracker.recordFailure(groupId: "group-1")
            XCTAssertFalse(reachedThreshold)
        }
        XCTAssertFalse(tracker.isUnhealthy(groupId: "group-1"))
        XCTAssertEqual(tracker.failureCount(for: "group-1"), GroupHealthTracker.failureThreshold - 1)
    }

    func testFailureAtThresholdMarksUnhealthy() {
        for i in 0..<GroupHealthTracker.failureThreshold {
            let reachedThreshold = tracker.recordFailure(groupId: "group-1")
            if i < GroupHealthTracker.failureThreshold - 1 {
                XCTAssertFalse(reachedThreshold)
            } else {
                XCTAssertTrue(reachedThreshold)
            }
        }
        XCTAssertTrue(tracker.isUnhealthy(groupId: "group-1"))
        XCTAssertTrue(tracker.unhealthyGroupIds.contains("group-1"))
    }

    func testSuccessResetsFailureCount() {
        tracker.recordFailure(groupId: "group-1")
        tracker.recordFailure(groupId: "group-1")
        XCTAssertEqual(tracker.failureCount(for: "group-1"), 2)

        tracker.recordSuccess(groupId: "group-1")
        XCTAssertEqual(tracker.failureCount(for: "group-1"), 0)
        XCTAssertFalse(tracker.isUnhealthy(groupId: "group-1"))
    }

    func testSuccessRemovesFromUnhealthySet() {
        for _ in 0..<GroupHealthTracker.failureThreshold {
            tracker.recordFailure(groupId: "group-1")
        }
        XCTAssertTrue(tracker.isUnhealthy(groupId: "group-1"))

        tracker.recordSuccess(groupId: "group-1")
        XCTAssertFalse(tracker.isUnhealthy(groupId: "group-1"))
        XCTAssertFalse(tracker.unhealthyGroupIds.contains("group-1"))
    }

    func testMultipleGroupsIndependent() {
        // Fail group-1
        for _ in 0..<GroupHealthTracker.failureThreshold {
            tracker.recordFailure(groupId: "group-1")
        }

        // group-2 should still be healthy
        tracker.recordFailure(groupId: "group-2")
        XCTAssertTrue(tracker.isUnhealthy(groupId: "group-1"))
        XCTAssertFalse(tracker.isUnhealthy(groupId: "group-2"))

        // Success on group-1 should not affect group-2
        tracker.recordSuccess(groupId: "group-1")
        XCTAssertFalse(tracker.isUnhealthy(groupId: "group-1"))
        XCTAssertEqual(tracker.failureCount(for: "group-2"), 1)
    }

    func testFailureBeyondThreshold() {
        // Go beyond threshold — should stay unhealthy
        for _ in 0..<(GroupHealthTracker.failureThreshold + 3) {
            tracker.recordFailure(groupId: "group-1")
        }
        XCTAssertTrue(tracker.isUnhealthy(groupId: "group-1"))
        XCTAssertEqual(tracker.failureCount(for: "group-1"), GroupHealthTracker.failureThreshold + 3)
    }
}
