import XCTest
import WhistleCore
@testable import Whistle

final class ChatPayloadTests: XCTestCase {

    func testEncodeProducesValidJSON() throws {
        let payload = ChatPayload(text: "Hello!")
        let json = try payload.jsonString()
        XCTAssertTrue(json.contains("\"type\":\"chat\""))
        XCTAssertTrue(json.contains("\"text\":\"Hello!\""))
    }

    func testDecodeFromValidJSON() throws {
        let json = """
        {"type":"chat","text":"Hi there","ts":1700000000,"v":1}
        """
        let payload = try ChatPayload.from(jsonString: json)
        XCTAssertEqual(payload.text, "Hi there")
        XCTAssertEqual(payload.ts, 1700000000)
    }

    func testRoundTrip() throws {
        let original = ChatPayload(text: "Round trip test")
        let json = try original.jsonString()
        let decoded = try ChatPayload.from(jsonString: json)
        XCTAssertEqual(original.text, decoded.text)
        XCTAssertEqual(original.v, decoded.v)
        XCTAssertEqual(original.type, decoded.type)
    }

    func testTypeFieldIsChat() {
        let payload = ChatPayload(text: "test")
        XCTAssertEqual(payload.type, "chat")
    }

    func testVersionFieldIsOne() {
        let payload = ChatPayload(text: "test")
        XCTAssertEqual(payload.v, 1)
    }

    func testTimestampConversion() {
        let now = Date()
        let payload = ChatPayload(text: "test", timestamp: now)
        let diff = abs(payload.date.timeIntervalSince(now))
        XCTAssertLessThan(diff, 1.0, "Timestamp should round-trip within 1 second")
    }
}
