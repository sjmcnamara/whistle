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
