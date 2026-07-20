import XCTest
@testable import Whistle
import WhistleCore

final class DiagnosticsReportTests: XCTestCase {

    private func report(
        groups: [DiagnosticsReport.GroupSnapshot] = [],
        relays: [DiagnosticsReport.RelaySnapshot] = [],
        failures: [DiagnosticsReport.FailureCount] = [],
        generatedAt: String = "2026-07-20T12:00:00Z"
    ) -> DiagnosticsReport {
        DiagnosticsReport(
            app: .init(version: "1.8.0", build: "46", platform: "iOS", os: "26.0", mdkRevision: "8a7a0a5"),
            identity: .init(pubkeyPrefix: "45de1c25"),
            groups: groups,
            relays: relays,
            settings: .init(locationIntervalSeconds: 3600, movementAware: true,
                            locationFuzzMeters: 0, keyRotationDays: 7, locationPaused: false),
            recentFailures: failures,
            volatile: .init(generatedAt: generatedAt, secondsSinceLastGroupEvent: 42)
        )
    }

    private func group(_ id: String, epoch: UInt64 = 1) -> DiagnosticsReport.GroupSnapshot {
        .init(id: id, epoch: epoch, memberCount: 3, adminCount: 1,
              isAdmin: true, healthy: true, consecutiveFailures: 0)
    }

    // MARK: - Deterministic ordering

    func testGroupsAreSortedById() {
        let r = report(groups: [group("cccccccc"), group("aaaaaaaa"), group("bbbbbbbb")])
        XCTAssertEqual(r.groups.map(\.id), ["aaaaaaaa", "bbbbbbbb", "cccccccc"])
    }

    func testRelaysAreSortedByURL() {
        let r = report(relays: [
            .init(url: "wss://zebra.example", enabled: true, connected: true),
            .init(url: "wss://alpha.example", enabled: true, connected: false)
        ])
        XCTAssertEqual(r.relays.map(\.url), ["wss://alpha.example", "wss://zebra.example"])
    }

    func testFailuresAreSortedByType() {
        let r = report(failures: [.init(type: "zeta", count: 1), .init(type: "alpha", count: 2)])
        XCTAssertEqual(r.recentFailures.map(\.type), ["alpha", "zeta"])
    }

    func testInputOrderDoesNotAffectOutput() throws {
        // The whole point: two devices listing the same groups in different
        // orders must produce byte-identical JSON, or a diff is meaningless.
        let a = report(groups: [group("aaaaaaaa"), group("bbbbbbbb")])
        let b = report(groups: [group("bbbbbbbb"), group("aaaaaaaa")])
        XCTAssertEqual(try a.jsonString(), try b.jsonString())
    }

    func testJSONKeysAreSorted() throws {
        let json = try report(groups: [group("aaaaaaaa")]).jsonString()
        // `app` precedes `groups` precedes `identity` — alphabetical, not
        // declaration order, which is what makes the diff stable across
        // future field additions.
        let appIdx = try XCTUnwrap(json.range(of: "\"app\""))
        let groupsIdx = try XCTUnwrap(json.range(of: "\"groups\""))
        let identityIdx = try XCTUnwrap(json.range(of: "\"identity\""))
        XCTAssertTrue(appIdx.lowerBound < groupsIdx.lowerBound)
        XCTAssertTrue(groupsIdx.lowerBound < identityIdx.lowerBound)
    }

    // MARK: - Diffability

    func testOnlyVolatileDiffersBetweenOtherwiseIdenticalReports() throws {
        let a = try report(generatedAt: "2026-07-20T12:00:00Z").jsonString()
        let b = try report(generatedAt: "2026-07-20T13:00:00Z").jsonString()
        let differing = zip(a.split(separator: "\n"), b.split(separator: "\n"))
            .filter { $0 != $1 }
        // A timestamp difference must not ripple through the document.
        XCTAssertEqual(differing.count, 1)
        XCTAssertTrue(differing.first?.0.contains("generatedAt") == true)
    }

    func testEpochDifferenceIsVisibleOnItsOwnLine() throws {
        // A fork is exactly this: same group, different epoch. It must show up
        // as a single changed line.
        let a = try report(groups: [group("aaaaaaaa", epoch: 12)]).jsonString()
        let b = try report(groups: [group("aaaaaaaa", epoch: 13)]).jsonString()
        let differing = zip(a.split(separator: "\n"), b.split(separator: "\n"))
            .filter { $0 != $1 }
        XCTAssertEqual(differing.count, 1)
        XCTAssertTrue(differing.first?.0.contains("epoch") == true)
    }

    // MARK: - Round trip

    func testRoundTrip() throws {
        let original = report(
            groups: [group("aaaaaaaa", epoch: 7)],
            relays: [.init(url: "wss://relay.example", enabled: true, connected: true)],
            failures: [.init(type: "cannotDecrypt", count: 2)]
        )
        XCTAssertEqual(try DiagnosticsReport.from(jsonString: original.jsonString()), original)
    }

    func testSchemaVersionIsRecorded() {
        XCTAssertEqual(report().schema, DiagnosticsReport.schemaVersion)
    }

    // MARK: - Privacy

    func testShortHexTruncatesToEightCharacters() {
        let full = String(repeating: "a", count: 64)
        XCTAssertEqual(DiagnosticsReport.shortHex(full).count, 8)
    }

    func testShortHexHandlesShortInput() {
        XCTAssertEqual(DiagnosticsReport.shortHex("abc"), "abc")
    }

    func testReportCarriesNoFullLengthHexKeys() throws {
        // Guards the rule rather than the current field list: if someone adds a
        // field later and puts a full pubkey or group id in it, this fails.
        let json = try report(
            groups: [group("aaaaaaaa")],
            relays: [.init(url: "wss://relay.example", enabled: true, connected: true)]
        ).jsonString()
        let longHex = try NSRegularExpression(pattern: "[0-9a-f]{32,}")
        let matches = longHex.numberOfMatches(
            in: json, range: NSRange(json.startIndex..., in: json)
        )
        XCTAssertEqual(matches, 0, "diagnostics must not contain full-length hex identifiers")
    }
}
