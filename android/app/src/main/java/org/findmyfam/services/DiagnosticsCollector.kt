package org.findmyfam.services

import android.content.Context
import android.os.Build
import dagger.hilt.android.qualifiers.ApplicationContext
import org.findmyfam.models.AppSettings
import org.findmyfam.shared.models.DiagnosticsReport
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Assembles a [DiagnosticsReport] from live app state.
 *
 * Deliberately reads rather than caches: a report is only useful if it
 * reflects the device at the moment the user hit "share", not at launch.
 */
@Singleton
class DiagnosticsCollector @Inject constructor(
    @ApplicationContext private val context: Context,
    private val marmot: MarmotKitService,
    private val identity: IdentityService,
    private val settings: AppSettings,
) {
    suspend fun collect(): DiagnosticsReport {
        // Read from the package manager rather than BuildConfig — buildConfig
        // is not enabled for this module, and SettingsScreen already sources
        // the version the same way.
        val pkg = runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0)
        }.getOrNull()
        @Suppress("DEPRECATION") // longVersionCode requires API 28; minSdk is 26
        val versionCode = pkg?.versionCode?.toString() ?: "?"
        val app = DiagnosticsReport.App(
            version = pkg?.versionName ?: "?",
            build = versionCode,
            platform = "Android",
            os = Build.VERSION.RELEASE ?: "?",
            mdkRevision = PINNED_MDK_REVISION
        )

        val myPubkey = identity.publicKeyHex ?: ""
        val identitySnapshot = DiagnosticsReport.Identity(
            pubkeyPrefix = DiagnosticsReport.shortHex(myPubkey)
        )

        val now = System.currentTimeMillis() / 1000
        val groups = marmot.groups.value.filter { it.isActive }.map { group ->
            // Re-read live rather than trusting the published cache: a report
            // is only useful if its epoch and admin list reflect the group
            // state right now.
            val detail = runCatching { marmot.group(group.mlsGroupId) }.getOrNull()
            val admins = detail?.adminPubkeys ?: group.adminPubkeys
            DiagnosticsReport.GroupSnapshot(
                id = DiagnosticsReport.shortHex(group.mlsGroupId),
                epoch = detail?.epoch ?: group.epoch,
                memberCount = runCatching { marmot.members(group.mlsGroupId).size }.getOrDefault(0),
                adminCount = admins.size,
                isAdmin = myPubkey in admins,
                // v1 inferred health by counting consecutive decrypt failures.
                // MarmotKit reports an unrecoverable group outright, so there
                // is nothing to tally — a group that loads is healthy by the
                // only measure available.
                healthy = true,
                consecutiveFailures = 0,
                // group.lastMessageAt advances on any group event (location,
                // chat, nickname, commit) -- null means never recorded.
                secondsSinceLastEvent = group.lastMessageAt?.let { maxOf(0L, now - it).toInt() },
                // Not exposed by MarmotKit's domain-level API — it was an MLS
                // ratchet-tree detail of the low-level bindings.
                ownLeafIndex = null,
            )
        }

        // Relay state comes from MarmotKit, and is refreshed here rather than
        // read as-is: `relayStatus` is a cache, and the only other thing that
        // fills it is the Advanced Settings screen. A bundle generated without
        // visiting that screen would otherwise report the default —
        // disconnected, 0 of 0.
        marmot.refreshRelayStatus(
            all = settings.relays.map { it.url },
            enabled = settings.relays.filter { it.isEnabled }.map { it.url },
        )
        val status = marmot.relayStatus.value
        val relays = settings.relays.map {
            DiagnosticsReport.RelaySnapshot(
                url = it.url,
                enabled = it.isEnabled,
                policy = status.policies[it.url],
            )
        }
        val relayConnectivity = "${status.connection.name.lowercase()} " +
            "(${status.connected} of ${status.total})"

        val settingsSnapshot = DiagnosticsReport.Settings(
            locationIntervalSeconds = settings.locationIntervalSeconds,
            movementAware = settings.isMotionAdaptiveEnabled,
            locationFuzzMeters = settings.locationFuzzMeters,
            keyRotationDays = settings.keyRotationIntervalDays,
            locationPaused = settings.isLocationPaused
        )

        val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }
        val volatile = DiagnosticsReport.Volatile(generatedAt = iso.format(Date()))

        // Always empty under protocol v2. v1 tallied decrypt failures by type
        // because the MDK boundary gave it nothing better to go on. MarmotKit
        // reports an unrecoverable group as a typed error instead, so there is
        // no tally. The field stays in the report rather than being dropped, so
        // an older diagnostics bundle still decodes.
        val recentFailures = emptyList<DiagnosticsReport.FailureCount>()

        return DiagnosticsReport(
            app = app,
            identity = identitySnapshot,
            groups = groups,
            relays = relays,
            settings = settingsSnapshot,
            recentFailures = recentFailures,
            volatile = volatile,
            relayConnectivity = relayConnectivity
        )
    }

    companion object {
        /**
         * MDK build this app was compiled against.
         *
         * Hand-maintained, mirroring the iOS constant, because the pin lives
         * in a build input (`scripts/vendor_marmotkit_android.py`) rather than
         * anywhere readable at runtime. **Update this whenever that pin
         * changes** — a report naming the wrong protocol build is worse than
         * one naming none, because it sends whoever reads it looking at the
         * wrong source.
         *
         * Names the MarmotKit release rather than an mdk-swift commit: the app
         * runs protocol v2, and the two are not wire-compatible, so a report
         * still citing `8a7a0a5` (MDK 0.8.0 / protocol v1) would point at the
         * wrong protocol entirely.
         */
        const val PINNED_MDK_REVISION = "marmotkit-v0.11.0"
    }
}
