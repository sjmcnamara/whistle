import XCTest
@testable import WhistleCore

final class LocationPayloadTests: XCTestCase {

    func makeSample() -> LocationPayload {
        LocationPayload(
            latitude: 51.5074,
            longitude: -0.1278,
            altitude: 10.0,
            accuracy: 5.0,
            timestamp: Date(timeIntervalSince1970: 1700000000)
        )
    }

    func testTypeFieldIsAlwaysLocation() {
        XCTAssertEqual(makeSample().type, "location")
    }

    func testVFieldIsAlways1() {
        XCTAssertEqual(makeSample().v, 1)
    }

    func testRoundTripJSONPreservesAllFields() throws {
        let original = makeSample()
        let json = try original.jsonString()
        let decoded = try LocationPayload.from(jsonString: json)

        XCTAssertEqual(original.type, decoded.type)
        XCTAssertEqual(original.lat, decoded.lat, accuracy: 0.0001)
        XCTAssertEqual(original.lon, decoded.lon, accuracy: 0.0001)
        XCTAssertEqual(original.alt, decoded.alt, accuracy: 0.0001)
        XCTAssertEqual(original.acc, decoded.acc, accuracy: 0.0001)
        XCTAssertEqual(original.ts, decoded.ts)
        XCTAssertEqual(original.v, decoded.v)
    }

    func testDateComputedPropertyConvertsTsCorrectly() {
        let payload = makeSample()
        XCTAssertEqual(payload.date.timeIntervalSince1970, 1700000000, accuracy: 0.001)
    }

    func testFromJsonThrowsOnInvalidJSON() {
        XCTAssertThrowsError(try LocationPayload.from(jsonString: "not valid {{{"))
    }
}
