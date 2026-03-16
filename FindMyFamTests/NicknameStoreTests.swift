import XCTest
@testable import FindMyFam

@MainActor
final class NicknameStoreTests: XCTestCase {

    private let alice = String(repeating: "a", count: 64)
    private let bob   = String(repeating: "b", count: 64)

    private var store: NicknameStore!

    override func setUp() {
        store = NicknameStore(skipLoad: true)
    }

    func testSetAndGetNickname() {
        store.set(name: "Alice", for: alice)
        XCTAssertEqual(store.displayName(for: alice), "Alice")
    }

    func testDisplayNameFallbackToShortHex() {
        let name = store.displayName(for: alice)
        XCTAssertEqual(name, "aaaaaaaa…", "Should show first 8 hex chars + ellipsis")
    }

    func testRemoveNickname() {
        store.set(name: "Bob", for: bob)
        store.remove(for: bob)
        XCTAssertEqual(store.displayName(for: bob), "bbbbbbbb…")
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
