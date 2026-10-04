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

    /// The parts of a simulated device that survive a restart: its database
    /// directory and its secret store. Reusing both is what makes a relaunch
    /// resume the same account instead of creating a second one — the signing
    /// key lives in the store, the account in the database.
    private struct DeviceStorage {
        let rootPath: String
        let secretStore: InMemorySecretStore
    }

    private func makeStorage() -> DeviceStorage {
        let root = NSTemporaryDirectory().appending("marmotkit-2dev-\(UUID().uuidString)")
        rootPaths.append(root)
        return DeviceStorage(rootPath: root, secretStore: InMemorySecretStore())
    }

    /// A MarmotKit instance over the given storage, pointed at the harness
    /// relay. Separate storage is what makes two instances independent
    /// "devices" rather than one account seen twice.
    @MainActor
    private func makeService(on storage: DeviceStorage) throws -> MarmotKitService {
        try MarmotKitService(
            rootPath: storage.rootPath,
            relayUrls: [try XCTUnwrap(relay.url)],
            allowLoopback: true,
            secretStore: storage.secretStore
        )
    }

    @MainActor
    private func makeService() throws -> MarmotKitService {
        try makeService(on: makeStorage())
    }

    /// Alice (group creator and admin) and Bob (invited member), both settled.
    /// Most scenarios below need this as a starting point.
    @MainActor
    private func makePair(
        groupName: String = "Dublin"
    ) async throws -> (alice: MarmotKitService, bob: MarmotKitService, bobRef: String, groupId: String) {
        let alice = try makeService()
        let bob = try makeService()
        try await alice.startWithNewIdentity()
        let bobRef = try await bob.startWithNewIdentity()
        try await bob.publishKeyPackage()

        let groupId = try await alice.createGroup(name: groupName)
        try await alice.invite(memberRefs: [bobRef], toGroup: groupId)
        try await eventually("Bob to converge on the group") {
            try await bob.group(id: groupId) != nil
        }
        return (alice, bob, bobRef, groupId)
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

// MARK: - Step 5: the message round trip

extension MarmotKitTwoDeviceTests {

    /// Closes the last unexercised path in `MarmotKitService`: a custom event
    /// sent by one instance and received, decrypted, by the other.
    ///
    /// This is Whistle's actual payload shape — location and chat ride as
    /// custom events on non-reserved kinds — so it is the single most
    /// load-bearing behaviour of the migration.
    @MainActor
    func testCustomEventSentByOneInstanceReachesTheOther() async throws {
        let pair = try await makePair()

        let stream = try await pair.bob.subscribe(toGroup: pair.groupId)
        let payload = LocationPayload(
            latitude: 53.3498,
            longitude: -6.2603,
            altitude: 20,
            accuracy: 5,
            timestamp: Date()
        )
        try await pair.alice.sendLocation(payload, toGroup: pair.groupId)

        let received = await Self.next(from: stream, timeout: 20)
        let message = try XCTUnwrap(received, "Bob's subscription never yielded Alice's location event")
        XCTAssertEqual(message.kind, MarmotKind.ProtocolV2.location)
        XCTAssertEqual(message.mlsGroupId, pair.groupId)

        let decoded = try LocationPayload.from(jsonString: message.content)
        XCTAssertEqual(decoded.lat, payload.lat, accuracy: 0.0001)
        XCTAssertEqual(decoded.lon, payload.lon, accuracy: 0.0001)
    }

    /// `next()` blocks until a message arrives, so races it against a timeout
    /// rather than hanging the suite when nothing comes.
    private static func next(
        from stream: MarmotKitService.MessageStream,
        timeout seconds: TimeInterval
    ) async -> WhistleMessage? {
        await withTaskGroup(of: WhistleMessage?.self) { group in
            group.addTask { await stream.next() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            // Iterating yields the element type directly; `group.next()` would
            // hand back a double optional needing a flattening coalesce.
            for await value in group {
                group.cancelAll()
                return value
            }
            return nil
        }
    }
}

// MARK: - Step 6: admin rules, typed rather than string-matched

extension MarmotKitTwoDeviceTests {

    /// Authorises deleting v1's error-string parsing.
    ///
    /// `MarmotService.leaveGroup` currently decides what happened by matching
    /// MDK's error *text* — `"last active admin"`, `"only admins can perform
    /// this operation"` — because 0.8 surfaced these untyped. If MarmotKit
    /// raises the typed equivalents, that matching goes away at step 3d.
    @MainActor
    func testSoleAdminCannotLeaveAndSaysWhy() async throws {
        let pair = try await makePair()

        // Alice created the group, so she is its only admin, and Bob is still
        // a member — the exact shape v1 guards against.
        do {
            try await pair.alice.leaveGroup(pair.groupId)
            XCTFail("sole admin was allowed to leave a group that still has members")
        } catch let error as MarmotKitService.ServiceError {
            guard case .lastAdminCannotLeave = error else {
                return XCTFail("expected .lastAdminCannotLeave, got \(error)")
            }
            // The user-facing wording is the contract here: v1 surfaced this
            // same guidance, and losing it would leave the user stuck with no
            // idea that promoting someone first is the way out.
            XCTAssertEqual(
                error.errorDescription,
                "You're the only admin of this group. Promote another member to admin before leaving."
            )
        }
    }

    /// A plain member leaving is the ordinary case and must still work —
    /// otherwise the test above would pass simply because leaving is broken.
    @MainActor
    func testPlainMemberCanLeave() async throws {
        let pair = try await makePair()

        try await pair.bob.leaveGroup(pair.groupId)

        try await eventually("Alice to see Bob leave") {
            let members = try await pair.alice.members(ofGroup: pair.groupId)
            return !members.contains(pair.bobRef)
        }
    }
}

// MARK: - Step 7: what MarmotKit does NOT enforce

extension MarmotKitTwoDeviceTests {

    /// Proves a v1 check must be **kept**, not deleted.
    ///
    /// Whistle treats a `group_avatar` payload as admin-only, and the only
    /// thing enforcing that is a receiver-side check: MLS proves the sender is
    /// a *member*, not an admin, so a modified client could send one anyway.
    /// If MarmotKit accepts a custom event from a non-admin — which it should,
    /// since custom events carry no admin semantics — then
    /// `routeApplicationMessage`'s `isAdmin` check has to survive the
    /// migration intact.
    @MainActor
    func testNonAdminCustomEventIsAcceptedSoTheAppMustCheckAdminItself() async throws {
        let pair = try await makePair()

        let members = try await pair.alice.members(ofGroup: pair.groupId)
        XCTAssertTrue(members.contains(pair.bobRef), "precondition: Bob is a member")
        let group = try await pair.alice.group(id: pair.groupId)
        XCTAssertFalse(
            try XCTUnwrap(group).adminPubkeys.contains(pair.bobRef),
            "precondition: Bob is not an admin"
        )

        let stream = try await pair.alice.subscribe(toGroup: pair.groupId)

        // Bob, a non-admin, sends the admin-only payload shape.
        let groupAvatar = #"{"type":"group_avatar","image":"not-really-an-image"}"#
        try await pair.bob.send(
            content: groupAvatar,
            kind: MarmotKind.ProtocolV2.chat,
            toGroup: pair.groupId
        )

        let received = await Self.next(from: stream, timeout: 20)
        let message = try XCTUnwrap(
            received,
            "MarmotKit dropped a non-admin custom event — if that is reproducible it enforces more than expected"
        )
        XCTAssertEqual(message.senderPubkey, pair.bobRef)
        XCTAssertEqual(message.payloadType, "group_avatar")
        // The point: it arrived. Nothing below the app rejected it, so the
        // receiver-side admin check in routeApplicationMessage is the only
        // thing standing between a modified client and a spoofed group photo.
    }
}

// MARK: - Step 8: catching up after being offline

extension MarmotKitTwoDeviceTests {

    /// Authorises deleting v1's `catchUpGroup` soft resync.
    ///
    /// v1 re-fetches 30 days of kind-445 events by hand when a device may
    /// have missed a commit, because MDK 0.8 offered nothing better. If
    /// MarmotKit picks up a missed commit on relaunch — on its own, or via
    /// `catchUpAccounts` — that hand-rolled lookback can go at step 3d.
    ///
    /// Restart is modelled properly rather than by holding delivery: the
    /// point is a client that was *absent* while the commit sat on the relay,
    /// then reconnected and had to fetch stored events, which is a different
    /// path from late live fan-out.
    @MainActor
    func testPicksUpACommitMissedWhileShutDown() async throws {
        let aliceStorage = makeStorage()
        let bobStorage = makeStorage()

        let alice = try makeService(on: aliceStorage)
        try await alice.startWithNewIdentity()

        // Bob is scoped so he can be released before the restart. Root
        // ownership survives `shutdown` until the handle is dropped, so a
        // second service on the same root would otherwise hit RuntimeBusy.
        let groupId: String
        let bobRef: String
        do {
            let bob = try makeService(on: bobStorage)
            bobRef = try await bob.startWithNewIdentity()
            try await bob.publishKeyPackage()

            groupId = try await alice.createGroup(name: "Dublin")
            try await alice.invite(memberRefs: [bobRef], toGroup: groupId)
            try await eventually("Bob to converge before going offline") {
                try await bob.group(id: groupId) != nil
            }
            await bob.shutdown()
        }

        // Bob is gone; Alice advances the group without him.
        try await alice.rename(group: groupId, to: "Dublin While Away")

        // Bob relaunches on the same storage and signs back in.
        let bobAgain = try makeService(on: bobStorage)
        let resumedRef = try await bobAgain.resumeExistingIdentity()
        XCTAssertEqual(resumedRef, bobRef, "relaunch resumed a different account")

        try await bobAgain.catchUpAccounts()

        try await eventually("Bob to pick up the commit made while he was offline", timeout: 25) {
            try await bobAgain.group(id: groupId)?.name == "Dublin While Away"
        }
    }
}

// MARK: - Step 9: a genuine fork

extension MarmotKitTwoDeviceTests {

    /// Probes what MarmotKit does with a true fork — two commits built on the
    /// same epoch by different members, neither having seen the other.
    ///
    /// This is the case v1 cannot repair: MDK marks such a commit
    /// `.previouslyFailed` permanently, `catchUpGroup` explicitly cannot help,
    /// and only `resyncMember`'s remove-then-re-add rebuilds the member's
    /// leaf. Upstream documents `GroupUnrecoverableRepairRequired` as "halted
    /// until another member re-admits this device", which says MarmotKit
    /// *detects* the state but still needs an admin-driven repair — so
    /// `resyncMember` is expected to survive while `GroupHealthTracker`'s
    /// failure-counting, which only ever guessed at this state, can go.
    ///
    /// Deliberately records what happens rather than asserting a particular
    /// recovery: the useful output is which of the two it is.
    @MainActor
    func testConcurrentCommitsFromTwoAdminsAreReportedNotSilentlyLost() async throws {
        let pair = try await makePair()

        // Both must be admins to issue competing metadata commits.
        try await pair.alice.promoteToAdmin(pair.bobRef, inGroup: pair.groupId)
        try await eventually("Bob to see his own promotion") {
            let group = try await pair.bob.group(id: pair.groupId)
            return group?.adminPubkeys.contains(pair.bobRef) ?? false
        }

        // Neither sees the other's commit before making its own: that is what
        // makes this a fork rather than a sequence.
        relay.holdLiveDelivery()
        try await pair.alice.rename(group: pair.groupId, to: "Alice's Name")
        try await pair.bob.rename(group: pair.groupId, to: "Bob's Name")
        XCTAssertGreaterThan(
            relay.heldDeliveryCount, 0,
            "nothing held, so this would not be a fork and the test would be vacuous"
        )
        relay.releaseLiveDelivery()

        // Let the dust settle, then report the outcome rather than demanding
        // a specific one.
        try? await Task.sleep(nanoseconds: 5_000_000_000)

        let aliceView = try await pair.alice.group(id: pair.groupId)
        let bobView = try await pair.bob.group(id: pair.groupId)

        let summary = """
        fork outcome — \
        alice: name=\(aliceView?.name ?? "<gone>") epoch=\(aliceView?.epoch ?? 0), \
        bob: name=\(bobView?.name ?? "<gone>") epoch=\(bobView?.epoch ?? 0)
        """

        // The one thing that must hold: neither side may silently sit on a
        // stale view believing it is current. Either they converge on one
        // winner, or the group is reported as needing repair — both are
        // actionable. Diverging names with no signal is not.
        let converged = aliceView?.name == bobView?.name && aliceView?.epoch == bobView?.epoch
        if !converged {
            // Not a failure in itself — it is the v1 situation, and means
            // resyncMember must be ported forward. Assert it is at least
            // *detectable* via the send path, which is where MarmotKit raises
            // GroupUnrecoverableRepairRequired.
            var sendOutcome = "send succeeded (no repair signalled)"
            do {
                try await pair.bob.send(
                    content: #"{"type":"chat","text":"probe"}"#,
                    kind: MarmotKind.ProtocolV2.chat,
                    toGroup: pair.groupId
                )
            } catch let error as MarmotKitService.ServiceError {
                sendOutcome = "send threw \(error)"
            }
            XCTFail("\(summary); \(sendOutcome)")
        }
    }
}

// MARK: - Step 10: cursor-based message paging

extension MarmotKitTwoDeviceTests {

    /// Walks the whole history by cursor, asserting the properties that
    /// actually matter: paging terminates, advances, and loses nothing.
    ///
    /// Deliberately *not* asserting that pages never overlap — they can, and
    /// the first version of this test failed for exactly that reason. The
    /// cursor is compound (`timelineAt` + message id) because `timelineAt`
    /// has one-second resolution, but messages sent in quick succession share
    /// a second and the id does not fully separate them. Whistle generates
    /// precisely that pattern: location updates arrive in bursts.
    ///
    /// So the contract a caller must code against is "pages may repeat rows;
    /// dedupe by id" — which v1's ChatViewModel already does, meaning this
    /// would have been invisible in production rather than caught. What must
    /// never happen is a page that fails to advance (an infinite scroll-back
    /// loop) or history that cannot be reached at all.
    @MainActor
    func testPagesThroughWholeHistoryByCursorWithoutStallingOrLosingMessages() async throws {
        let pair = try await makePair()

        let sent = (1...5).map { "message \($0)" }
        for text in sent {
            try await pair.alice.sendChat(ChatPayload(text: text), toGroup: pair.groupId)
        }

        try await eventually("all five sends to reach Alice's own history") {
            let page = try await pair.alice.messages(inGroup: pair.groupId, limit: 50)
            return page.messages.count >= sent.count
        }

        // Walk back two at a time, deduping as a caller must.
        var collected: [String: WhistleMessage] = [:]
        var cursor: WhistleMessage?
        var pages = 0
        let pageLimit = 12   // generous: 5 messages at 2 per page cannot need this many

        while pages < pageLimit {
            pages += 1
            let page = try await pair.alice.messages(
                inGroup: pair.groupId,
                before: cursor,
                limit: 2
            )
            guard let oldest = page.messages.last else { break }

            let before = collected.count
            for message in page.messages { collected[message.id] = message }

            // Progress means either new rows or a moved cursor. Neither
            // changing is a stall, and a caller looping on it would hang.
            let gainedRows = collected.count > before
            let cursorMoved = oldest.id != cursor?.id
            XCTAssertTrue(
                gainedRows || cursorMoved,
                "page \(pages) neither added rows nor advanced the cursor — a caller would loop forever"
            )
            if !page.hasMoreBefore { break }
            if !cursorMoved { break }
            cursor = oldest
        }

        XCTAssertLessThan(pages, pageLimit, "paging did not terminate")

        let texts = Set(collected.values.compactMap { try? ChatPayload.from(jsonString: $0.content).text })
        for text in sent {
            XCTAssertTrue(texts.contains(text), "history lost \(text) — collected: \(texts.sorted())")
        }
    }
}

// MARK: - Step 11: scan to invite

extension MarmotKitTwoDeviceTests {

    /// The whole of the v2 join flow: an admin scans a member's code and
    /// invites them. There is no counterpart direction — protocol v2 has no
    /// out-of-group messaging, so a non-member cannot act on anything.
    @MainActor
    func testAdminInvitesByScannedCode() async throws {
        let alice = try makeService()
        let bob = try makeService()
        try await alice.startWithNewIdentity()
        let bobRef = try await bob.startWithNewIdentity()
        try await bob.publishKeyPackage()

        let groupId = try await alice.createGroup(name: "Dublin")

        // A scanned code resolves to the same account id the API uses, so
        // inviting by code and by ref are the same operation.
        try await alice.invite(scannedCode: bobRef, toGroup: groupId)

        try await eventually("Bob to converge after being invited by code") {
            try await bob.group(id: groupId) != nil
        }
        let members = try await alice.members(ofGroup: groupId)
        XCTAssertTrue(members.contains(bobRef))
    }

    /// A mis-scan must be distinguishable from a relay or permission failure —
    /// those are indistinguishable to a user otherwise, and the fix differs.
    @MainActor
    func testScanningSomethingThatIsNotAMemberCodeFailsClearly() async throws {
        let alice = try makeService()
        try await alice.startWithNewIdentity()
        let groupId = try await alice.createGroup(name: "Dublin")

        for nonsense in ["", "   ", "hello", "https://example.com", "npub1notvalid"] {
            do {
                try await alice.invite(scannedCode: nonsense, toGroup: groupId)
                XCTFail("accepted \(nonsense.isEmpty ? "<empty>" : nonsense) as a member code")
            } catch let error as MarmotKitService.ServiceError {
                guard case .unrecognisedMemberCode = error else {
                    return XCTFail("expected .unrecognisedMemberCode for \(nonsense), got \(error)")
                }
            }
        }
    }

    /// Whitespace around a scanned value must not change the outcome — QR
    /// payloads and pasted text routinely carry a trailing newline.
    @MainActor
    func testScannedCodeToleratesSurroundingWhitespace() async throws {
        let service = try makeService()
        let ref = try await service.startWithNewIdentity()
        XCTAssertEqual(service.normalisedAccountReference("  \(ref)\n"), ref)
    }

    /// A member code is only useful once the KeyPackage has reached a relay.
    /// Showing it earlier yields a code an admin cannot invite, which looks
    /// like a broken scanner rather than a timing problem — so the UI gates
    /// on this in step 3d-iii.
    @MainActor
    func testReadinessReachesNetworkReadyOncePublished() async throws {
        let service = try makeService()
        try await service.startWithNewIdentity()
        try await service.publishKeyPackage()

        try await eventually("account setup to reach networkReady") {
            service.isReadyToBeInvited()
        }
    }
}

// MARK: - Step 12: the identity survives the cutover

extension MarmotKitTwoDeviceTests {

    /// The upgrade path. MarmotKit mints its own keys, so starting a v2
    /// install with `createIdentityWithProfile` would give every existing user
    /// a new npub and orphan them from everyone who knows them. Adopting the
    /// nsec the app already holds is what prevents that.
    @MainActor
    func testAdoptingAnExistingNsecPreservesTheAccountIdentity() async throws {
        // Stand in for a v1 install: an identity that already exists.
        let original = try makeService()
        let originalRef = try await original.startWithNewIdentity()
        let nsec = try original.revealNsec()
        XCTAssertTrue(nsec.hasPrefix("nsec"), "expected a bech32 nsec, got \(nsec.prefix(8))…")

        // A fresh v2 install — separate database and keyring — adopting it.
        let upgraded = try makeService()
        let adoptedRef = try await upgraded.start(adoptingNsec: nsec, expecting: originalRef)

        XCTAssertEqual(
            adoptedRef, originalRef,
            "adopting the nsec produced a different account — users would lose their npub on upgrade"
        )
        XCTAssertEqual(upgraded.myMemberCode(), original.myMemberCode())
    }

    /// Relaunching must resume the adopted account, not onboard a second one.
    ///
    /// The inner scopes are load-bearing, not style: a root is owned until its
    /// `Marmot` handle is *dropped*, and `shutdown()` does not drop it. Holding
    /// the first service in scope while constructing the second on the same
    /// root fails with `RuntimeBusy` — which is the same hazard production
    /// avoids by giving each identity generation its own root.
    @MainActor
    func testRelaunchResumesTheAdoptedAccount() async throws {
        let storage = makeStorage()
        let nsec: String
        let seedRef: String
        do {
            let seed = try makeService()
            seedRef = try await seed.startWithNewIdentity()
            nsec = try seed.revealNsec()
            await seed.shutdown()
        }

        let firstRef: String
        do {
            let first = try makeService(on: storage)
            firstRef = try await first.start(adoptingNsec: nsec, expecting: seedRef)
            await first.shutdown()
        }

        let relaunched = try makeService(on: storage)
        let secondRef = try await relaunched.start(adoptingNsec: nsec, expecting: seedRef)
        XCTAssertEqual(secondRef, firstRef, "relaunch did not resume the adopted account")
    }

    /// Importing a different key must switch identity, not quietly keep the
    /// old one.
    ///
    /// This is the bug the `expecting:` argument exists for. Signing into
    /// `listAccounts().first` looked equivalent and was not: the previous
    /// account is still in MarmotKit's database after an import or a burn, so
    /// the app signed back into the *old* identity — keeping its npub and its
    /// groups — while reporting the import a success. Silent, and it would
    /// have survived any test that only ever used one key.
    @MainActor
    func testImportingADifferentKeyReplacesTheIdentityRatherThanResumingTheOld() async throws {
        let storage = makeStorage()

        let refA: String, nsecA: String, refB: String, nsecB: String
        do {
            let seedA = try makeService()
            refA = try await seedA.startWithNewIdentity()
            nsecA = try seedA.revealNsec()
            await seedA.shutdown()
        }
        do {
            let seedB = try makeService()
            refB = try await seedB.startWithNewIdentity()
            nsecB = try seedB.revealNsec()
            await seedB.shutdown()
        }
        XCTAssertNotEqual(refA, refB)

        do {
            let app = try makeService(on: storage)
            _ = try await app.start(adoptingNsec: nsecA, expecting: refA)
            await app.shutdown()
        }

        // The import: same device storage, a different key, and account A
        // deliberately left in the database — that is the condition under
        // which `listAccounts().first` silently resumed the wrong identity.
        let afterImport = try makeService(on: storage)
        let adopted = try await afterImport.start(adoptingNsec: nsecB, expecting: refB)

        XCTAssertEqual(adopted, refB, "import resumed the previous identity instead of adopting the new key")
        XCTAssertNotEqual(adopted, refA)
    }

    /// An nsec and a reference that disagree must fail loudly. Continuing
    /// would run the app as whoever the nsec belongs to, which is not who the
    /// caller believed it was.
    @MainActor
    func testAdoptingWithAMismatchedReferenceThrows() async throws {
        let nsecA: String, refB: String
        do {
            let seedA = try makeService()
            _ = try await seedA.startWithNewIdentity()
            nsecA = try seedA.revealNsec()
            await seedA.shutdown()
        }
        do {
            let seedB = try makeService()
            refB = try await seedB.startWithNewIdentity()
            await seedB.shutdown()
        }

        let service = try makeService()
        do {
            _ = try await service.start(adoptingNsec: nsecA, expecting: refB)
            XCTFail("expected a mismatch to throw")
        } catch MarmotKitService.ServiceError.identityMismatch {
            // Expected.
        }
    }
}

// MARK: - Diagnostics against a real group

extension MarmotKitTwoDeviceTests {

    /// Moved here from `DiagnosticsCollectorTests`: asserting
    /// `secondsSinceLastEvent` needs an actual group, and under v2 that means
    /// a running MarmotKit account rather than an in-memory MLS service.
    ///
    /// Ground truth is read back from the group itself rather than re-derived,
    /// so this catches the collector reading the wrong timestamp — or a
    /// device-wide one — instead of that group's own.
    @MainActor
    func testDiagnosticsSecondsSinceLastEventMatchesThatGroupsLastMessageAt() async throws {
        let service = try makeService()
        _ = try await service.startWithNewIdentity()
        let groupId = try await service.createGroup(name: "Diagnostics")
        await service.refreshGroups()

        let report = await DiagnosticsCollector.collect(
            marmot: service,
            identity: IdentityService(),
            settings: .shared
        )
        let snapshot = try XCTUnwrap(
            report.groups.first { $0.id == DiagnosticsReport.shortHex(groupId) },
            "collector reported no snapshot for the group that was just created"
        )

        let loaded = try await service.group(id: groupId)
        let group = try XCTUnwrap(loaded)
        if let lastMessageAt = group.lastMessageAt {
            let expected = max(0, Int(Date().timeIntervalSince1970) - Int(lastMessageAt))
            let actual = try XCTUnwrap(snapshot.secondsSinceLastEvent)
            XCTAssertLessThanOrEqual(abs(actual - expected), 2)
        } else {
            // nil must stay nil ("never recorded"), not 0 ("just now").
            XCTAssertNil(snapshot.secondsSinceLastEvent)
        }
    }
}

// MARK: - Relay policy

/// No service instance needed — relay policy is answered before one exists,
/// because startup has to filter the list *before* handing it to the runtime.
final class MarmotKitRelayPolicyTests: XCTestCase {

    /// The regression that broke startup on device. MarmotKit refuses a
    /// retired host at the dial boundary, and a relay-list declaration naming
    /// one fails the whole relay directory fetch rather than just that
    /// endpoint — so a single retired default took the entire launch down with
    /// "relay endpoint host is retired". `wss://relay.damus.io` was the first
    /// entry in the shipped default list.
    func testShippedDefaultRelaysAreAllDialable() {
        let allowed = MarmotKitService.allowedRelayEndpoints(from: AppDefaults.defaultRelays)
        XCTAssertEqual(
            allowed.count, AppDefaults.defaultRelays.count,
            """
            A default relay is not dialable by MarmotKit. Startup filters the \
            list, so the app still launches — but shipping an unusable default \
            means every new install silently loses a relay. \
            defaults=\(AppDefaults.defaultRelays) allowed=\(allowed)
            """
        )
    }

    func testRetiredHostIsFilteredOut() {
        let mixed = ["wss://relay.damus.io"] + AppDefaults.defaultRelays
        let allowed = MarmotKitService.allowedRelayEndpoints(from: mixed)
        XCTAssertFalse(
            allowed.contains { $0.contains("relay.damus.io") },
            "retired host survived filtering — this is what fails the relay directory fetch"
        )
        // The usable ones must come through untouched: dropping a retired host
        // must not cost the account every other relay it had.
        XCTAssertEqual(allowed.count, AppDefaults.defaultRelays.count)
    }

    func testEmptyInputYieldsEmptyOutput() {
        XCTAssertEqual(MarmotKitService.allowedRelayEndpoints(from: []), [])
    }
}

// MARK: - Root path

final class MarmotKitRootPathTests: XCTestCase {

    /// The device failure this exists for: MarmotKit opens its root as a
    /// "complete authorized directory path" and rejects any symlink in it with
    /// `ELOOP` (os error 62). On iOS `/var` is a symlink to `/private/var`,
    /// and `FileManager.urls(for:in:)` returns the unresolved form — so
    /// startup failed with an I/O error naming the leaf directory, which reads
    /// like the leaf is broken rather than the prefix.
    ///
    /// The simulator's container is not under a symlinked prefix, so this
    /// cannot reproduce the device path. What it *can* pin is the invariant
    /// that was violated: the path handed to MarmotKit must already equal its
    /// own fully-resolved form.
    func testRootPathIsFullySymlinkResolved() throws {
        let path = try MarmotKitService.defaultRootPath()
        XCTAssertEqual(
            MarmotKitService.fullyResolved(path), path,
            "root path contains an unresolved symlink — MarmotKit rejects these with ELOOP"
        )
    }

    /// The trap that made the first attempt at the device fix a no-op:
    /// `resolvingSymlinksInPath()` resolves `/var` to `/private/var`, and then
    /// reading `.path` back off the result standardizes `/private` away again.
    /// Asserted on a real symlink so it holds wherever the test runs, rather
    /// than depending on the host having a `/var` symlink.
    func testFoundationRoundTripDoesNotResolveWhereRealpathDoes() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resolve-\(UUID().uuidString)", isDirectory: true)
        let target = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let viaRealpath = MarmotKitService.fullyResolved(link.path)
        XCTAssertEqual(
            viaRealpath, MarmotKitService.fullyResolved(target.path),
            "realpath must resolve the link to its target"
        )
        XCTAssertFalse(
            viaRealpath.hasSuffix("/link"),
            "resolved path still points at the symlink — MarmotKit would reject it with ELOOP"
        )
    }

    func testRootPathExistsAsADirectory() throws {
        let path = try MarmotKitService.defaultRootPath()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// Advancing is what makes identity replacement safe from `RuntimeBusy`,
    /// so a new generation must genuinely be a different directory.
    func testAdvancingGenerationYieldsADifferentRoot() throws {
        let before = try MarmotKitService.defaultRootPath()
        MarmotKitService.advanceIdentityGeneration()
        let after = try MarmotKitService.defaultRootPath()
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(
            URL(fileURLWithPath: after).resolvingSymlinksInPath().path, after,
            "a new generation must be as symlink-free as the first"
        )
    }

    /// The previous generation is deleted at launch, when nothing can still
    /// hold it — otherwise every import or burn leaves a database behind.
    func testSupersededGenerationIsPurgedOnNextResolve() throws {
        let stale = try MarmotKitService.defaultRootPath()
        FileManager.default.createFile(atPath: stale + "/marker", contents: nil)
        MarmotKitService.advanceIdentityGeneration()

        // Resolving the new generation is what sweeps the old one.
        _ = try MarmotKitService.defaultRootPath()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stale),
            "superseded generation survived — identity replacement would accumulate databases"
        )
    }
}

