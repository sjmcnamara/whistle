import XCTest
import WhistleCore
@testable import Whistle

@MainActor
final class JoinRequestStoreTests: XCTestCase {

    private func makeStore() -> JoinRequestStore {
        // skipLoad avoids touching the shared UserDefaults key between tests.
        JoinRequestStore(skipLoad: true)
    }

    private func req(group: String, pubkey: String, kp: String = "{}", name: String? = nil) -> JoinRequest {
        JoinRequest(groupId: group, pubkey: pubkey, keyPackage: kp, name: name)
    }

    func testAddAndFilterByGroup() {
        let store = makeStore()
        store.add(req(group: "g1", pubkey: "a"))
        store.add(req(group: "g1", pubkey: "b"))
        store.add(req(group: "g2", pubkey: "c"))

        XCTAssertEqual(store.requests.count, 3)
        XCTAssertEqual(Set(store.requests(forGroup: "g1").map(\.pubkey)), ["a", "b"])
        XCTAssertEqual(store.requests(forGroup: "g2").map(\.pubkey), ["c"])
    }

    func testReAddReplacesWithFreshKeyPackage() {
        let store = makeStore()
        store.add(req(group: "g1", pubkey: "a", kp: "OLD"))
        store.add(req(group: "g1", pubkey: "a", kp: "NEW"))

        XCTAssertEqual(store.requests(forGroup: "g1").count, 1, "Same (group,pubkey) must dedupe")
        XCTAssertEqual(store.requests(forGroup: "g1").first?.keyPackage, "NEW", "Freshest KeyPackage wins")
    }

    func testSamePubkeyDifferentGroupsCoexist() {
        let store = makeStore()
        store.add(req(group: "g1", pubkey: "a"))
        store.add(req(group: "g2", pubkey: "a"))
        XCTAssertEqual(store.requests.count, 2)
    }

    func testRemoveOne() {
        let store = makeStore()
        store.add(req(group: "g1", pubkey: "a"))
        store.add(req(group: "g1", pubkey: "b"))
        store.remove(groupId: "g1", pubkey: "a")
        XCTAssertEqual(store.requests(forGroup: "g1").map(\.pubkey), ["b"])
    }

    func testRemoveAllForGroup() {
        let store = makeStore()
        store.add(req(group: "g1", pubkey: "a"))
        store.add(req(group: "g1", pubkey: "b"))
        store.add(req(group: "g2", pubkey: "c"))
        store.removeAll(forGroup: "g1")
        XCTAssertTrue(store.requests(forGroup: "g1").isEmpty)
        XCTAssertEqual(store.requests(forGroup: "g2").map(\.pubkey), ["c"])
    }
}
