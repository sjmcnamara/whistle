import XCTest
import WhistleCore
@testable import Whistle

/// Step 3c groundwork: two independent MarmotKit instances against one relay
/// we control (see `LoopbackRelay`).
///
/// These build up to the real question — whether MarmotKit's own convergence
/// machinery covers what Whistle's v1 stack covers, which is what authorises
/// deleting `GroupHealthTracker`, `catchUpGroup` and the v1.11.2
/// relay-delivery-order buffer. None of that can be asked until two instances
/// can reliably form a shared group here, so this file establishes that first
/// and in order: identity, then group, then join.
///
/// Built incrementally on purpose. The harness relay implements "enough NIP-01
/// that MarmotKit works" and that boundary is unproven — replaceable-event
/// semantics in particular are deliberately absent, and KeyPackage discovery
/// may well need them. Finding out where it stops is the point of these tests,
/// so each asserts one more step than the last rather than asserting a whole
/// flow and leaving the failure ambiguous.
final class MarmotKitTwoDeviceTests: XCTestCase {

    private var relay: LoopbackRelay!
    private var rootPaths: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        relay = try LoopbackRelay()
        try relay.start()
    }

    override func tearDown() {
        relay?.stop()
        relay = nil
        for path in rootPaths { try? FileManager.default.removeItem(atPath: path) }
        rootPaths = []
        super.tearDown()
    }

    /// A MarmotKit instance with its own database and secret store, pointed at
    /// the harness relay. Separate roots are what make these two independent
    /// "devices" rather than one account seen twice.
    @MainActor
    private func makeService() throws -> MarmotKitService {
        let root = NSTemporaryDirectory().appending("marmotkit-2dev-\(UUID().uuidString)")
        rootPaths.append(root)
        return try MarmotKitService(
            rootPath: root,
            relayUrls: [try XCTUnwrap(relay.url)],
            allowLoopback: true,
            secretStore: InMemorySecretStore()
        )
    }

    /// Poll until `condition` holds.
    ///
    /// Anything observed from the *receiving* side here is asynchronous: the
    /// sender's own call returns as soon as its local commit is made and the
    /// publish is accepted, while the peer still has to receive, decrypt and
    /// apply. Asserting once straight after the sender returns tests the
    /// sender's optimism, not convergence — which is exactly how the invite
    /// test below first passed while the invitee could not see the group.
    @MainActor
    private func eventually(
        _ description: String,
        timeout: TimeInterval = 15,
        _ condition: @MainActor () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTFail("timed out after \(Int(timeout))s waiting for: \(description)")
    }

    // MARK: - Step 1: an identity can be created at all

    @MainActor
    func testCreatesAnIdentityAgainstTheHarnessRelay() async throws {
        let service = try makeService()
        let accountRef = try await service.startWithNewIdentity()
        XCTAssertFalse(accountRef.isEmpty)
        XCTAssertEqual(service.currentAccountRef, accountRef)
    }

    // MARK: - Step 2: that identity can create a group

    @MainActor
    func testCreatesAGroupThatAppearsInItsOwnGroupList() async throws {
        let service = try makeService()
        try await service.startWithNewIdentity()

        let groupId = try await service.createGroup(name: "Dublin")
        XCTAssertFalse(groupId.isEmpty)

        let groups = try await service.groups()
        let created = try XCTUnwrap(
            groups.first { $0.mlsGroupId == groupId },
            "created group absent from chatList — groups seen: \(groups.map(\.mlsGroupId))"
        )
        XCTAssertEqual(created.name, "Dublin")
        XCTAssertTrue(created.isActive)
    }

    // MARK: - Step 3: a second instance can be invited into it

    /// The gate for everything in step 3c: without two members there is no
    /// commit sequence to deliver out of order, so none of the convergence
    /// questions can even be posed.
    ///
    /// Expected to be the first place the harness relay's limits show, since
    /// inviting requires the invitee's KeyPackage to be discoverable and the
    /// relay implements no replaceable-event semantics.
    @MainActor
    func testSecondInstanceIsInvitedIntoTheFirstsGroup() async throws {
        let alice = try makeService()
        let bob = try makeService()

        let aliceRef = try await alice.startWithNewIdentity()
        let bobRef = try await bob.startWithNewIdentity()
        XCTAssertNotEqual(aliceRef, bobRef, "two roots must mean two accounts")

        // Identity creation returns at local-ready, so Bob's KeyPackage may
        // not have reached the relay yet. Force it before Alice looks.
        try await bob.publishKeyPackage()

        let groupId = try await alice.createGroup(name: "Dublin")
        try await alice.invite(memberRefs: [bobRef], toGroup: groupId)

        // Alice's own view: her commit added Bob.
        let members = try await alice.members(ofGroup: groupId)
        XCTAssertTrue(
            members.contains(bobRef),
            "Bob absent from Alice's member list — members: \(members), relay stored \(relay.storedEvents.count) event(s) of kinds \(Set(relay.storedEvents.map(\.kind)).sorted())"
        )

        // Bob's own view is the one that actually means "joined". Alice's
        // member list reflects her local commit and says nothing about whether
        // the Welcome ever reached him.
        try await eventually("Bob to see the group he was invited to") {
            try await bob.group(id: groupId) != nil
        }
        let fetched = try await bob.group(id: groupId)
        let bobsGroup = try XCTUnwrap(fetched)
        XCTAssertEqual(bobsGroup.name, "Dublin")
        XCTAssertTrue(bobsGroup.isActive)
    }

    // MARK: - Step 4: does MarmotKit survive out-of-order commit delivery?

    /// The delete-authorisation gate for Whistle's v1.11.2
    /// relay-delivery-order buffer.
    ///
    /// On the v1 stack, a commit applied before the commit it builds on is
    /// marked `.unprocessable` once and then permanently `.previouslyFailed`
    /// on every redelivery, with no retry path — which is exactly why the app
    /// buffers kind-445 events and re-sorts them by `created_at` before
    /// handing them to MDK. If MarmotKit converges here without help, that
    /// buffer can go at step 3d; if it does not, the buffer has to be carried
    /// forward into the v2 stack instead.
    ///
    /// Two group renames produce two epoch-advancing commits. The relay holds
    /// both, then releases them to Bob in reverse order. Alice is the
    /// publisher and is acknowledged normally, so nothing on the sending side
    /// signals that anything was reordered.
    @MainActor
    func testConvergesWhenCommitsArriveOutOfOrder() async throws {
        let alice = try makeService()
        let bob = try makeService()

        try await alice.startWithNewIdentity()
        let bobRef = try await bob.startWithNewIdentity()
        try await bob.publishKeyPackage()

        let groupId = try await alice.createGroup(name: "Dublin")
        try await alice.invite(memberRefs: [bobRef], toGroup: groupId)

        // Bob must be a settled member before the adverse delivery, otherwise
        // this would be testing the join flow rather than convergence.
        try await eventually("Bob to join before delivery is tampered with") {
            try await bob.group(id: groupId) != nil
        }
        let settled = try await bob.group(id: groupId)
        let epochBefore = try XCTUnwrap(settled).epoch

        relay.holdLiveDelivery()
        try await alice.rename(group: groupId, to: "Dublin Two")
        try await alice.rename(group: groupId, to: "Dublin Three")
        XCTAssertGreaterThan(
            relay.heldDeliveryCount, 0,
            "nothing was held, so the reorder below would be a no-op and this test would pass vacuously"
        )

        relay.releaseLiveDelivery(order: .reversed)

        // Converging is asynchronous, and failing to converge is the headline
        // result here — so poll to a generous deadline and report rather than
        // let a slow pass look like a failure.
        var observed: WhistleGroup?
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            observed = try await bob.group(id: groupId)
            if (observed?.epoch ?? 0) > epochBefore, observed?.name == "Dublin Three" { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        let final = try XCTUnwrap(observed, "Bob lost the group entirely")
        XCTAssertEqual(
            final.name, "Dublin Three",
            """
            Bob did not converge on the latest commit after out-of-order delivery \
            (epoch \(epochBefore) -> \(final.epoch)). If this is reproducible, \
            MarmotKit needs the same ordering guard v1.11.2 added and the buffer \
            must be ported forward rather than deleted at step 3d.
            """
        )
        XCTAssertGreaterThan(final.epoch, epochBefore, "epoch never advanced")
    }
}
