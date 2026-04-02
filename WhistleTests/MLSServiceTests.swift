import XCTest
import NostrSDK
@testable import Whistle

/// Tests for MLSService using an in-memory MDK instance (no Keychain, no disk I/O).
final class MLSServiceTests: XCTestCase {

    // Shared service — reset per test to guarantee isolation
    private var service: MLSService!

    // A stable hex pubkey for tests that don't need real Nostr signing
    private let aliceHex = String(repeating: "a", count: 64)
    private let bobHex   = String(repeating: "b", count: 64)

    override func setUp() async throws {
        try await super.setUp()
        service = MLSService()
        try await service.initialiseInMemory()
    }

    // MARK: - Initialisation

    func testInitialisedFlagSetAfterInit() async {
        let flag = await service.isInitialised
        XCTAssertTrue(flag)
    }

    func testUninitalisedServiceThrows() async {
        let fresh = MLSService()
        await XCTAssertThrowsErrorAsync(try await fresh.getGroups())
    }

    // MARK: - Key Packages

    func testCreateKeyPackageReturnsNonEmptyResult() async throws {
        let result = try await service.createKeyPackage(
            publicKeyHex: aliceHex,
            relays: ["wss://relay.damus.io"]
        )
        XCTAssertFalse(result.keyPackage.isEmpty, "keyPackage hex should be non-empty")
        XCTAssertFalse(result.tags.isEmpty, "tags array should be non-empty")
    }

    func testCreateKeyPackageTagsContainRelayHint() async throws {
        let relay  = "wss://relay.damus.io"
        let result = try await service.createKeyPackage(
            publicKeyHex: aliceHex,
            relays: [relay]
        )
        let allTagValues = result.tags.flatMap { $0 }
        XCTAssertTrue(allTagValues.contains(relay),
                      "tags should contain the relay hint")
    }

    // MARK: - Group Lifecycle

    func testCreateGroupReturnsValidGroup() async throws {
        let result = try await service.createGroup(
            creatorPublicKeyHex: aliceHex,
            name: "Test Family",
            description: "A test group",
            relays: ["wss://relay.damus.io"]
        )
        XCTAssertFalse(result.group.mlsGroupId.isEmpty)
        XCTAssertEqual(result.group.name, "Test Family")
    }

    func testCreateGroupEpochStartsAtZero() async throws {
        let result = try await service.createGroup(
            creatorPublicKeyHex: aliceHex,
            name: "Epoch Test",
            relays: []
        )
        XCTAssertEqual(result.group.epoch, 0)
    }

    func testMergePendingCommitSucceedsAfterCreate() async throws {
        let result = try await service.createGroup(
            creatorPublicKeyHex: aliceHex,
            name: "Merge Test",
            relays: []
        )
        // Must not throw
        try await service.mergePendingCommit(groupId: result.group.mlsGroupId)
    }

