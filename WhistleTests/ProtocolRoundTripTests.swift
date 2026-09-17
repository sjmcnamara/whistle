import XCTest
import NostrSDK
import WhistleCore
import MDKBindings
@testable import Whistle

/// Tier 1 — Protocol Correctness Tests
///
/// End-to-end round-trip tests for the Marmot protocol:
/// group lifecycle, member management, messages, key rotation, and leave flow.
/// Uses real MDK (in-memory) + MockRelayService.
@MainActor
final class ProtocolRoundTripTests: XCTestCase {

    private var mockRelay: MockRelayService!
    private var mls: MLSService!
    private var keys: Keys!
    private var pubHex: String!
    private var sut: MarmotService!  // system under test

    // Second user for multi-party tests
    private var mls2: MLSService!
    private var keys2: Keys!
    private var pub2Hex: String!
    private var sut2: MarmotService!
    private var mockRelay2: MockRelayService!

    override func setUp() async throws {
        try await super.setUp()

        // Alice (primary)
        mockRelay = MockRelayService()
        mls = MLSService()
        try await mls.initialiseInMemory()
        keys = Keys.generate()
        pubHex = keys.publicKey().toHex()
        sut = MarmotService(relay: mockRelay, mls: mls, publicKeyHex: pubHex, keys: keys)

        // Bob (secondary)
        mockRelay2 = MockRelayService()
        mls2 = MLSService()
        try await mls2.initialiseInMemory()
        keys2 = Keys.generate()
        pub2Hex = keys2.publicKey().toHex()
        sut2 = MarmotService(relay: mockRelay2, mls: mls2, publicKeyHex: pub2Hex, keys: keys2)
    }

    // MARK: - Helpers

    /// Create a solo group (Alice) and merge. Returns the group ID.
    private func createAndMergeGroup(name: String = "Test Group") async throws -> String {
        let result = try await mls.createGroup(
            creatorPublicKeyHex: pubHex,
            name: name,
            relays: ["wss://mock.relay"]
        )
        try await mls.mergePendingCommit(groupId: result.group.mlsGroupId)
        return result.group.mlsGroupId
    }

    /// Create a key package event JSON for Bob, suitable for addMembers.
    private func bobKeyPackageEventJson() async throws -> String {
        let kp = try await mls2.createKeyPackage(
            publicKeyHex: pub2Hex,
            relays: ["wss://mock.relay"]
        )
        // Build a signed kind-30443 event with the key package as content
        var builder = EventBuilder(kind: Kind(kind: MarmotKind.keyPackage), content: kp.keyPackage)
        var tags: [Tag] = []
        for tag in kp.tags {
            guard tag.count >= 2 else { continue }
            tags.append(Tag.custom(kind: .unknown(unknown: tag[0]), values: Array(tag.dropFirst())))
        }
        builder = builder.tags(tags: tags)
        let event = try builder.signWithKeys(keys: keys2)
        return try event.asJson()
    }

    // MARK: - 1. Group Creation

