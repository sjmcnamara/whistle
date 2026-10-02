import Foundation
import UIKit
import WhistleCore

/// Assembles a `DiagnosticsReport` from live app state.
///
/// Deliberately reads rather than caches: a report is only useful if it
/// reflects the device at the moment the user hit "share", not at launch.
@MainActor
enum DiagnosticsCollector {

    /// MDK build this app was compiled against.
    ///
    /// Hand-maintained because the pin lives in a build input
    /// (`MarmotKitBindings/Package.swift`) rather than anywhere readable at
    /// runtime. **Update this whenever that pin changes** — a report naming
    /// the wrong protocol build is worse than one naming none, because it
    /// sends whoever reads it looking at the wrong source.
    ///
    /// Now names the MarmotKit release rather than an mdk-swift commit: the
    /// app target runs protocol v2, and the two are not wire-compatible, so a
    /// report still citing `8a7a0a5` (MDK 0.8.0 / protocol v1) would point at
    /// the wrong protocol entirely.
    static let pinnedMDKRevision = "marmotkit-v0.10.4"

    static func collect(
        marmot: MarmotKitService?,
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

        let now = Int(Date().timeIntervalSince1970)
        var groups: [DiagnosticsReport.GroupSnapshot] = []
        if let marmot {
            for group in marmot.groups where group.isActive {
                // Re-read live rather than trusting the published cache: a
                // report is only useful if its epoch and admin list reflect
                // the MLS state right now.
                let detail = try? await marmot.group(id: group.mlsGroupId)
                let admins = detail?.adminPubkeys ?? []
                groups.append(
                    DiagnosticsReport.GroupSnapshot(
                        id: DiagnosticsReport.shortHex(group.mlsGroupId),
                        epoch: detail?.epoch ?? 0,
                        memberCount: (try? await marmot.members(ofGroup: group.mlsGroupId))?.count ?? 0,
                        adminCount: admins.count,
                        isAdmin: admins.contains(myPubkey),
                        // v1 inferred health by counting consecutive decrypt
                        // failures. MarmotKit reports an unrecoverable group
                        // outright, so there is nothing to tally — a group
                        // that loads is healthy by the only measure available.
                        healthy: true,
                        consecutiveFailures: 0,
                        secondsSinceLastEvent: group.lastMessageAt.map { max(0, now - Int($0)) },
                        // Not exposed by MarmotKit's domain-level API — it
                        // was an MLS ratchet-tree detail of the low-level
                        // bindings, with no equivalent here.
                        ownLeafIndex: nil
                    )
                )
            }
        }

        // Read from MarmotKit, not `RelayService`. The v2 startup path never
        // connects the v1 service, so `relay.connectedRelayURLs` is always
        // empty — the bundle reported every relay as disconnected while
        // MarmotKit was connected to both.
        //
        // Refreshed here rather than read as-is: `relayStatus` is a cache, and
        // the only other thing that fills it is the Advanced Settings screen's
        // poll. A bundle generated without visiting that screen would
        // otherwise report the default — disconnected, 0 of 0.
        await marmot?.refreshRelayStatus(configured: settings.relays.map(\.url))
        let status = marmot?.relayStatus
        let relays = settings.relays.map {
            DiagnosticsReport.RelaySnapshot(
                url: $0.url,
                enabled: $0.isEnabled,
                policy: status?.policies[$0.url]
            )
        }
        let relayConnectivity = status.map { summary -> String in
            let state: String
            switch summary.connection {
            case .connected: state = "connected"
            case .connecting: state = "connecting"
            case .disconnected: state = "disconnected"
            }
            return "\(state) (\(summary.connected) of \(summary.total))"
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
        let volatile = DiagnosticsReport.Volatile(generatedAt: formatter.string(from: Date()))

        // Always empty under protocol v2. v1 tallied decrypt failures by type
        // because the MDK boundary gave it nothing better to go on — a stuck
        // group could only be recognised by counting how often it failed.
        // MarmotKit reports an unrecoverable group as a typed error instead, so
        // there is no tally to report. The field stays in the report rather
        // than being dropped, so an older diagnostics bundle still decodes.
        let recentFailures: [DiagnosticsReport.FailureCount] = []

        return DiagnosticsReport(
            app: app,
            identity: identitySnapshot,
            groups: groups,
            relays: relays,
            settings: settingsSnapshot,
            recentFailures: recentFailures,
            volatile: volatile,
            relayConnectivity: relayConnectivity
        )
    }
}
