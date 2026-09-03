import Foundation
import UIKit
import WhistleCore

/// Assembles a `DiagnosticsReport` from live app state.
///
/// Deliberately reads rather than caches: a report is only useful if it
/// reflects the device at the moment the user hit "share", not at launch.
@MainActor
enum DiagnosticsCollector {

    /// MDK revision this build was compiled against.
    ///
    /// Hand-maintained because the pin lives in `project.yml`, which is a build
    /// input rather than something readable at runtime. **Update this whenever
    /// the `MDKBindings` revision changes** — a report naming the wrong
    /// protocol build is worse than one naming none, because it sends whoever
    /// reads it looking at the wrong source.
    static let pinnedMDKRevision = "8a7a0a5"

    static func collect(
        marmot: MarmotService?,
        mls: MLSService,
        identity: IdentityService,
        settings: AppSettings,
        relay: RelayService
    ) async -> DiagnosticsReport {
        let bundle = Bundle.main
        let app = DiagnosticsReport.App(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            platform: "iOS",
            os: UIDevice.current.systemVersion,
            mdkRevision: pinnedMDKRevision
        )

        let myPubkey = identity.identity?.publicKeyHex ?? ""
        let identitySnapshot = DiagnosticsReport.Identity(
            pubkeyPrefix: DiagnosticsReport.shortHex(myPubkey)
        )

        var groups: [DiagnosticsReport.GroupSnapshot] = []
        if let marmot {
            for group in marmot.groups where group.isActive {
                let detail = try? await mls.getGroup(mlsGroupId: group.mlsGroupId)
                let admins = detail?.adminPubkeys ?? []
                groups.append(
                    DiagnosticsReport.GroupSnapshot(
                        id: DiagnosticsReport.shortHex(group.mlsGroupId),
                        epoch: detail?.epoch ?? 0,
                        memberCount: (try? await mls.getMembers(groupId: group.mlsGroupId))?.count ?? 0,
                        adminCount: admins.count,
                        isAdmin: admins.contains(myPubkey),
                        healthy: !marmot.healthTracker.isUnhealthy(groupId: group.mlsGroupId),
                        consecutiveFailures: marmot.healthTracker.failureCount(for: group.mlsGroupId)
                    )
                )
            }
        }

        let connected = Set(relay.connectedRelayURLs)
        let relays = settings.relays.map {
            DiagnosticsReport.RelaySnapshot(
                url: $0.url,
                enabled: $0.isEnabled,
                connected: connected.contains($0.url)
            )
        }

        let settingsSnapshot = DiagnosticsReport.Settings(
            locationIntervalSeconds: settings.locationIntervalSeconds,
            movementAware: settings.isMotionAdaptiveEnabled,
            locationFuzzMeters: settings.locationFuzzMeters,
            keyRotationDays: settings.keyRotationIntervalDays,
            locationPaused: settings.isLocationPaused
        )

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        let volatile = DiagnosticsReport.Volatile(
            generatedAt: formatter.string(from: Date()),
            // 0 means "never recorded" rather than "just now", so report nil.
            secondsSinceLastGroupEvent: settings.lastEventTimestamp == 0
                ? nil
                : max(0, Int(Date().timeIntervalSince1970) - Int(settings.lastEventTimestamp))
        )

        let recentFailures = (marmot?.healthTracker.failureTypeCountsSnapshot() ?? [:]).map {
            DiagnosticsReport.FailureCount(type: $0.key, count: $0.value)
        }

        return DiagnosticsReport(
            app: app,
            identity: identitySnapshot,
            groups: groups,
            relays: relays,
            settings: settingsSnapshot,
            recentFailures: recentFailures,
            volatile: volatile
        )
    }
}