// MARK: - Does MarmotKit actually reject a symlinked root?

/// The experiment that should have been run before any fix was pushed.
///
/// The device failure was `Io("open complete authorized directory path at
/// /var/mobile/…: Too many levels of symbolic links (os error 62)")`, and the
/// diagnosis — that MarmotKit refuses a symlink anywhere in its root path —
/// was inferred from the message rather than tested. It is testable locally:
/// point a runtime at a root reached through a symlink and see what happens.
/// `/var` on iOS is just one instance of that.
final class MarmotKitSymlinkedRootTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("symlink-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        base = nil
    }

    @MainActor
    func testRootReachedThroughASymlinkIsRejected() throws {
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // The unresolved path — the shape the device was given.
        do {
            _ = try MarmotKitService(
                rootPath: link.path,
                relayUrls: [],
                secretStore: InMemorySecretStore()
            )
            XCTFail(
                """
                MarmotKit accepted a symlinked root. The device ELOOP therefore has \
                some other cause, and `fullyResolved` is not the fix.
                """
            )
        } catch {
            // Confirms the diagnosis. Recorded in the message so a future
            // reader sees the evidence rather than the inference.
            XCTAssertTrue(
                "\(error)".contains("symbolic link") || "\(error)".contains("os error 62"),
                "rejected, but not for the reason assumed — got: \(error)"
            )
        }
    }

    /// The other half: the same root, resolved, must be accepted. Without this
    /// the test above only proves symlinks are rejected, not that resolving
    /// them is sufficient.
    @MainActor
    func testSameRootResolvedIsAccepted() throws {
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let resolved = MarmotKitService.fullyResolved(link.path)
        XCTAssertFalse(resolved.hasSuffix("/link"), "realpath did not see through the symlink")

        _ = try MarmotKitService(
            rootPath: resolved,
            relayUrls: [],
            secretStore: InMemorySecretStore()
        )
    }
}

