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

    func testGeneratesIdentityOnFirstLaunch() {
        let service = IdentityService(storage: store)
        XCTAssertNotNil(service.identity)
        XCTAssertNotNil(service.keys)
        XCTAssertTrue(service.isNewUser)
    }

    func testNpubHasCorrectPrefix() {
        let service = IdentityService(storage: store)
        XCTAssertTrue(service.identity?.npub.hasPrefix("npub1") == true,
                      "npub should start with 'npub1'")
    }

    func testNpubIsReasonableLength() {
        let service = IdentityService(storage: store)
        XCTAssertGreaterThan(service.identity?.npub.count ?? 0, 50,
                             "npub should be a full bech32 string")
    }

    func testPublicKeyHexIsNonEmpty() {
        let service = IdentityService(storage: store)
        XCTAssertFalse(service.identity?.publicKeyHex.isEmpty == true)
    }

    // MARK: - Persistence

    func testSameNpubRestoredOnSecondInit() {
        let first = IdentityService(storage: store)
        let stored = first.identity?.npub

        // Second instance reads from the same in-memory store (simulates relaunch).
        let second = IdentityService(storage: store)
        XCTAssertEqual(stored, second.identity?.npub,
                       "npub should be stable across launches")
        XCTAssertFalse(second.isNewUser)
    }

    func testTwoFreshInstancesProduceDifferentKeys() {
        let first  = IdentityService(storage: InMemorySecureStorage())
        let second = IdentityService(storage: InMemorySecureStorage())
        XCTAssertNotEqual(first.identity?.npub, second.identity?.npub,
                          "Two fresh instances should produce distinct keypairs")
    }

    func testIsNewUserFalseOnRestore() {
        let _ = IdentityService(storage: store) // first launch — populates store
        let restored = IdentityService(storage: store)
        XCTAssertFalse(restored.isNewUser)
    }

    // MARK: - Destroy

    func testDestroyCurrentKeyNilsIdentity() {
        let service = IdentityService(storage: store)
        XCTAssertNotNil(service.keys)
        XCTAssertNotNil(service.identity)

        service.destroyCurrentKey()

        XCTAssertNil(service.keys, "keys should be nil after destroy")
        XCTAssertNil(service.identity, "identity should be nil after destroy")
    }

    func testDestroyCurrentKeyRemovesFromStorage() {
        let service = IdentityService(storage: store)
        XCTAssertNotNil(store.load(key: .nsec), "nsec should be in storage before destroy")

        service.destroyCurrentKey()

        XCTAssertNil(store.load(key: .nsec), "nsec should be removed from storage after destroy")
    }

    func testDestroyThenImportProducesDifferentIdentity() throws {
        let service = IdentityService(storage: store)
        let oldNpub = service.identity?.npub

        service.destroyCurrentKey()

        // Generate a fresh key and import it
        let freshKeys = NostrSDK.Keys.generate()
        let freshNsec = try freshKeys.secretKey().toBech32()
        try service.importKey(nsec: freshNsec)

        XCTAssertNotNil(service.identity)
        XCTAssertNotEqual(service.identity?.npub, oldNpub,
                          "New identity should differ from destroyed one")
    }

    func testDestroyThenNewInstanceGeneratesFreshKey() {
        let first = IdentityService(storage: store)
        let oldNpub = first.identity?.npub

        first.destroyCurrentKey()

        // Simulates app relaunch — no stored key, so a new one is generated
        let second = IdentityService(storage: store)
        XCTAssertNotNil(second.identity)
        XCTAssertNotEqual(second.identity?.npub, oldNpub,
                          "Fresh instance after destroy should generate a new identity")
        XCTAssertTrue(second.isNewUser)
    }

    // MARK: - Import

    func testImportKeyChangesIdentity() throws {
        let service = IdentityService(storage: store)
        let originalNpub = service.identity?.npub

        let freshKeys = NostrSDK.Keys.generate()
        let freshNsec = try freshKeys.secretKey().toBech32()
        try service.importKey(nsec: freshNsec)

        XCTAssertNotEqual(service.identity?.npub, originalNpub)
        XCTAssertFalse(service.isNewUser)
    }

    func testImportKeyPersistsToStorage() throws {
        let service = IdentityService(storage: store)

        let freshKeys = NostrSDK.Keys.generate()
        let freshNsec = try freshKeys.secretKey().toBech32()
        try service.importKey(nsec: freshNsec)

        XCTAssertEqual(store.load(key: .nsec), freshNsec,
                       "Imported nsec should be persisted in storage")
    }

    func testImportKeyRestoresOnRelaunch() throws {
        let first = IdentityService(storage: store)

        let freshKeys = NostrSDK.Keys.generate()
        let freshNsec = try freshKeys.secretKey().toBech32()
        try first.importKey(nsec: freshNsec)
        let importedNpub = first.identity?.npub

        // Simulate relaunch
        let second = IdentityService(storage: store)
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
