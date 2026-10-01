import XCTest
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

        let members = try await alice.members(ofGroup: groupId)
        XCTAssertTrue(
            members.contains(bobRef),
            "Bob absent from the group after invite — members: \(members), relay stored \(relay.storedEvents.count) event(s) of kinds \(Set(relay.storedEvents.map(\.kind)).sorted())"
        )
    }
}
