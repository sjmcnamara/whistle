import XCTest
@testable import FindMyFam

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
}
