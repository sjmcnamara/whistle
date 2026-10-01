import XCTest
import NostrSDK
import WhistleCore
@testable import Whistle

/// Tests for DiagnosticsCollector — the assembler that reads live app state into
/// a DiagnosticsReport. The report *model* (ordering/redaction) is covered by
/// DiagnosticsReportTests; this covers the collector's mapping of services →
/// snapshot.
@MainActor
final class DiagnosticsCollectorTests: XCTestCase {

    private var mls: MLSService!
    private var identity: IdentityService!
    private var relay: RelayService!
    private let settings = AppSettings.shared

    // Snapshot of the singleton settings we mutate, restored in tearDown.
    private var savedRelays: [RelayConfig]!
    private var savedInterval: Int!
    private var savedMotion: Bool!
    private var savedFuzz: Int!
    private var savedRotation: Int!
    private var savedPaused: Bool!
    private var savedLastEvent: UInt64!

    override func setUp() async throws {
        try await super.setUp()
        mls = MLSService()
        try await mls.initialiseInMemory()
        identity = IdentityService()
        relay = RelayService()

        savedRelays = settings.relays
        savedInterval = settings.locationIntervalSeconds
        savedMotion = settings.isMotionAdaptiveEnabled
        savedFuzz = settings.locationFuzzMeters
        savedRotation = settings.keyRotationIntervalDays
        savedPaused = settings.isLocationPaused
        savedLastEvent = settings.lastEventTimestamp
    }

    override func tearDown() async throws {
        settings.relays = savedRelays
        settings.locationIntervalSeconds = savedInterval
        settings.isMotionAdaptiveEnabled = savedMotion
        settings.locationFuzzMeters = savedFuzz
        settings.keyRotationIntervalDays = savedRotation
        settings.isLocationPaused = savedPaused
        settings.lastEventTimestamp = savedLastEvent
        mls = nil; identity = nil; relay = nil
    }

    private func collect() async -> DiagnosticsReport {
        await DiagnosticsCollector.collect(
            marmot: nil, identity: identity, settings: settings, relay: relay
        )
    }

    // MARK: - App section

    func testReportsIOSPlatform() async {
        let r = await collect()
        XCTAssertEqual(r.app.platform, "iOS")
    }

    func testReportsPinnedMDKRevision() async {
        let r = await collect()
        // The collector's hand-maintained pin must be what lands in the report;
        // a mismatch here means the constant drifted from what we ship.
        XCTAssertEqual(r.app.mdkRevision, DiagnosticsCollector.pinnedMDKRevision)
        XCTAssertFalse(r.app.mdkRevision.isEmpty)
    }

    // MARK: - Groups (nil marmot → none)

    func testNilMarmotProducesNoGroups() async {
        let r = await collect()
        XCTAssertTrue(r.groups.isEmpty)
    }

    // MARK: - Settings mapping

    func testSettingsSnapshotMirrorsAppSettings() async {
        settings.locationIntervalSeconds = 900
        settings.isMotionAdaptiveEnabled = true
        settings.locationFuzzMeters = 150
        settings.keyRotationIntervalDays = 14
        settings.isLocationPaused = true

        let r = await collect()
        XCTAssertEqual(r.settings.locationIntervalSeconds, 900)
        XCTAssertEqual(r.settings.movementAware, true)
        XCTAssertEqual(r.settings.locationFuzzMeters, 150)
        XCTAssertEqual(r.settings.keyRotationDays, 14)
        XCTAssertEqual(r.settings.locationPaused, true)
    }

    // MARK: - Relays mapping

    func testRelaysReflectSettingsAndDisconnectedState() async {
        settings.relays = [
            RelayConfig(url: "wss://alpha.example", isEnabled: true),
            RelayConfig(url: "wss://beta.example", isEnabled: false)
        ]
        let r = await collect()
        XCTAssertEqual(Set(r.relays.map(\.url)), ["wss://alpha.example", "wss://beta.example"])
        // Nothing is connected (RelayService never told to connect).
        XCTAssertTrue(r.relays.allSatisfy { !$0.connected })
        XCTAssertEqual(r.relays.first(where: { $0.url == "wss://beta.example" })?.enabled, false)
    }

    // MARK: - Volatile / generatedAt

    func testGeneratedAtIsISO8601UTC() async {
        let r = await collect()
        // e.g. 2026-07-22T10:11:12Z
        XCTAssertTrue(r.volatile.generatedAt.hasSuffix("Z"))
        XCTAssertNotNil(ISO8601DateFormatter().date(from: r.volatile.generatedAt))
    }

    // MARK: - Identity redaction

    func testIdentityPrefixIsAtMostEightChars() async {
        let r = await collect()
        XCTAssertLessThanOrEqual(r.identity.pubkeyPrefix.count, 8)
    }

    // MARK: - Per-group last-event (v2: moved out of Volatile into GroupSnapshot)

    // `secondsSinceLastEvent` against a real group's `lastMessageAt` moved to
    // `MarmotKitTwoDeviceTests` — asserting it needs a group, and building one
    // now means a running MarmotKit account rather than an in-memory MLS
    // service, which that harness already stands up.

    // MARK: - Recent failures

    func testRecentFailuresIsEmptyWhenNoneRecorded() async {
        let r = await collect()
        XCTAssertTrue(r.recentFailures.isEmpty)
    }

    // Failure-type tallying was v1's only way to recognise a permanently stuck
    // group — `previouslyFailed` carries no group id at the MDK boundary, so
    // counting was all there was. v2 removes both the tracker and the need for
    // it, so `recentFailures` is now always empty and the test asserting it
    // reflected the tracker has nothing left to assert.
}
