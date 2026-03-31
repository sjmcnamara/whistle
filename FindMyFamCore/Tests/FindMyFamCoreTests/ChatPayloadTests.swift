import XCTest
@testable import FindMyFamCore

final class ChatPayloadTests: XCTestCase {

    func testTypeFieldIsAlwaysChat() {
        let payload = ChatPayload(text: "Hello!")
        XCTAssertEqual(payload.type, "chat")
    }

    func testVFieldIsAlways1() {
        let payload = ChatPayload(text: "Hello!")
        XCTAssertEqual(payload.v, 1)
    }

    func testRoundTripJSON() throws {
        let original = ChatPayload(text: "Hello, world!", timestamp: Date(timeIntervalSince1970: 1700000000))
        let json = try original.jsonString()
        let decoded = try ChatPayload.from(jsonString: json)

        XCTAssertEqual(original.type, decoded.type)
        XCTAssertEqual(original.text, decoded.text)
        XCTAssertEqual(original.ts, decoded.ts)
        XCTAssertEqual(original.v, decoded.v)
    }

    func testDatePropertyCorrect() {
        let payload = ChatPayload(text: "hi", timestamp: Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(payload.date.timeIntervalSince1970, 1700000000, accuracy: 0.001)
    }
}