// MARK: - Account setup completion

extension MarmotKitTwoDeviceTests {

    /// Why "my member code" failed on device with `OnboardingRequired` while
    /// every test passed: the tests reached an account through
    /// `startWithNewIdentity`, the app reaches it through
    /// `start(adoptingNsec:)`, and nothing asserted the adopt path got past
    /// identity creation.
    ///
    /// Asserts `.networkReady` outright rather than comparing against the
    /// create path. Measured: the two genuinely end in different states —
    /// `startWithNewIdentity` settles at `localReady` with no onboarding
    /// session at all, while the adopt path runs the onboarding machine
    /// through to `networkReady`. Comparing them was the wrong test, and it
    /// failed for the opposite of the reason it was written for.
    @MainActor
    func testAdoptedAccountReachesNetworkReady() async throws {
        let nsec: String, ref: String
        do {
            let seed = try makeService()
            ref = try await seed.startWithNewIdentity()
            nsec = try seed.revealNsec()
            await seed.shutdown()
        }

        let adopted = try makeService()
        _ = try await adopted.start(adoptingNsec: nsec, expecting: ref)
        XCTAssertEqual(
            try adopted.setupReadiness(), .initializing,
            "adopt is expected to stop short of publication — that is what makes launch fast"
        )

        let readiness = try await adopted.completeAccountSetup()
        XCTAssertEqual(
            readiness, .networkReady,
            """
            account setup did not complete. Onboarding is a sequential machine that             blocks on caller input — a single `runOnboarding` stalls on `profile` and             every later step stays pending behind it.
            """
        )
    }