    func testCreateGroup_soloGroup_hasOneMember() async throws {
        let groupId = try await createAndMergeGroup()
        let members = try await mls.getMembers(groupId: groupId)
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members.first, pubHex)
    }

    func testCreateGroup_namePreserved() async throws {
        let groupId = try await createAndMergeGroup(name: "Family 🏡")
        let group = try await mls.getGroup(mlsGroupId: groupId)
        XCTAssertEqual(group?.name, "Family 🏡")
    }

    func testCreateGroup_relaysPreserved() async throws {
        let result = try await mls.createGroup(
            creatorPublicKeyHex: pubHex,
            name: "Relay Test",
            relays: ["wss://relay1.example", "wss://relay2.example"]
        )
        try await mls.mergePendingCommit(groupId: result.group.mlsGroupId)
        let relays = try await mls.getRelays(groupId: result.group.mlsGroupId)
        XCTAssertEqual(Set(relays), Set(["wss://relay1.example", "wss://relay2.example"]))
    }

    func testCreateGroup_multipleGroupsIndependent() async throws {
        let g1 = try await createAndMergeGroup(name: "Group 1")
        let g2 = try await createAndMergeGroup(name: "Group 2")
        XCTAssertNotEqual(g1, g2)

        let groups = try await mls.getGroups()
        XCTAssertEqual(groups.count, 2)
    }

    // MARK: - 2. Member Add (Welcome Round-Trip)

    func testAddMember_producesWelcomeRumors() async throws {
        let groupId = try await createAndMergeGroup()
        let bobKP = try await bobKeyPackageEventJson()

        let result = try await mls.addMembers(
            groupId: groupId,
            keyPackageEventsJson: [bobKP]
        )
        try await mls.mergePendingCommit(groupId: groupId)

        XCTAssertFalse(result.welcomeRumorsJson?.isEmpty ?? true,
                       "Adding a member should produce at least one welcome rumor")
    }

    func testAddMember_memberAppearsInList() async throws {
        let groupId = try await createAndMergeGroup()
        let bobKP = try await bobKeyPackageEventJson()

        _ = try await mls.addMembers(groupId: groupId, keyPackageEventsJson: [bobKP])
        try await mls.mergePendingCommit(groupId: groupId)

        let members = try await mls.getMembers(groupId: groupId)
        XCTAssertEqual(members.count, 2)
        XCTAssertTrue(members.contains(pubHex), "Creator should be in member list")
        XCTAssertTrue(members.contains(pub2Hex), "Added member should be in member list")
    }

    func testAddMember_welcomeCanBeProcessedByReceiver() async throws {
        let groupId = try await createAndMergeGroup()
        let bobKP = try await bobKeyPackageEventJson()

        let result = try await mls.addMembers(groupId: groupId, keyPackageEventsJson: [bobKP])
        try await mls.mergePendingCommit(groupId: groupId)

        // Bob processes the welcome
        let rumorJson = try XCTUnwrap(result.welcomeRumorsJson?.first,
                                       "Should have at least one welcome rumor")
        let welcome = try await mls2.processWelcome(
            wrapperEventId: String(repeating: "f", count: 64),
            rumorEventJson: rumorJson
        )
        XCTAssertEqual(welcome.mlsGroupId, groupId)
    }

    func testAddMember_welcomeAccepted_bobSeesGroup() async throws {
        let groupId = try await createAndMergeGroup()
        let bobKP = try await bobKeyPackageEventJson()

        let result = try await mls.addMembers(groupId: groupId, keyPackageEventsJson: [bobKP])
        try await mls.mergePendingCommit(groupId: groupId)

        let rumorJson = try XCTUnwrap(result.welcomeRumorsJson?.first)
        let welcome = try await mls2.processWelcome(
            wrapperEventId: String(repeating: "f", count: 64),
            rumorEventJson: rumorJson
        )
        try await mls2.acceptWelcome(welcome)

        // Bob should now see the group
        let bobGroups = try await mls2.getGroups()
        XCTAssertTrue(bobGroups.contains { $0.mlsGroupId == groupId },
                      "Bob should have the group after accepting welcome")
    }

    func testAddMember_welcomeAccepted_bobSeesBothMembers() async throws {
        let groupId = try await createAndMergeGroup()
        let bobKP = try await bobKeyPackageEventJson()

        let result = try await mls.addMembers(groupId: groupId, keyPackageEventsJson: [bobKP])
        try await mls.mergePendingCommit(groupId: groupId)

        let rumorJson = try XCTUnwrap(result.welcomeRumorsJson?.first)
        let welcome = try await mls2.processWelcome(
            wrapperEventId: String(repeating: "f", count: 64),
            rumorEventJson: rumorJson
        )
        try await mls2.acceptWelcome(welcome)

        let bobMembers = try await mls2.getMembers(groupId: groupId)
        XCTAssertEqual(bobMembers.count, 2,
                       "Bob should see both members after joining")
    }

    // MARK: - 3. Member Remove

    func testRemoveMember_memberGoneFromList() async throws {
        let groupId = try await createAndMergeGroup()
        let bobKP = try await bobKeyPackageEventJson()

        _ = try await mls.addMembers(groupId: groupId, keyPackageEventsJson: [bobKP])
        try await mls.mergePendingCommit(groupId: groupId)

        // Remove Bob
        _ = try await mls.removeMembers(groupId: groupId, memberPublicKeys: [pub2Hex])
        try await mls.mergePendingCommit(groupId: groupId)

        let members = try await mls.getMembers(groupId: groupId)
        XCTAssertEqual(members.count, 1)
        XCTAssertFalse(members.contains(pub2Hex), "Removed member should not be in list")
    }

    func testRemoveMember_producesEvolutionEvent() async throws {
        let groupId = try await createAndMergeGroup()
        let bobKP = try await bobKeyPackageEventJson()

        _ = try await mls.addMembers(groupId: groupId, keyPackageEventsJson: [bobKP])
        try await mls.mergePendingCommit(groupId: groupId)

        let removeResult = try await mls.removeMembers(
            groupId: groupId,
            memberPublicKeys: [pub2Hex]
        )
        XCTAssertFalse(removeResult.evolutionEventJson.isEmpty,
                       "Remove should produce an evolution event for relay publishing")
    }

    // MARK: - 4. Message Delivery

    func testMessage_roundTrip_contentPreserved() async throws {
        let groupId = try await createAndMergeGroup()

        let eventJson = try await mls.createMessage(
            groupId: groupId,
            senderPublicKeyHex: pubHex,
            content: "Hello, family!"
        )

        // Process the message as if it came from the relay
        let result = try await mls.processIncomingEvent(eventJson: eventJson)

        switch result {
        case .applicationMessage(let message):
            XCTAssertEqual(message.plaintextContent, "Hello, family!")
            XCTAssertEqual(message.senderPubkey, pubHex)
            XCTAssertEqual(message.mlsGroupId, groupId)
        default:
            XCTFail("Expected .applicationMessage, got \(result)")
        }
    }

    func testMessage_storedAndRetrievable() async throws {
        let groupId = try await createAndMergeGroup()

        // Send and self-process 3 messages
        for i in 1...3 {
            let json = try await mls.createMessage(
                groupId: groupId,
                senderPublicKeyHex: pubHex,
                content: "Message \(i)"
            )
            _ = try await mls.processIncomingEvent(eventJson: json)
        }

        let messages = try await mls.getMessages(groupId: groupId, limit: 10)
        XCTAssertEqual(messages.count, 3)
    }

    func testMessage_locationKind_roundTrip() async throws {
        let groupId = try await createAndMergeGroup()
        let locationJson = try LocationPayload(
            latitude: 53.3498, longitude: -6.2603, altitude: 10.0,
            accuracy: 5.0, timestamp: Date()
        ).jsonString()

        let eventJson = try await mls.createMessage(
            groupId: groupId,
            senderPublicKeyHex: pubHex,
            content: locationJson,
            kind: MarmotKind.location
        )

        let result = try await mls.processIncomingEvent(eventJson: eventJson)
        switch result {
        case .applicationMessage(let message):
            XCTAssertEqual(message.kind, MarmotKind.location)
            let payload = try XCTUnwrap(message.plaintextContent)
            let decoded = try LocationPayload.from(jsonString: payload)
            XCTAssertEqual(decoded.lat, 53.3498, accuracy: 0.0001)
            XCTAssertEqual(decoded.lon, -6.2603, accuracy: 0.0001)
        default:
            XCTFail("Expected .applicationMessage, got \(result)")
        }
    }

    func testMessage_chatPayload_roundTrip() async throws {
        let groupId = try await createAndMergeGroup()
        let chatPayload = ChatPayload(text: "Hey there! 👋")
        let chatJson = try chatPayload.jsonString()

        let eventJson = try await mls.createMessage(
            groupId: groupId,
            senderPublicKeyHex: pubHex,
            content: chatJson,
            kind: MarmotKind.chat
        )

        let result = try await mls.processIncomingEvent(eventJson: eventJson)
        switch result {
        case .applicationMessage(let message):
            let content = try XCTUnwrap(message.plaintextContent)
            let decoded = try ChatPayload.from(jsonString: content)
            XCTAssertEqual(decoded.text, "Hey there! 👋")
            XCTAssertEqual(decoded.type, "chat")
        default:
            XCTFail("Expected .applicationMessage, got \(result)")
        }
    }

    func testMessage_nicknamePayload_roundTrip() async throws {
        let groupId = try await createAndMergeGroup()
        let nicknamePayload = NicknamePayload(name: "Alice")
        let json = try nicknamePayload.jsonString()

        let eventJson = try await mls.createMessage(
            groupId: groupId,
            senderPublicKeyHex: pubHex,
            content: json,
            kind: MarmotKind.chat  // nicknames use chat kind with type="nickname"
        )

        let result = try await mls.processIncomingEvent(eventJson: eventJson)
        switch result {
        case .applicationMessage(let message):
            let content = try XCTUnwrap(message.plaintextContent)
            let decoded = try NicknamePayload.from(jsonString: content)
            XCTAssertEqual(decoded.name, "Alice")
            XCTAssertEqual(decoded.type, "nickname")
        default:
            XCTFail("Expected .applicationMessage, got \(result)")
        }
    }

    // MARK: - 5. Key Rotation (Epoch Advancement)

    func testKeyRotation_epochAdvances() async throws {
        let groupId = try await createAndMergeGroup()
        let before = try await mls.getGroup(mlsGroupId: groupId)
        let epochBefore = before?.epoch ?? 0

        _ = try await mls.selfUpdate(groupId: groupId)
        try await mls.mergePendingCommit(groupId: groupId)

        let after = try await mls.getGroup(mlsGroupId: groupId)
        XCTAssertGreaterThan(after?.epoch ?? 0, epochBefore,
                             "Epoch should advance after self-update")
    }

    func testKeyRotation_messagesStillWorkAfterRotation() async throws {
        let groupId = try await createAndMergeGroup()

        // Rotate keys
        _ = try await mls.selfUpdate(groupId: groupId)
        try await mls.mergePendingCommit(groupId: groupId)

        // Send a message after rotation
        let eventJson = try await mls.createMessage(
            groupId: groupId,
            senderPublicKeyHex: pubHex,
            content: "Post-rotation message"
        )
        let result = try await mls.processIncomingEvent(eventJson: eventJson)

        switch result {
        case .applicationMessage(let message):
            XCTAssertEqual(message.plaintextContent, "Post-rotation message")
        default:
            XCTFail("Should be able to send messages after key rotation")
        }
    }

    func testKeyRotation_multipleRotations() async throws {
        let groupId = try await createAndMergeGroup()

        for _ in 1...3 {
            _ = try await mls.selfUpdate(groupId: groupId)
            try await mls.mergePendingCommit(groupId: groupId)
        }

        let group = try await mls.getGroup(mlsGroupId: groupId)
        XCTAssertGreaterThanOrEqual(group?.epoch ?? 0, 3,
                                    "Epoch should advance 3 times")
    }

    func testKeyRotation_producesEvolutionEvent() async throws {
        let groupId = try await createAndMergeGroup()
        let result = try await mls.selfUpdate(groupId: groupId)
        XCTAssertFalse(result.evolutionEventJson.isEmpty)
    }

    // MARK: - 6. Leave Group Flow (self-remove)

    /// A plain (non-admin) member can leave directly — no admin action needed.
    private func addBobAsPlainMember(to groupId: String) async throws {
        let bobKP = try await bobKeyPackageEventJson()
        let result = try await mls.addMembers(groupId: groupId, keyPackageEventsJson: [bobKP])
        try await mls.mergePendingCommit(groupId: groupId)

        let rumorJson = try XCTUnwrap(result.welcomeRumorsJson?.first)
        let welcome = try await mls2.processWelcome(
            wrapperEventId: String(repeating: "f", count: 64),
            rumorEventJson: rumorJson
        )
        try await mls2.acceptWelcome(welcome)
    }

    /// Unlike other mutations, a self-remove commit is never merged locally —
    /// `deleteGroup` (not `mergePendingCommit`) is what actually finalizes it.
    func testLeaveGroup_nonAdminMember_deletesLocalGroupState() async throws {
        let groupId = try await createAndMergeGroup()
        try await addBobAsPlainMember(to: groupId)

        _ = try await mls2.leaveGroup(groupId: groupId)
        try await mls2.deleteGroup(groupId: groupId)

        let bobGroups = try await mls2.getGroups()
        XCTAssertFalse(bobGroups.contains { $0.mlsGroupId == groupId },
                       "Group should be gone locally for Bob after his own self-remove — no admin action required")
    }

    func testLeaveGroup_nonAdminMember_producesKind445EvolutionEvent() async throws {
        let groupId = try await createAndMergeGroup()
        try await addBobAsPlainMember(to: groupId)

        let result = try await mls2.leaveGroup(groupId: groupId)
        XCTAssertFalse(result.evolutionEventJson.isEmpty,
                       "Leave should produce an evolution event for relay publishing")

        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.evolutionEventJson.utf8)) as? [String: Any]
        )
        // kind 445 is the group event kind
        XCTAssertEqual(parsed["kind"] as? Int, 445)
    }

    /// MIP-03: an admin cannot call `leaveGroup` directly — they must
    /// `selfDemote` first. Regression test for this MDK-enforced constraint,
    /// which our leave flow must account for.
    func testLeaveGroup_admin_throwsUntilSelfDemoted() async throws {
        let groupId = try await createAndMergeGroup()
        do {
            _ = try await mls.leaveGroup(groupId: groupId)
            XCTFail("Admin should not be able to leave without self-demoting first")
        } catch {
            // Expected — MDK rejects with "Admins must self-demote before leaving."
        }
    }

    /// An admin who is NOT the last admin can self-demote, then leave, in two commits.
    func testLeaveGroup_admin_selfDemoteThenLeave_succeeds() async throws {
        let groupId = try await createAndMergeGroup()
        try await addBobAsPlainMember(to: groupId)

        let update = GroupDataUpdate(
            name: nil, description: nil, imageHash: nil,
            imageKey: nil, imageNonce: nil, relays: nil,
            admins: [pubHex, pub2Hex]
        )
        _ = try await mls.updateGroupData(groupId: groupId, update: update)
        try await mls.mergePendingCommit(groupId: groupId)

        _ = try await mls.selfDemote(groupId: groupId)
        try await mls.mergePendingCommit(groupId: groupId)

        _ = try await mls.leaveGroup(groupId: groupId)
        try await mls.deleteGroup(groupId: groupId)

        let remaining = try await mls.getGroups()
        XCTAssertFalse(remaining.contains { $0.mlsGroupId == groupId })
    }

    /// MIP-03: the last admin cannot self-demote at all — there's no one to
    /// hand admin duties to. This means a solo group (you're the only member)
    /// can never be left via `leaveGroup`; that case needs different handling.
    /// Non-admin selfDemote throws a distinct message ("only admins can
    /// perform this operation") from the last-admin case ("last active
    /// admin") — this is how `leaveGroup` distinguishes them without relying
    /// on our own cached admin list, which can diverge from MDK's live truth.
    func testSelfDemote_nonAdmin_throwsDistinctError() async throws {
        let groupId = try await createAndMergeGroup()
        try await addBobAsPlainMember(to: groupId)

        do {
            _ = try await mls2.selfDemote(groupId: groupId)
            XCTFail("Non-admin should not be able to self-demote")
        } catch let error as MdkUniffiError {
            guard case .Mdk(let message) = error else {
                XCTFail("Expected .Mdk error case, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("only admins can perform this operation"), "Got: \(message)")
        }
    }

    func testSelfDemote_lastAdmin_throws() async throws {
        let groupId = try await createAndMergeGroup()
        do {
            _ = try await mls.selfDemote(groupId: groupId)
            XCTFail("Last admin should not be able to self-demote without a successor")
        } catch {
            // Expected — MDK rejects with "Cannot self-demote: last active admin."
        }
    }

    // MARK: - 6b. MarmotService.leaveGroup — full production code path

    func testMarmotServiceLeaveGroup_nonAdmin_publishesAndDeletesLocally() async throws {
        let groupId = try await createAndMergeGroup()
        try await addBobAsPlainMember(to: groupId)
        await sut2.refreshGroups()

        // Make verifyEventOnRelay's fetch-back succeed immediately — the mock
        // ignores the filter and just returns whatever is configured here.
        let anyEventJson = try await mls.createMessage(groupId: groupId, senderPublicKeyHex: pubHex, content: "x")
        mockRelay2.eventsToReturn = [try Event.fromJson(json: anyEventJson)]

        try await sut2.leaveGroup(groupId: groupId)

        XCTAssertEqual(mockRelay2.sentEvents.count, 1, "Leave commit should be published")
        let remaining = try await mls2.getGroups()
        XCTAssertFalse(remaining.contains { $0.mlsGroupId == groupId },
                       "Group should be deleted locally after a successful leave")
    }

    func testMarmotServiceLeaveGroup_soloGroup_deletesWithoutPublishing() async throws {
        let groupId = try await createAndMergeGroup()

        try await sut.leaveGroup(groupId: groupId)

        XCTAssertTrue(mockRelay.sentEvents.isEmpty, "Solo group leave shouldn't publish anything — no one to notify")
        let remaining = try await mls.getGroups()
        XCTAssertFalse(remaining.contains { $0.mlsGroupId == groupId })
    }

    func testMarmotServiceLeaveGroup_lastAdminOfMultiMemberGroup_throwsClearError() async throws {
        let groupId = try await createAndMergeGroup()
        try await addBobAsPlainMember(to: groupId)
        await sut.refreshGroups()

        do {
            try await sut.leaveGroup(groupId: groupId)
            XCTFail("Sole admin of a multi-member group should not be able to leave")
        } catch MarmotService.MarmotError.lastAdminCannotLeave {
            // Expected
        }
    }

    // MARK: - 7. Nickname Broadcast via MarmotService

    func testNicknameBroadcast_publishesEvent() async throws {
        let groupId = try await createAndMergeGroup()
        await sut.refreshGroups()
        try await sut.sendNicknameUpdate(name: "Alice", toGroup: groupId)

        XCTAssertEqual(mockRelay.sentEvents.count, 1)
    }

    // MARK: - 8. Location Broadcast via MarmotService

    func testLocationBroadcast_publishesEvent() async throws {
        let groupId = try await createAndMergeGroup()
        await sut.refreshGroups()

        let payload = LocationPayload(
            latitude: 53.3498, longitude: -6.2603, altitude: 10.0,
            accuracy: 5.0, timestamp: Date()
        )
        try await sut.sendLocationUpdate(payload, toGroup: groupId)

        XCTAssertEqual(mockRelay.sentEvents.count, 1)
    }

    // MARK: - 9. Subscription Setup

    func testSubscriptions_registerTwoFilters() async throws {
        sut.startSubscriptions()
        // Allow task to start
        try await Task.sleep(nanoseconds: 100_000_000)

        // Should have subscriptions for group events (445) and gift-wraps (1059)
        XCTAssertGreaterThanOrEqual(mockRelay.subscribeFilters.count, 2,
                                    "Should register filters for group events and gift-wraps")
    }

    // MARK: - 10. Invite Code Round-Trip

    func testInviteCode_generateAndDecode() async throws {
        let groupId = try await createAndMergeGroup()
        let encoded = try sut.generateInviteCode(for: groupId, relay: "wss://mock.relay")

        let decoded = try InviteCode.decode(from: encoded)
        XCTAssertEqual(decoded.groupId, groupId)
        XCTAssertEqual(decoded.relay, "wss://mock.relay")
    }

    // MARK: - 11. Group Rename

    func testGroupRename_preservedAfterRefresh() async throws {
        let groupId = try await createAndMergeGroup(name: "Original Name")

        let update = GroupDataUpdate(
            name: "Renamed Group",
            description: nil,
            imageHash: nil,
            imageKey: nil,
            imageNonce: nil,
            relays: nil,
            admins: nil
        )
        _ = try await mls.updateGroupData(groupId: groupId, update: update)
        try await mls.mergePendingCommit(groupId: groupId)

        let group = try await mls.getGroup(mlsGroupId: groupId)
        XCTAssertEqual(group?.name, "Renamed Group")
    }
}
