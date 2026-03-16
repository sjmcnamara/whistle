import Foundation

/// JSON payload for location updates sent inside kind-445 MLS application messages.
///
/// Schema (inner kind = `MarmotKind.location` / 1):
/// ```json
/// { "type": "location", "lat": 0.0, "lon": 0.0, "alt": 0.0, "acc": 10.0, "ts": 1700000000, "v": 1 }
/// ```
struct LocationPayload: Codable, Equatable {

    /// Always `"location"`.
    let type: String

    /// Latitude in decimal degrees.
    let lat: Double

    /// Longitude in decimal degrees.
    let lon: Double

    /// Altitude in metres (0 if unavailable).
    let alt: Double

    /// Horizontal accuracy in metres.
    let acc: Double

    /// Unix timestamp (seconds since epoch).
    let ts: Int

    /// Schema version — always 1.
    let v: Int

    static let currentVersion = 1

    init(latitude: Double, longitude: Double, altitude: Double,
         accuracy: Double, timestamp: Date) {
        self.type = "location"
        self.lat  = latitude
        self.lon  = longitude
        self.alt  = altitude
        self.acc  = accuracy
        self.ts   = Int(timestamp.timeIntervalSince1970)
        self.v    = Self.currentVersion
    }

    /// Convert the Unix timestamp back to a `Date`.
    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(ts))
    }

    /// Encode to a JSON string for use as MLS message content.
    func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8)!
    }

    /// Decode from a JSON string received in an MLS message.
    static func from(jsonString: String) throws -> LocationPayload {
        let data = Data(jsonString.utf8)
        return try JSONDecoder().decode(LocationPayload.self, from: data)
    }
}