    /// Diagnostic, not an assertion of desired behaviour: dumps the onboarding
    /// state machine so the steps that actually stall are visible instead of
    /// guessed at. Onboarding steps can sit at `needsInput` awaiting a caller
    /// action, and `runOnboarding` advances past only what it can decide
    /// itself.
    @MainActor
    func testDumpsOnboardingStateForAnAdoptedAccount() async throws {
        let nsec: String, ref: String
        do {
            let seed = try makeService()
            ref = try await seed.startWithNewIdentity()
            nsec = try seed.revealNsec()
            await seed.shutdown()
        }

        let service = try makeService()
        _ = try await service.start(adoptingNsec: nsec, expecting: ref)
        print("ONBOARD-DIAG readiness after adopt: \(try service.setupReadiness())")
        for line in try service.onboardingDiagnostics() { print("ONBOARD-DIAG \(line)") }

        _ = try? await service.completeAccountSetup()
        print("ONBOARD-DIAG readiness after runOnboarding: \(try service.setupReadiness())")
        for line in try service.onboardingDiagnostics() { print("ONBOARD-DIAG \(line)") }
    }

    /// The specific operation that failed on device. It needs a published
    /// account, so it is the sharpest check that setup actually completed.
    @MainActor
    func testKeyPackageRotationWorksOnAnAdoptedAccount() async throws {
        let nsec: String, ref: String
        do {
            let seed = try makeService()
            ref = try await seed.startWithNewIdentity()
            nsec = try seed.revealNsec()
            await seed.shutdown()
        }

        let service = try makeService()
        _ = try await service.start(adoptingNsec: nsec, expecting: ref)
        try await service.completeAccountSetup()

        // Before the fix this threw `OnboardingRequired`.
        _ = try await service.publishKeyPackage()
    }

