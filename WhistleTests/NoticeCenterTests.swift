import XCTest
@testable import Whistle

/// The toast/banner split is mostly presentation, but the banner dismissal
/// rules are real logic: a dismissed banner must stay dismissed while the
/// condition holds, and must come back if the condition recurs. Getting that
/// wrong either nags the user forever or hides a degraded state permanently.
@MainActor
final class NoticeCenterTests: XCTestCase {

    private var notices: NoticeCenter!

    override func setUp() {
        super.setUp()
        notices = NoticeCenter()
    }

    override func tearDown() {
        notices = nil
        super.tearDown()
    }

    // MARK: - Toasts

    func testToastsQueueRatherThanReplace() {
        notices.postToast("first")
        notices.postToast("second")
        XCTAssertEqual(notices.toasts.map(\.message), ["first", "second"])
    }

    func testDismissingOneToastLeavesTheOthers() throws {
        notices.postToast("first")
        notices.postToast("second")
        let first = try XCTUnwrap(notices.toasts.first)

        notices.dismissToast(first.id)

        XCTAssertEqual(notices.toasts.map(\.message), ["second"])
    }

    func testToastRetainsItsRetryAction() async throws {
        var retried = false
        notices.postToast("send failed") { retried = true }
        let toast = try XCTUnwrap(notices.toasts.first)
        let retry = try XCTUnwrap(toast.retry)

        await retry()

        XCTAssertTrue(retried)
    }

    func testToastWithoutRetryHasNone() throws {
        notices.postToast("nothing to repeat")
        XCTAssertNil(try XCTUnwrap(notices.toasts.first).retry)
    }

    // MARK: - Banners

    func testBannerForTheSameCauseReplacesRatherThanStacks() {
        notices.post(.init(cause: .relayUnusable, message: "one relay unusable"))
        notices.post(.init(cause: .relayUnusable, message: "two relays unusable"))

        XCTAssertEqual(notices.banners.count, 1)
        XCTAssertEqual(notices.banners.first?.message, "two relays unusable")
    }

    func testDifferentCausesCoexist() {
        notices.post(.init(cause: .relayUnusable, message: "relay"))
        notices.post(.init(cause: .accountSetupIncomplete, message: "setup"))
        XCTAssertEqual(Set(notices.banners.map(\.cause)), [.relayUnusable, .accountSetupIncomplete])
    }

    /// The reason dismissal is tracked per cause: banners are re-posted by
    /// polled state, so without this a dismissed banner reappears on the very
    /// next poll and the dismiss button does nothing.
    func testADismissedBannerIsNotRepostedWhileTheConditionHolds() {
        notices.post(.init(cause: .accountSetupIncomplete, message: "setup"))
        notices.dismissBanner(.accountSetupIncomplete)

        notices.post(.init(cause: .accountSetupIncomplete, message: "setup"))

        XCTAssertTrue(notices.banners.isEmpty, "dismissing did not suppress the re-post")
    }

    /// And the reason `clear` forgets the dismissal: a condition that resolves
    /// and later recurs is new information, so it must be shown again.
    func testAResolvedThenRecurringConditionIsShownAgain() {
        notices.post(.init(cause: .groupNeedsRepair, message: "repair"))
        notices.dismissBanner(.groupNeedsRepair)
        notices.clear(.groupNeedsRepair)

        notices.post(.init(cause: .groupNeedsRepair, message: "repair"))

        XCTAssertEqual(notices.banners.map(\.cause), [.groupNeedsRepair])
    }

    func testClearRemovesAnUndismissedBanner() {
        notices.post(.init(cause: .startupFailed, message: "failed"))
        notices.clear(.startupFailed)
        XCTAssertTrue(notices.banners.isEmpty)
    }

    // MARK: - setBanner

    func testSetBannerPostsWhenActiveAndClearsWhenNot() {
        notices.setBanner(
            .accountSetupIncomplete,
            active: true,
            message: .init(cause: .accountSetupIncomplete, message: "publishing")
        )
        XCTAssertEqual(notices.banners.count, 1)

        notices.setBanner(
            .accountSetupIncomplete,
            active: false,
            message: .init(cause: .accountSetupIncomplete, message: "publishing")
        )
        XCTAssertTrue(notices.banners.isEmpty)
    }

    /// `setBanner(active: false)` goes through `clear`, so it must also reset a
    /// dismissal — otherwise a condition that resolves while dismissed stays
    /// permanently suppressed and the next occurrence is invisible.
    func testSetBannerGoingInactiveResetsADismissal() {
        notices.setBanner(
            .relayUnusable,
            active: true,
            message: .init(cause: .relayUnusable, message: "unusable")
        )
        notices.dismissBanner(.relayUnusable)
        notices.setBanner(
            .relayUnusable,
            active: false,
            message: .init(cause: .relayUnusable, message: "unusable")
        )

        notices.setBanner(
            .relayUnusable,
            active: true,
            message: .init(cause: .relayUnusable, message: "unusable again")
        )

        XCTAssertEqual(notices.banners.first?.message, "unusable again")
    }
}

// MARK: - Tier routing

/// `report` decides *which tier* a failure belongs in, and that decision is
/// the whole point of having two. These pin the three cases that are easy to
/// get wrong.
@MainActor
final class NoticeCenterRoutingTests: XCTestCase {

    private var notices: NoticeCenter!

    override func setUp() {
        super.setUp()
        notices = NoticeCenter()
    }

    override func tearDown() {
        notices = nil
        super.tearDown()
    }

    /// A group needing repair stays broken until an admin re-admits the
    /// member, so it must not be a toast that disappears while that holds.
    func testGroupNeedsRepairBecomesABannerNotAToast() {
        notices.report(MarmotKitService.ServiceError.groupNeedsRepair, fallback: "unused") {}

        XCTAssertEqual(notices.banners.map(\.cause), [.groupNeedsRepair])
        XCTAssertTrue(notices.toasts.isEmpty)
    }

    /// Advice gets no Retry even when the caller offers one, because repeating
    /// it fails identically.
    func testAdviceDropsTheRetryTheCallerOffered() throws {
        notices.report(MarmotKitService.ServiceError.lastAdminCannotLeave, fallback: "unused") {}

        let toast = try XCTUnwrap(notices.toasts.first)
        XCTAssertNil(toast.retry, "advice should not offer a retry")
        XCTAssertEqual(toast.message, MarmotKitService.ServiceError.lastAdminCannotLeave.errorDescription)
    }

    /// A genuinely transient failure keeps its Retry.
    func testTransientFailureKeepsItsRetry() throws {
        notices.report(MarmotKitService.ServiceError.sendQueueFull, fallback: "unused") {}
        XCTAssertNotNil(try XCTUnwrap(notices.toasts.first).retry)
    }

    /// A non-service error falls back to the caller's wording rather than
    /// leaking a raw debug description into the UI.
    func testUnknownErrorUsesTheCallersFallback() throws {
        struct Opaque: Error {}
        notices.report(Opaque(), fallback: "Couldn't do the thing.")
        XCTAssertEqual(try XCTUnwrap(notices.toasts.first).message, "Couldn't do the thing.")
    }
}
