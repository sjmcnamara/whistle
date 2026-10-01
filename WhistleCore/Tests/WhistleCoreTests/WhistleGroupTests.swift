import XCTest
@testable import WhistleCore

final class WhistleGroupTests: XCTestCase {

    private func makeGroup(name: String = "Dublin", admins: [String] = []) -> WhistleGroup {
        WhistleGroup(
            mlsGroupId: "abc123",
            name: name,
            isActive: true,
            adminPubkeys: admins
        )
    }

    func testDisplayNameFallsBackWhenNameIsEmpty() {
        XCTAssertEqual(makeGroup(name: "").displayName, "Unnamed Group")
    }

    func testDisplayNameUsesNameWhenPresent() {
        XCTAssertEqual(makeGroup(name: "Dublin").displayName, "Dublin")
    }

    func testIdentifiableIdIsTheMlsGroupId() {
        let group = makeGroup()
        XCTAssertEqual(group.id, group.mlsGroupId)
    }

    func testIsAdminReflectsAdminList() {
        let group = makeGroup(admins: ["alice", "bob"])
        XCTAssertTrue(group.isAdmin("alice"))
        XCTAssertFalse(group.isAdmin("carol"))
    }

    func testIsAdminIsFalseWhenAdminListIsEmpty() {
        XCTAssertFalse(makeGroup(admins: []).isAdmin("alice"))
    }
}