    /// Completing twice must be harmless — it runs on every launch.
    @MainActor
    func testCompletingSetupTwiceIsIdempotent() async throws {
        let service = try makeService()
        _ = try await service.startWithNewIdentity()
        let first = try await service.completeAccountSetup()
        let second = try await service.completeAccountSetup()
        XCTAssertEqual(first, second)
    }
}

// MARK: - Leaving a group of one

extension MarmotKitTwoDeviceTests {

    /// Reported from device: a group you are alone in could not be left. MLS
    /// cannot remove the last member, so `selfDemoteAdmin` reports
    /// `WouldRemoveLastAdmin` and the app relayed it as "promote another
    /// member to admin before leaving" — impossible advice with nobody to
    /// promote, leaving identity burn as the only escape.
    @MainActor
    func testAGroupYouAreAloneInCanBeLeft() async throws {
        let service = try makeService()
        _ = try await service.startWithNewIdentity()
        let groupId = try await service.createGroup(name: "Solo")
        await service.refreshGroups()
        XCTAssertTrue(service.groups.contains { $0.mlsGroupId == groupId })

        try await service.leaveGroup(groupId)

        XCTAssertFalse(
            service.groups.contains { $0.mlsGroupId == groupId },
            "group of one survived being left — the list should no longer show it"
        )
    }

