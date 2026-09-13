import XCTest
import NostrSDK
import WhistleCore
@testable import Whistle

@MainActor
final class NicknameStoreTests: XCTestCase {

    // Real keys, not synthetic "aaaa…"/"bbbb…" hex — the fallback now bech32-
    // encodes the pubkey, which requires a genuine point on the curve.
    private let aliceKeys = Keys.generate()
    private let bobKeys   = Keys.generate()
    private var alice: String { aliceKeys.publicKey().toHex() }
    private var bob: String { bobKeys.publicKey().toHex() }

    private var store: NicknameStore!

    override func setUp() {
        store = NicknameStore(skipLoad: true)
    }

    func testSetAndGetNickname() {
        store.set(name: "Alice", for: alice)
        XCTAssertEqual(store.displayName(for: alice), "Alice")
    }

    func testDisplayNameFallsBackToAbbreviatedNpub() throws {
        let expectedNpub = try aliceKeys.publicKey().toBech32()
        let expected = NostrIdentity(npub: expectedNpub, publicKeyHex: alice).shortNpub
        XCTAssertEqual(store.displayName(for: alice), expected)
        XCTAssertTrue(expected.hasPrefix("npub1"), "should be npub-encoded, not raw hex")
    }

    func testDisplayNameFallsBackToRawHexPrefixWhenPubkeyIsUnparseable() {
        // Not a valid pubkey at all (wrong length/format) — must degrade
        // gracefully to the old hex-prefix fallback rather than crash.
        let malformed = "not-a-real-pubkey"
        XCTAssertEqual(store.displayName(for: malformed), "not-a-re…")
    }

    func testRemoveNickname() throws {
        store.set(name: "Bob", for: bob)
        store.remove(for: bob)
        let expectedNpub = try bobKeys.publicKey().toBech32()
        XCTAssertEqual(
            store.displayName(for: bob),
            NostrIdentity(npub: expectedNpub, publicKeyHex: bob).shortNpub
        )
    }

    func testEmptyNameRemovesEntry() {
        store.set(name: "Alice", for: alice)
        store.set(name: "", for: alice)
        XCTAssertNil(store.nicknames[alice], "Empty name should remove entry")
    }

    func testMultipleNicknames() {
        store.set(name: "Alice", for: alice)
        store.set(name: "Bob", for: bob)
        XCTAssertEqual(store.nicknames.count, 2)
        XCTAssertEqual(store.displayName(for: alice), "Alice")
        XCTAssertEqual(store.displayName(for: bob), "Bob")
    }
}
