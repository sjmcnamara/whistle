import XCTest
import NostrSDK
@testable import Whistle

@MainActor
final class IdentityServiceTests: XCTestCase {

    // Use in-memory storage so tests are hermetic and don't require code signing.
    private var store: InMemorySecureStorage!

    override func setUp() async throws {
        try await super.setUp()
        store = InMemorySecureStorage()
    }

    // MARK: - Generation

    func testGeneratesIdentityOnFirstLaunch() async throws {
        let service = IdentityService(storage: store)
        await service.initialise()
        XCTAssertNotNil(service.identity)
        XCTAssertNotNil(service.keys)
        XCTAssertTrue(service.isNewUser)
    }

    func testNpubHasCorrectPrefix() async throws {
        let service = IdentityService(storage: store)
        await service.initialise()
        XCTAssertTrue(service.identity?.npub.hasPrefix("npub1") == true,
                      "npub should start with 'npub1'")
    }

    func testNpubIsReasonableLength() async throws {
        let service = IdentityService(storage: store)
        await service.initialise()
        XCTAssertGreaterThan(service.identity?.npub.count ?? 0, 50,
                             "npub should be a full bech32 string")
    }

    func testPublicKeyHexIsNonEmpty() async throws {
        let service = IdentityService(storage: store)
        await service.initialise()
        XCTAssertFalse(service.identity?.publicKeyHex.isEmpty == true)
    }

    // MARK: - Persistence

    func testSameNpubRestoredOnSecondInit() async throws {
        let first = IdentityService(storage: store)
        await first.initialise()
        let stored = first.identity?.npub

        let second = IdentityService(storage: store)
        await second.initialise()
        XCTAssertEqual(stored, second.identity?.npub,
                       "npub should be stable across launches")
        XCTAssertFalse(second.isNewUser)
    }

    func testTwoFreshInstancesProduceDifferentKeys() async throws {
        let first  = IdentityService(storage: InMemorySecureStorage())
        let second = IdentityService(storage: InMemorySecureStorage())
        await first.initialise()
        await second.initialise()
        XCTAssertNotEqual(first.identity?.npub, second.identity?.npub,
                          "Two fresh instances should produce distinct keypairs")
    }

    func testIsNewUserFalseOnRestore() async throws {
        let first = IdentityService(storage: store)
        await first.initialise()
        let restored = IdentityService(storage: store)
        await restored.initialise()
        XCTAssertFalse(restored.isNewUser)
    }

    // MARK: - Destroy

    func testDestroyCurrentKeyNilsIdentity() async throws {
        let service = IdentityService(storage: store)
        await service.initialise()
        XCTAssertNotNil(service.keys)
        XCTAssertNotNil(service.identity)

        service.destroyCurrentKey()

        XCTAssertNil(service.keys, "keys should be nil after destroy")
        XCTAssertNil(service.identity, "identity should be nil after destroy")
    }

    func testDestroyCurrentKeyRemovesFromStorage() async throws {
        let service = IdentityService(storage: store)
        await service.initialise()
        XCTAssertNotNil(store.load(key: .nsec), "nsec should be in storage before destroy")

        service.destroyCurrentKey()

        XCTAssertNil(store.load(key: .nsec), "nsec should be removed from storage after destroy")
    }

    func testDestroyThenImportProducesDifferentIdentity() async throws {
        let service = IdentityService(storage: store)
        await service.initialise()
        let oldNpub = service.identity?.npub

        service.destroyCurrentKey()

        let freshKeys = NostrSDK.Keys.generate()
        let freshNsec = try freshKeys.secretKey().toBech32()
        try service.importKey(nsec: freshNsec)

        XCTAssertNotNil(service.identity)
        XCTAssertNotEqual(service.identity?.npub, oldNpub,
                          "New identity should differ from destroyed one")
    }

    func testDestroyThenNewInstanceGeneratesFreshKey() async throws {
        let first = IdentityService(storage: store)
        await first.initialise()
        let oldNpub = first.identity?.npub

        first.destroyCurrentKey()

        let second = IdentityService(storage: store)
        await second.initialise()
        XCTAssertNotNil(second.identity)
        XCTAssertNotEqual(second.identity?.npub, oldNpub,
                          "Fresh instance after destroy should generate a new identity")
        XCTAssertTrue(second.isNewUser)
    }

    // MARK: - Import

    func testImportKeyChangesIdentity() async throws {
        let service = IdentityService(storage: store)
        await service.initialise()
        let originalNpub = service.identity?.npub

        let freshKeys = NostrSDK.Keys.generate()
        let freshNsec = try freshKeys.secretKey().toBech32()
        try service.importKey(nsec: freshNsec)

        XCTAssertNotEqual(service.identity?.npub, originalNpub)
        XCTAssertFalse(service.isNewUser)
    }

    func testImportKeyPersistsToStorage() async throws {
        let service = IdentityService(storage: store)
        await service.initialise()

        let freshKeys = NostrSDK.Keys.generate()
        let freshNsec = try freshKeys.secretKey().toBech32()
        try service.importKey(nsec: freshNsec)

        XCTAssertEqual(store.load(key: .nsec), freshNsec,
                       "Imported nsec should be persisted in storage")
    }

    func testImportKeyRestoresOnRelaunch() async throws {
        let first = IdentityService(storage: store)
        await first.initialise()

        let freshKeys = NostrSDK.Keys.generate()
        let freshNsec = try freshKeys.secretKey().toBech32()
        try first.importKey(nsec: freshNsec)
        let importedNpub = first.identity?.npub

        let second = IdentityService(storage: store)
        await second.initialise()
        XCTAssertEqual(second.identity?.npub, importedNpub,
                       "Imported identity should survive relaunch")
    }

    // MARK: - Secure Storage Delete

    func testInMemoryStorageDeleteRemovesKey() {
        store.save(key: .nsec, value: "nsec1test")
        XCTAssertNotNil(store.load(key: .nsec))

        store.delete(key: .nsec)
        XCTAssertNil(store.load(key: .nsec), "Key should be nil after delete")
    }

    func testInMemoryStorageDeleteReturnsTrueForMissingKey() {
        let result = store.delete(key: .nsec)
        XCTAssertTrue(result, "Deleting a non-existent key should return true")
    }

    func testInMemoryStorageSaveOverwritesPreviousValue() {
        store.save(key: .nsec, value: "old-value")
        store.save(key: .nsec, value: "new-value")
        XCTAssertEqual(store.load(key: .nsec), "new-value")
    }
}
