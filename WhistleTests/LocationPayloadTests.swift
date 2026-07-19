import XCTest
import WhistleCore
@testable import Whistle

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

    // MARK: - Interval (v1.2.1+ optional field)

    func testIntervalDefaultsToNil() {
        let payload = LocationPayload(
            latitude: 0, longitude: 0, altitude: 0, accuracy: 0,
            timestamp: Date()
        )
        XCTAssertNil(payload.interval)
    }

    func testIntervalIsEncodedWhenSet() throws {
        let payload = LocationPayload(
            latitude: 0, longitude: 0, altitude: 0, accuracy: 0,
            timestamp: Date(), interval: 600
        )
        let json = try payload.jsonString()
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(obj["interval"] as? Int, 600)
    }

    func testIntervalRoundTrip() throws {
        let original = LocationPayload(
            latitude: 0, longitude: 0, altitude: 0, accuracy: 0,
            timestamp: Date(timeIntervalSince1970: 1700000000),
            battery: 87, interval: 3600
        )
        let json = try original.jsonString()
        let decoded = try LocationPayload.from(jsonString: json)
        XCTAssertEqual(decoded.interval, 3600)
        XCTAssertEqual(original, decoded)
    }

    func testDecodeBackwardCompatPayloadWithoutInterval() throws {
        // pre-v1.2.1 clients omit the interval field; receivers must accept the
        // payload and fall back to their own local interval for staleness.
        let json = """
        {"type":"location","lat":0,"lon":0,"alt":0,"acc":0,"ts":1700000000,"v":1}
        """
        let payload = try LocationPayload.from(jsonString: json)
        XCTAssertNil(payload.interval)
        XCTAssertEqual(payload.v, 1)
    }

    // MARK: - stationary (v1.7)

    func testStationaryDefaultsToNil() {
        let payload = LocationPayload(
            latitude: 0, longitude: 0, altitude: 0, accuracy: 0,
            timestamp: Date(timeIntervalSince1970: 1700000000)
        )
        XCTAssertNil(payload.stationary)
    }

    func testStationaryIsOmittedFromJSONWhenNil() throws {
        // Must be absent, not `"stationary":null` — receivers distinguish
        // "unknown" from an explicit value, and an older client parsing a null
        // should see the same shape it always has.
        let payload = LocationPayload(
            latitude: 0, longitude: 0, altitude: 0, accuracy: 0,
            timestamp: Date(timeIntervalSince1970: 1700000000)
        )
        XCTAssertFalse(try payload.jsonString().contains("stationary"))
    }

    func testStationaryRoundTripTrueAndFalse() throws {
        for value in [true, false] {
            let original = LocationPayload(
                latitude: 51.5, longitude: -0.12, altitude: 10, accuracy: 5,
                timestamp: Date(timeIntervalSince1970: 1700000000),
                battery: 87, interval: 3600, stationary: value
            )
            let decoded = try LocationPayload.from(jsonString: original.jsonString())
            XCTAssertEqual(decoded.stationary, value)
            XCTAssertEqual(original, decoded)
        }
    }

    func testDecodeBackwardCompatPayloadWithoutStationary() throws {
        // pre-v1.7 clients omit the field. It must decode as nil ("unknown"),
        // never false — false would claim the member is known to be moving.
        let json = """
        {"type":"location","lat":0,"lon":0,"alt":0,"acc":0,"ts":1700000000,"interval":3600,"v":1}
        """
        let payload = try LocationPayload.from(jsonString: json)
        XCTAssertNil(payload.stationary)
        XCTAssertNotEqual(payload.stationary, false)
    }

    func testStationaryFalseIsDistinctFromOmitted() throws {
        let explicit = LocationPayload(
            latitude: 0, longitude: 0, altitude: 0, accuracy: 0,
            timestamp: Date(timeIntervalSince1970: 1700000000), stationary: false
        )
        let omitted = LocationPayload(
            latitude: 0, longitude: 0, altitude: 0, accuracy: 0,
            timestamp: Date(timeIntervalSince1970: 1700000000)
        )
        XCTAssertNotEqual(explicit, omitted)
        XCTAssertEqual(try LocationPayload.from(jsonString: explicit.jsonString()).stationary, false)
        XCTAssertNil(try LocationPayload.from(jsonString: omitted.jsonString()).stationary)
    }
}
