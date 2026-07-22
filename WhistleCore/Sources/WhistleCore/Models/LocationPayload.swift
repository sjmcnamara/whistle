import Foundation

/// JSON payload for location updates sent inside kind-445 MLS application messages.
///
/// Schema (inner kind = `MarmotKind.location` / 1):
/// ```json
/// { "type": "location", "lat": 0.0, "lon": 0.0, "alt": 0.0, "acc": 10.0,
///   "ts": 1700000000, "batt": 87, "interval": 3600, "stationary": true, "v": 1 }
/// ```
///
/// `interval` is the publisher's own update cadence in seconds. Receivers use
/// it to decide when a pin is stale (typically `> 2 × interval` since `ts`).
/// Optional for backward compatibility — pre-1.2.1 clients omit it and
/// receivers fall back to their own local interval.
///
/// `stationary` is the publisher's Movement Aware state at broadcast time.
/// Optional the same way — pre-1.7 clients omit it, and `nil` means "unknown",
/// which is distinct from `false` ("known to be moving"). Receivers must not
/// render an omitted value as moving.
public struct LocationPayload: Codable, Equatable {

    /// Always `"location"`.
    public let type: String

    /// Latitude in decimal degrees.
    public let lat: Double

    /// Longitude in decimal degrees.
    public let lon: Double

    /// Altitude in metres (0 if unavailable).
    public let alt: Double

    /// Horizontal accuracy in metres.
    public let acc: Double

    /// Unix timestamp (seconds since epoch).
    public let ts: Int

    /// Device battery level 0–100, or nil if unavailable.
    public let batt: Int?

    /// Publisher's own location interval in seconds, or nil if pre-1.2.1.
    public let interval: Int?

    // swiftlint:disable discouraged_optional_boolean
    /// Publisher's Movement Aware state, or nil if unknown (pre-1.7 client,
    /// or Movement Aware disabled). Nil is not the same as `false`.
    ///
    /// Deliberately tri-state: the wire field is absent, true, or false, and
    /// collapsing absent into false would render every pre-1.7 member as
    /// known-to-be-moving. Encoded as a plain JSON boolean to match the
    /// Kotlin `Boolean?` on the other side.
    public let stationary: Bool?
    // swiftlint:enable discouraged_optional_boolean

    /// Schema version — always 1.
    public let v: Int

    public static let currentVersion = 1

    // swiftlint:disable discouraged_optional_boolean
    public init(latitude: Double, longitude: Double, altitude: Double,
                accuracy: Double, timestamp: Date, battery: Int? = nil,
                interval: Int? = nil, stationary: Bool? = nil) {
        // swiftlint:enable discouraged_optional_boolean
        self.type = "location"
        self.lat  = latitude
        self.lon  = longitude
        self.alt  = altitude
        self.acc  = accuracy
        self.ts   = Int(timestamp.timeIntervalSince1970)
        self.batt = battery
        self.interval = interval
        self.stationary = stationary
        self.v    = Self.currentVersion
    }

    /// Convert the Unix timestamp back to a `Date`.
    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(ts))
    }

    /// Encode to a JSON string for use as MLS message content.
    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8)!
    }

    /// Decode from a JSON string received in an MLS message.
    public static func from(jsonString: String) throws -> LocationPayload {
        let data = Data(jsonString.utf8)
        try JSONNestingGuard.validate(data)
        return try JSONDecoder().decode(LocationPayload.self, from: data)
    }
}
