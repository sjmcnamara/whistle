import XCTest
@testable import WhistleCore

final class MarmotKindTests: XCTestCase {

    func testKeyPackageIs30443() {
        XCTAssertEqual(MarmotKind.keyPackage, 30443)
    }

    func testWelcomeIs444() {
        XCTAssertEqual(MarmotKind.welcome, 444)
    }

    func testGroupEventIs445() {
        XCTAssertEqual(MarmotKind.groupEvent, 445)
    }

    func testKeyPackageRelayListIs10051() {
        XCTAssertEqual(MarmotKind.keyPackageRelayList, 10051)
    }

    func testGiftWrapIs1059() {
        XCTAssertEqual(MarmotKind.giftWrap, 1059)
    }

    func testJoinRequestIs1080() {
        XCTAssertEqual(MarmotKind.joinRequest, 1080)
    }

    func testChatIs9() {
        XCTAssertEqual(MarmotKind.chat, 9)
    }

    func testLocationIs1() {
        XCTAssertEqual(MarmotKind.location, 1)
    }

    func testLeaveRequestIs2() {
        XCTAssertEqual(MarmotKind.leaveRequest, 2)
    }
}
