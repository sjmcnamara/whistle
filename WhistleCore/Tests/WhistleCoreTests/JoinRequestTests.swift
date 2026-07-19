import XCTest
@testable import WhistleCore

final class JoinRequestTests: XCTestCase {

    private let kp = #"{"kind":30443,"content":"<keypackage-hex>","tags":[]}"#

    func testTypeAndVersionAreFixed() {
        let req = JoinRequest(groupId: "g1", pubkey: "abc", keyPackage: kp)
        XCTAssertEqual(req.type, "join-request")
        XCTAssertEqual(req.v, 1)
    }

    func testRoundTripWithName() throws {
        let original = JoinRequest(groupId: "group-hex", pubkey: "pub-hex", keyPackage: kp, name: "Alice")
        let decoded = try JoinRequest.from(jsonString: try original.jsonString())
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.name, "Alice")
        XCTAssertEqual(decoded.keyPackage, kp)
    }

    func testRoundTripWithoutName() throws {
        let original = JoinRequest(groupId: "g", pubkey: "p", keyPackage: kp)
        let json = try original.jsonString()
        // A nil name must be omitted from the wire form, not encoded as null.
        XCTAssertFalse(json.contains("\"name\""))
        let decoded = try JoinRequest.from(jsonString: json)
        XCTAssertNil(decoded.name)
        XCTAssertEqual(decoded, original)
    }

    func testDecodeToleratesUnknownFields() throws {
        // Forward-compat: a newer sender may add fields an older client ignores.
        let json = #"{"type":"join-request","v":1,"groupId":"g","pubkey":"p","keyPackage":"{}","name":"Bo","future":42}"#
        let decoded = try JoinRequest.from(jsonString: json)
        XCTAssertEqual(decoded.groupId, "g")
        XCTAssertEqual(decoded.name, "Bo")
    }

    func testDecodeMissingRequiredFieldThrows() {
        let json = #"{"type":"join-request","v":1,"pubkey":"p","keyPackage":"{}"}"# // no groupId
        XCTAssertThrowsError(try JoinRequest.from(jsonString: json))
    }
}
