import XCTest
import WhistleCore
@testable import Whistle

final class RelayConfigTests: XCTestCase {

    // MARK: - RelayConfig

    func testDefaultRelaysAllUseWSS() {
        for relay in AppSettings.defaultRelays {
            XCTAssertTrue(relay.url.hasPrefix("wss://"),
                          "Relay \(relay.url) should use wss://")
        }
    }

    func testDefaultRelaysAreAllEnabled() {
        for relay in AppSettings.defaultRelays {
            XCTAssertTrue(relay.isEnabled)
        }
    }

    func testDefaultRelaysIsNonEmpty() {
        XCTAssertFalse(AppSettings.defaultRelays.isEmpty)
    }

    func testEachRelayConfigHasUniqueID() {
        let r1 = RelayConfig(url: "wss://relay.damus.io")
        let r2 = RelayConfig(url: "wss://relay.damus.io")
        XCTAssertNotEqual(r1.id, r2.id,
                          "Each RelayConfig instance should carry a unique UUID")
    }

    func testRelayConfigCodableRoundTrip() throws {
        let original = RelayConfig(url: "wss://relay.test.io", isEnabled: false)
        let data     = try JSONEncoder().encode(original)
        let decoded  = try JSONDecoder().decode(RelayConfig.self, from: data)

        XCTAssertEqual(original.id,        decoded.id)
        XCTAssertEqual(original.url,       decoded.url)
        XCTAssertEqual(original.isEnabled, decoded.isEnabled)
    }

    // MARK: - NostrIdentity

    func testShortNpubContainsEllipsis() {
        let long = "npub1" + String(repeating: "a", count: 55)
        let id   = NostrIdentity(npub: long, publicKeyHex: "deadbeef")
        XCTAssertTrue(id.shortNpub.contains("..."),
                      "shortNpub should truncate with an ellipsis")
    }

    func testShortNpubIsShorterThanFull() {
        let long = "npub1" + String(repeating: "a", count: 55)
        let id   = NostrIdentity(npub: long, publicKeyHex: "deadbeef")
        XCTAssertLessThan(id.shortNpub.count, long.count)
    }

    func testShortNpubPreservesPrefix() {
        let long = "npub1abcdefghij" + String(repeating: "x", count: 45)
        let id   = NostrIdentity(npub: long, publicKeyHex: "deadbeef")
        XCTAssertTrue(id.shortNpub.hasPrefix("npub1"))
    }

    func testShortNpubPassthroughForShortStrings() {
        let short = "npub1abc"
        let id    = NostrIdentity(npub: short, publicKeyHex: "")
        XCTAssertEqual(id.shortNpub, short,
                       "Short npub should be returned unchanged")
    }

    // MARK: - InMemorySecureStorage

    func testInMemorySaveAndLoad() {
        let storage = InMemorySecureStorage()
        XCTAssertTrue(storage.save(key: .nsec, value: "nsec1test"))
        XCTAssertEqual(storage.load(key: .nsec), "nsec1test")
    }

    func testInMemoryDeleteRemovesEntry() {
        let storage = InMemorySecureStorage()
        storage.save(key: .nsec, value: "nsec1test")
        XCTAssertTrue(storage.delete(key: .nsec))
        XCTAssertNil(storage.load(key: .nsec))
    }

    func testInMemoryOverwritesExistingValue() {
        let storage = InMemorySecureStorage()
        storage.save(key: .nsec, value: "first")
        storage.save(key: .nsec, value: "second")
        XCTAssertEqual(storage.load(key: .nsec), "second")
    }

    func testInMemoryLoadMissingKeyReturnsNil() {
        let storage = InMemorySecureStorage()
        XCTAssertNil(storage.load(key: .nsec))
    }
}
