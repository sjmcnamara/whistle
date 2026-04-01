import XCTest
import WhistleCore
@testable import FindMyFam

final class LocationPayloadTests: XCTestCase {

    // MARK: - Encoding

    func testEncodeProducesValidJSON() throws {
        let payload = LocationPayload(
            latitude: 37.7749, longitude: -122.4194,
            altitude: 10.0, accuracy: 5.0,
            timestamp: Date(timeIntervalSince1970: 1700000000)
        )
        let json = try payload.jsonString()
        let data = Data(json.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(obj["type"] as? String, "location")
        XCTAssertEqual(obj["lat"] as? Double, 37.7749)
        XCTAssertEqual(obj["lon"] as? Double, -122.4194)
        XCTAssertEqual(obj["alt"] as? Double, 10.0)
        XCTAssertEqual(obj["acc"] as? Double, 5.0)
        XCTAssertEqual(obj["ts"] as? Int, 1700000000)
        XCTAssertEqual(obj["v"] as? Int, 1)
    }

    // MARK: - Decoding

    func testDecodeFromValidJSON() throws {
        let json = """
        {"type":"location","lat":51.5074,"lon":-0.1278,"alt":20.0,"acc":15.0,"ts":1700000000,"v":1}
        """
        let payload = try LocationPayload.from(jsonString: json)
        XCTAssertEqual(payload.lat, 51.5074)
        XCTAssertEqual(payload.lon, -0.1278)
        XCTAssertEqual(payload.alt, 20.0)
        XCTAssertEqual(payload.acc, 15.0)
        XCTAssertEqual(payload.ts, 1700000000)
        XCTAssertEqual(payload.v, 1)
        XCTAssertEqual(payload.type, "location")
    }

    // MARK: - Round-trip

    func testRoundTrip() throws {
        let original = LocationPayload(
            latitude: -33.8688, longitude: 151.2093,
            altitude: 58.0, accuracy: 3.5,
            timestamp: Date(timeIntervalSince1970: 1710000000)
        )
        let json = try original.jsonString()
        let decoded = try LocationPayload.from(jsonString: json)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Fields

    func testVersionFieldIsOne() {
        let payload = LocationPayload(
            latitude: 0, longitude: 0, altitude: 0, accuracy: 0,
            timestamp: Date()
        )
        XCTAssertEqual(payload.v, 1)
        XCTAssertEqual(payload.v, LocationPayload.currentVersion)
    }

    func testTypeFieldIsLocation() {
        let payload = LocationPayload(
            latitude: 0, longitude: 0, altitude: 0, accuracy: 0,
            timestamp: Date()
        )
        XCTAssertEqual(payload.type, "location")
    }

    func testTimestampConversion() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let payload = LocationPayload(
            latitude: 0, longitude: 0, altitude: 0, accuracy: 0,
            timestamp: date
        )
        XCTAssertEqual(payload.ts, 1700000000)
        XCTAssertEqual(payload.date.timeIntervalSince1970, 1700000000, accuracy: 1)
    }
}