    /// The error must survive where it is still correct: with another member
    /// present, a sole admin genuinely has to hand admin over first.
    @MainActor
    func testSoleAdminOfAPopulatedGroupStillCannotLeave() async throws {
        // `makePair` already creates the group and converges Bob into it.
        let (alice, _, _, groupId) = try await makePair(groupName: "Populated")

        do {
            try await alice.leaveGroup(groupId)
            XCTFail("sole admin of a populated group should not be able to leave")
        } catch MarmotKitService.ServiceError.lastAdminCannotLeave {
            // Correct: there is someone to promote here.
        }
    }
}

// MARK: - Can the dialled relay set change at runtime?

/// Device report: adding a relay in Advanced Settings left the status at
/// "connected (2 of 2)" until the app was restarted, while diagnostics listed
/// three — because diagnostics maps `settings.relays` whereas the status comes
/// from `relayHealth()`, which reflects the pool the runtime was *constructed*
/// with.
///
/// `relayUrls` is init-only; no binding changes it afterwards. The open
/// question is whether `publishRelayLists` — which updates what the account
/// advertises — also causes the runtime to adopt those relays for dialling.
/// Asked here rather than assumed, because the answer decides whether a relay
/// change can take effect live or genuinely needs a relaunch.
final class MarmotKitRuntimeRelaySetTests: XCTestCase {