    func testGetGroupReturnsCreatedGroup() async throws {
        let result = try await service.createGroup(
            creatorPublicKeyHex: aliceHex,
            name: "Lookup Test",
            relays: []
        )
        try await service.mergePendingCommit(groupId: result.group.mlsGroupId)

        let fetched = try await service.getGroup(mlsGroupId: result.group.mlsGroupId)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.mlsGroupId, result.group.mlsGroupId)
    }

    func testGetGroupsListsCreatedGroup() async throws {
        let result = try await service.createGroup(
            creatorPublicKeyHex: aliceHex,
            name: "Listed",
            relays: []
        )
        try await service.mergePendingCommit(groupId: result.group.mlsGroupId)

        let groups = try await service.getGroups()
        XCTAssertTrue(groups.contains { $0.mlsGroupId == result.group.mlsGroupId })
    }

    func testGetGroupReturnsNilForUnknownId() async throws {
        let group = try await service.getGroup(mlsGroupId: String(repeating: "0", count: 64))
        XCTAssertNil(group)
    }

    // MARK: - Messages

    func testCreateMessageReturnsValidJSON() async throws {
        let result = try await service.createGroup(
            creatorPublicKeyHex: aliceHex,
            name: "Msg Group",
            relays: []
        )
        try await service.mergePendingCommit(groupId: result.group.mlsGroupId)

        let eventJson = try await service.createMessage(
            groupId: result.group.mlsGroupId,
            senderPublicKeyHex: aliceHex,
            content: "Hello, family!"
        )

        XCTAssertFalse(eventJson.isEmpty)
        let data = Data(eventJson.utf8)
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: data),
            "createMessage should return valid JSON"
        )
    }

    func testCreateMessageEventJsonContainsKindField() async throws {
        let result = try await service.createGroup(
            creatorPublicKeyHex: aliceHex,
            name: "Kind Field Test",
            relays: []
        )
        try await service.mergePendingCommit(groupId: result.group.mlsGroupId)

        let eventJson = try await service.createMessage(
            groupId: result.group.mlsGroupId,
            senderPublicKeyHex: aliceHex,
            content: "hi"
        )

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(eventJson.utf8)) as? [String: Any]
        )
        XCTAssertNotNil(json["kind"], "event JSON should contain a 'kind' field")
    }

    func testMultipleMessagesCanBeSent() async throws {
        let result = try await service.createGroup(
            creatorPublicKeyHex: aliceHex,
            name: "Multi-msg",
            relays: []
        )
        try await service.mergePendingCommit(groupId: result.group.mlsGroupId)
        let gid = result.group.mlsGroupId

        for i in 1...3 {
            _ = try await service.createMessage(
                groupId: gid,
                senderPublicKeyHex: aliceHex,
                content: "Message \(i)"
            )
        }

        let messages = try await service.getMessages(groupId: gid, limit: 10)
        XCTAssertFalse(messages.isEmpty)
    }

    // MARK: - Message convenience extensions

    func testMessagePlaintextContentParsed() async throws {
        let result = try await service.createGroup(
            creatorPublicKeyHex: aliceHex,
            name: "Content Test",
            relays: []
        )
        try await service.mergePendingCommit(groupId: result.group.mlsGroupId)
        let gid = result.group.mlsGroupId

        _ = try await service.createMessage(
            groupId: gid,
            senderPublicKeyHex: aliceHex,
            content: "Test content"
        )

        let messages = try await service.getMessages(groupId: gid, limit: 1)
        if let first = messages.first {
            // plaintextContent parses eventJson — verify it doesn't crash
            _ = first.plaintextContent
            _ = first.innerKind
        }
    }

    // MARK: - Self-update / epoch rotation

    func testSelfUpdateDoesNotThrow() async throws {
        let result = try await service.createGroup(
            creatorPublicKeyHex: aliceHex,
            name: "Rotation Test",
            relays: []
        )
        try await service.mergePendingCommit(groupId: result.group.mlsGroupId)
        let gid = result.group.mlsGroupId

        let updateResult = try await service.selfUpdate(groupId: gid)
        XCTAssertFalse(updateResult.evolutionEventJson.isEmpty)

        try await service.mergePendingCommit(groupId: gid)

        // Epoch should have advanced
        let group = try await service.getGroup(mlsGroupId: gid)
        XCTAssertGreaterThan(group?.epoch ?? 0, 0)
    }

    func testGroupsNeedingSelfUpdateReturnsArray() async throws {
        let groups = try await service.groupsNeedingSelfUpdate(thresholdSecs: 1)
        XCTAssertNotNil(groups) // may be empty or non-empty — just verify no throw
    }

    // MARK: - Publish payload helpers

    func testCreateGroupPublishPayloadHasWelcomeRumors() async throws {
        // With no initial members, welcome rumors should be empty
        let result = try await service.createGroup(
            creatorPublicKeyHex: aliceHex,
            name: "Payload Test",
            relays: ["wss://relay.damus.io"]
        )
        let payload = result.publishPayload(relayURLs: ["wss://relay.damus.io"])
        // Solo group: no members to welcome
        XCTAssertEqual(payload.welcomeRumors.count, result.welcomeRumorsJson.count)
        XCTAssertEqual(payload.relayURLs, ["wss://relay.damus.io"])
    }

    func testUpdateGroupResultPublishPayloadContainsEvolutionEvent() async throws {
        let result = try await service.createGroup(
            creatorPublicKeyHex: aliceHex,
            name: "Evolution Test",
            relays: []
        )
        try await service.mergePendingCommit(groupId: result.group.mlsGroupId)

        let updateResult = try await service.selfUpdate(groupId: result.group.mlsGroupId)
        let payload = updateResult.publishPayload(relayURLs: [])
        XCTAssertFalse(payload.events.isEmpty)
        XCTAssertFalse(payload.events[0].isEmpty)
    }
}

// MARK: - Async XCTest helper

/// Asserts that an async expression throws an error.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw, but it returned successfully",
                file: file, line: line)
    } catch {
        // Expected
    }
}
