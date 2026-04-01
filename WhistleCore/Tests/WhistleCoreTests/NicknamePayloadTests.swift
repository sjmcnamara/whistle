import XCTest
@testable import WhistleCore

final class NicknamePayloadTests: XCTestCase {

    func testTypeFieldIsAlwaysNickname() {
        let payload = NicknamePayload(name: "Dad")
        XCTAssertEqual(payload.type, "nickname")
    }

    func testVFieldIsAlways1() {
        let payload = NicknamePayload(name: "Dad")
        XCTAssertEqual(payload.v, 1)
    }

    func testRoundTripJSON() throws {
        let original = NicknamePayload(name: "Mum", timestamp: Date(timeIntervalSince1970: 1700000000))
        let json = try original.jsonString()
        let decoded = try NicknamePayload.from(jsonString: json)

        XCTAssertEqual(original.type, decoded.type)
        XCTAssertEqual(original.name, decoded.name)
        XCTAssertEqual(original.ts, decoded.ts)
        XCTAssertEqual(original.v, decoded.v)
    }
}
