import Foundation

/// A snapshot of app and group state, safe to share publicly.
///
/// Exists to make a fork diagnosable from outside the device. A fork is two
/// members sitting on different epochs for the same group — obvious when two
/// reports are placed side by side, and invisible in prose. So the format is
/// JSON with **deterministic ordering**: sorted keys, groups sorted by id,
/// relays by URL, failures by type. Two reports from two devices should differ
/// only where the devices genuinely differ.
///
/// ## What must never appear here
///
/// The report is meant to be pasteable into a public issue, so it carries no
/// message content, no locations, no nicknames (they name family members), no
/// secret key material, and no full public keys — those are truncated to the
/// same 8-character prefix the logs use. Adding a field means asking whether a
/// stranger reading it learns anything about the family.
public struct DiagnosticsReport: Codable, Equatable {

    /// Bumped when the shape changes, so an old report is still readable.
    public static let schemaVersion = 1

    public let schema: Int
    public let app: App
    public let identity: Identity
    /// Sorted by `id`.
    public let groups: [GroupSnapshot]
    /// Sorted by `url`.
    public let relays: [RelaySnapshot]
    public let settings: Settings
    /// Sorted by `type`.
    public let recentFailures: [FailureCount]
    /// Values expected to differ between any two reports — kept together so the
    /// rest of the document diffs cleanly.
    public let volatile: Volatile

    public struct App: Codable, Equatable {
        public let version: String
        public let build: String
        public let platform: String
        public let os: String
        /// Pinned MDK revision, so a report names the protocol code it ran.
        public let mdkRevision: String

        public init(version: String, build: String, platform: String, os: String, mdkRevision: String) {
            self.version = version
            self.build = build
            self.platform = platform
            self.os = os
            self.mdkRevision = mdkRevision
        }
    }

    public struct Identity: Codable, Equatable {
        /// First 8 hex characters only — enough to correlate two reports, not
        /// enough to identify the person.
        public let pubkeyPrefix: String

        public init(pubkeyPrefix: String) {
            self.pubkeyPrefix = pubkeyPrefix
        }
    }

    public struct GroupSnapshot: Codable, Equatable {
        /// First 8 hex characters of the MLS group id.
        public let id: String
        /// The number that matters: members on different epochs are forked.
        public let epoch: UInt64
        public let memberCount: Int
        public let adminCount: Int
        public let isAdmin: Bool
        /// From `GroupHealthTracker` — whether recent MLS operations failed.
        public let healthy: Bool
        /// Consecutive MLS failures recorded for this group.
        public let consecutiveFailures: Int

        public init(id: String, epoch: UInt64, memberCount: Int, adminCount: Int,
                    isAdmin: Bool, healthy: Bool, consecutiveFailures: Int) {
            self.id = id
            self.epoch = epoch
            self.memberCount = memberCount
            self.adminCount = adminCount
            self.isAdmin = isAdmin
            self.healthy = healthy
            self.consecutiveFailures = consecutiveFailures
        }
    }

    public struct RelaySnapshot: Codable, Equatable {
        public let url: String
        public let enabled: Bool
        public let connected: Bool

        public init(url: String, enabled: Bool, connected: Bool) {
            self.url = url
            self.enabled = enabled
            self.connected = connected
        }
    }

    public struct Settings: Codable, Equatable {
        public let locationIntervalSeconds: Int
        public let movementAware: Bool
        public let locationFuzzMeters: Int
        public let keyRotationDays: Int
        public let locationPaused: Bool

        public init(locationIntervalSeconds: Int, movementAware: Bool, locationFuzzMeters: Int,
                    keyRotationDays: Int, locationPaused: Bool) {
            self.locationIntervalSeconds = locationIntervalSeconds
            self.movementAware = movementAware
            self.locationFuzzMeters = locationFuzzMeters
            self.keyRotationDays = keyRotationDays
            self.locationPaused = locationPaused
        }
    }

    /// An error *type* and how often it occurred. Never the message body — those
    /// can contain group or member identifiers.
    public struct FailureCount: Codable, Equatable {
        public let type: String
        public let count: Int

        public init(type: String, count: Int) {
            self.type = type
            self.count = count
        }
    }

    public struct Volatile: Codable, Equatable {
        /// ISO-8601, UTC.
        public let generatedAt: String
        /// Seconds since this device last processed any group event.
        public let secondsSinceLastGroupEvent: Int?

        public init(generatedAt: String, secondsSinceLastGroupEvent: Int?) {
            self.generatedAt = generatedAt
            self.secondsSinceLastGroupEvent = secondsSinceLastGroupEvent
        }
    }

    public init(app: App, identity: Identity, groups: [GroupSnapshot], relays: [RelaySnapshot],
                settings: Settings, recentFailures: [FailureCount], volatile: Volatile) {
        self.schema = Self.schemaVersion
        self.app = app
        self.identity = identity
        // Sorting happens here rather than at the call sites so no caller can
        // produce a report that diffs badly.
        self.groups = groups.sorted { $0.id < $1.id }
        self.relays = relays.sorted { $0.url < $1.url }
        self.settings = settings
        self.recentFailures = recentFailures.sorted { $0.type < $1.type }
        self.volatile = volatile
    }

    /// Pretty-printed JSON with sorted keys, newline-terminated.
    ///
    /// `.sortedKeys` is what makes two reports comparable with a plain diff;
    /// `.prettyPrinted` puts one field per line so a diff points at the field
    /// that changed rather than the whole document.
    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8)! + "\n"
    }

    public static func from(jsonString: String) throws -> DiagnosticsReport {
        try JSONDecoder().decode(DiagnosticsReport.self, from: Data(jsonString.utf8))
    }

    /// Truncate a hex key to the 8-character prefix used throughout the report
    /// and the logs.
    public static func shortHex(_ hex: String) -> String {
        String(hex.prefix(8))
    }
}