    private var first: LoopbackRelay!
    private var second: LoopbackRelay!
    private var rootPath: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        first = try LoopbackRelay()
        try first.start()
        second = try LoopbackRelay()
        try second.start()
    }

    override func tearDown() {
        first?.stop(); first = nil
        second?.stop(); second = nil
        if let rootPath { try? FileManager.default.removeItem(atPath: rootPath) }
        rootPath = nil
        super.tearDown()
    }

    @MainActor
    func testPublishingANewRelayListDoesNotChangeTheDialledPool() async throws {
        let root = NSTemporaryDirectory().appending("marmotkit-relayset-\(UUID().uuidString)")
        rootPath = root
        let firstURL = try XCTUnwrap(first.url)
        let secondURL = try XCTUnwrap(second.url)

        let service = try MarmotKitService(
            rootPath: root,
            relayUrls: [firstURL],
            allowLoopback: true,
            secretStore: InMemorySecretStore()
        )
        _ = try await service.startWithNewIdentity()

        await service.refreshRelayStatus(all: [firstURL], enabled: [firstURL])
        let before = service.relayStatus.total
        XCTAssertEqual(before, 1, "expected the pool to be the single relay passed at construction")

        // Advertise both. If the runtime adopts its published default relays
        // for dialling, the pool grows; if not, a relay change needs a new
        // runtime and the UI has to say so.
        try await service.publishRelayLists(defaultRelays: [firstURL, secondURL])

        await service.refreshRelayStatus(all: [firstURL, secondURL], enabled: [firstURL, secondURL])
        let after = service.relayStatus.total
        XCTAssertEqual(
            after, before,
            """
            The dialled pool DID change after publishing a new relay list \
            (\(before) → \(after)). If this fails, a relay added in settings can \
            be applied live and the restart requirement should be removed.
            """
        )
    }
}

