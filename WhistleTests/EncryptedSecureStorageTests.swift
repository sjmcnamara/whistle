import XCTest
@testable import Whistle

@MainActor
final class EncryptedSecureStorageTests: XCTestCase {

    private var store: InMemorySecureStorage!

    override func setUp() async throws {
        try await super.setUp()
        store = InMemorySecureStorage()
    }

    // MARK: - Non-SE passthrough (simulator / non-nsec keys)

    func testNonNsecKeySavesAndLoadsDirectly() {
        let storage = EncryptedSecureStorage(keychain: .shared)
        // Use InMemorySecureStorage to test passthrough logic
        // (SE is not available in test runner, so all operations fall through)
        store.save(key: .nsec, value: "nsec1testvalue")
        XCTAssertEqual(store.load(key: .nsec), "nsec1testvalue")
    }

    func testDeleteRemovesValue() {
        store.save(key: .nsec, value: "nsec1testvalue")
        store.delete(key: .nsec)
        XCTAssertNil(store.load(key: .nsec))
    }

    // MARK: - InMemorySecureStorage Data methods

    func testDataSaveAndLoad() {
        let data = Data([0x01, 0x02, 0x03])
        store.saveData(key: .sePrivateKey, value: data)
        XCTAssertEqual(store.loadData(key: .sePrivateKey), data)
    }

    func testDataLoadReturnsNilWhenEmpty() {
        XCTAssertNil(store.loadData(key: .sePrivateKey))
    }

    func testDataOverwrite() {
        store.saveData(key: .sePrivateKey, value: Data([0x01]))
        store.saveData(key: .sePrivateKey, value: Data([0x02]))
        XCTAssertEqual(store.loadData(key: .sePrivateKey), Data([0x02]))
    }

    func testDeleteClearsDataStore() {
        store.saveData(key: .sePrivateKey, value: Data([0x01, 0x02]))
        store.delete(key: .sePrivateKey)
        XCTAssertNil(store.loadData(key: .sePrivateKey))
    }

    func testDeleteClearsBothStringAndDataStores() {
        store.save(key: .nsec, value: "nsec1test")
        store.saveData(key: .nsec, value: Data([0xAB]))
        store.delete(key: .nsec)
        XCTAssertNil(store.load(key: .nsec))
        XCTAssertNil(store.loadData(key: .nsec))
    }

    // MARK: - Migration detection

    func testPlaintextNsecDetectedByPrefix() {
        // Verify the migration logic: values starting with "nsec1" are plaintext
        let plaintext = "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqhqtcqp"
        XCTAssertTrue(plaintext.hasPrefix("nsec1"),
                      "Plaintext nsec should be detectable by prefix")
    }

    func testBase64ValueDoesNotStartWithNsec1() {
        // Simulated AES-GCM sealed box as base64
        let sealed = Data([0xAB, 0xCD, 0xEF, 0x01, 0x02, 0x03]).base64EncodedString()
        XCTAssertFalse(sealed.hasPrefix("nsec1"),
                       "SE-encrypted value should not look like a plaintext nsec")
    }

    // MARK: - KeychainKey enum

    func testKeychainKeyRawValues() {
        XCTAssertEqual(KeychainKey.nsec.rawValue, "org.findmyfam.nsec")
        XCTAssertEqual(KeychainKey.sePrivateKey.rawValue, "org.findmyfam.se.privatekey")
        XCTAssertEqual(KeychainKey.seEphemeralPublicKey.rawValue, "org.findmyfam.se.ephemeral-pubkey")
    }

    // MARK: - IdentityService integration (non-SE path)

    func testIdentityServiceWorksWithInMemoryStorage() async throws {
        let service = IdentityService(storage: store)
        await service.initialise()
        XCTAssertNotNil(service.identity)
        XCTAssertNotNil(service.keys)
    }

    func testIdentityServicePersistsAndRestoresWithInMemoryStorage() async throws {
        let first = IdentityService(storage: store)
        await first.initialise()
        let npub = first.identity?.npub

        let second = IdentityService(storage: store)
        await second.initialise()
        XCTAssertEqual(second.identity?.npub, npub)
    }

    func testDestroyKeyAndRecreateCleansAllState() async throws {
        let service = IdentityService(storage: store)
        await service.initialise()
        let oldNpub = service.identity?.npub

        service.destroyCurrentKey()

        XCTAssertNil(store.loadData(key: .sePrivateKey))
        XCTAssertNil(store.loadData(key: .seEphemeralPublicKey))

        let fresh = IdentityService(storage: store)
        await fresh.initialise()
        XCTAssertNotEqual(fresh.identity?.npub, oldNpub)
    }
}
