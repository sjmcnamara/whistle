import XCTest
import WhistleCore
@testable import Whistle

final class NicknamePayloadTests: XCTestCase {

    func testEncodeProducesValidJSON() throws {
        let payload = NicknamePayload(name: "Dad")
        let json = try payload.jsonString()
        XCTAssertTrue(json.contains("\"type\":\"nickname\""))
        XCTAssertTrue(json.contains("\"name\":\"Dad\""))
    }

    func testDecodeFromValidJSON() throws {
        let json = """
        {"type":"nickname","name":"Mom","ts":1700000000,"v":1}
        """
        let payload = try NicknamePayload.from(jsonString: json)
        XCTAssertEqual(payload.name, "Mom")
        XCTAssertEqual(payload.ts, 1700000000)
    }

    func testRoundTrip() throws {
        let original = NicknamePayload(name: "Kiddo")
        let json = try original.jsonString()
        let decoded = try NicknamePayload.from(jsonString: json)
        XCTAssertEqual(original.name, decoded.name)
        XCTAssertEqual(original.v, decoded.v)
    }

    func testTypeFieldIsNickname() {
        let payload = NicknamePayload(name: "Test")
        XCTAssertEqual(payload.type, "nickname")
    }
}