// MARK: - Relay settings diff

/// Device report: toggling a relay changed nothing in the status, and exactly
/// one relay showed a permanent "restart to connect". Cause was a comparison
/// between two different spellings — `relayUrls` holds MarmotKit's
/// *normalised* endpoints, settings holds what the user typed — so whichever
/// relay normalised differently never matched.
final class MarmotKitRelayDiffTests: XCTestCase {

    private var relay: LoopbackRelay!
    private var rootPath: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        relay = try LoopbackRelay()
        try relay.start()
    }

    override func tearDown() {
        relay?.stop(); relay = nil
        if let rootPath { try? FileManager.default.removeItem(atPath: rootPath) }
        rootPath = nil
        super.tearDown()
    }

    @MainActor
    private func makeService() throws -> (MarmotKitService, String) {
        let root = NSTemporaryDirectory().appending("marmotkit-diff-\(UUID().uuidString)")
        rootPath = root
        let url = try XCTUnwrap(relay.url)
        let service = try MarmotKitService(
            rootPath: root,
            relayUrls: [url],
            allowLoopback: true,
            secretStore: InMemorySecretStore()
        )
        return (service, url)
    }

    @MainActor
    func testNoPendingChangesWhenSettingsMatchTheDialledPool() async throws {
        let (service, url) = try makeService()
        await service.refreshRelayStatus(all: [url], enabled: [url])
        XCTAssertEqual(service.relayStatus.pendingAdditions, [])
        XCTAssertEqual(service.relayStatus.pendingRemovals, [])
    }

    /// The reported bug: the same relay written differently must not register
    /// as a pending change. A trailing slash and different casing are both
    /// spellings MarmotKit normalises away.
    @MainActor
    func testDifferentSpellingsOfTheSameRelayAreNotPendingChanges() async throws {
        let (service, url) = try makeService()
        for spelling in [url + "/", url.uppercased()] {
            await service.refreshRelayStatus(all: [spelling], enabled: [spelling])
            XCTAssertEqual(
                service.relayStatus.pendingAdditions, [],
                "\(spelling) was treated as a different relay from \(url)"
            )
            XCTAssertEqual(service.relayStatus.pendingRemovals, [])
        }
    }

    @MainActor
    func testAddedRelayIsAPendingAddition() async throws {
        let (service, url) = try makeService()
        await service.refreshRelayStatus(all: [url, "wss://added.example"], enabled: [url, "wss://added.example"])
        XCTAssertEqual(service.relayStatus.pendingAdditions.count, 1)
        XCTAssertEqual(service.relayStatus.pendingRemovals, [])
    }

    /// Disabling a relay does not stop it being dialled until restart, so it
    /// must be reported — the user otherwise believes the toggle took effect.
    @MainActor
    func testDisabledRelayIsAPendingRemoval() async throws {
        let (service, url) = try makeService()
        await service.refreshRelayStatus(all: [url], enabled: [])
        XCTAssertEqual(service.relayStatus.pendingRemovals.count, 1)
        XCTAssertEqual(service.relayStatus.pendingAdditions, [])
    }

    /// A disabled relay keeps its policy label, so "retired" stays visible
    /// rather than disappearing when the relay is switched off.
    @MainActor
    func testDisabledRelayStillHasAPolicy() async throws {
        let (service, url) = try makeService()
        await service.refreshRelayStatus(all: [url], enabled: [])
        XCTAssertNotNil(service.relayStatus.policies[url])
    }
}

// MARK: - Leaving removes the group

extension MarmotKitTwoDeviceTests {

    /// Device report: leaving from the group detail screen removed the user
    /// from the group but left the chat and detail views on screen, and the
    /// group still in the list — faded, labelled "Inactive". That label is
    /// right for a group that ended around you and wrong for one you chose to
    /// leave.
    @MainActor
    func testLeavingAPopulatedGroupRemovesItFromTheList() async throws {
        let (alice, bob, _, groupId) = try await makePair(groupName: "Leaving")

        // Bob takes admin so Alice is free to go.
        try await alice.promoteToAdmin(try XCTUnwrap(bob.currentAccountRef), inGroup: groupId)
        try await alice.leaveGroup(groupId)

        XCTAssertFalse(
            alice.groups.contains { $0.mlsGroupId == groupId },
            "the group survived being left — the list would show it as Inactive"
        )
    }
}

// MARK: - Joining is detected, including the first group

extension MarmotKitTwoDeviceTests {

    /// Device report: the admin saw the new member as a bare npub with no
    /// avatar. `lastJoinedGroupId` drives the joiner broadcasting its own
    /// profile, and the detection guarded on the group list having been
    /// non-empty beforehand — so joining your *first* group, the case that
    /// matters most, was treated as a startup load and never announced.
    @MainActor
    func testJoiningAFirstGroupIsReportedAsAJoin() async throws {
        let alice = try makeService()
        _ = try await alice.startWithNewIdentity()
        let bob = try makeService()
        let bobRef = try await bob.startWithNewIdentity()

        // Bob has no groups at all — the condition the old guard mishandled.
        XCTAssertTrue(bob.groups.isEmpty)
        bob.startSubscriptions()

        let groupId = try await alice.createGroup(name: "First")
        try await alice.invite(memberRefs: [bobRef], toGroup: groupId)

        // Fails the test if it never happens — the joiner would silently
        // never broadcast its profile, which is the reported symptom.
        try await eventually("Bob to report joining his first group") {
            bob.lastJoinedGroupId == groupId
        }
    }
}
