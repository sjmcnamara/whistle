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
    private val marmotService: MarmotService,
    private val mls: MLSService,
    private val identity: IdentityService,
    private val settings: AppSettings,
    private val relay: RelayService
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

        val groups = marmotService.groups.value.filter { it.isActive }.map { group ->
            val detail = runCatching { mls.getGroup(group.mlsGroupId) }.getOrNull()
            val admins = detail?.adminPubkeys ?: emptyList()
            DiagnosticsReport.GroupSnapshot(
                id = DiagnosticsReport.shortHex(group.mlsGroupId),
                epoch = detail?.epoch?.toLong() ?: 0L,
                memberCount = runCatching { mls.getMembers(group.mlsGroupId).size }.getOrDefault(0),
                adminCount = admins.size,
                isAdmin = myPubkey in admins,
                healthy = !marmotService.healthTracker.isUnhealthy(group.mlsGroupId),
                consecutiveFailures = marmotService.healthTracker.failureCount(group.mlsGroupId)
            )
        }

        val connected = relay.connectedRelayUrls.value.toSet()
        val relays = settings.relays.map {
            DiagnosticsReport.RelaySnapshot(
                url = it.url,
                enabled = it.isEnabled,
                connected = it.url in connected
            )
        }

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
        val lastEvent = settings.lastEventTimestamp
        val volatile = DiagnosticsReport.Volatile(
            generatedAt = iso.format(Date()),
            // 0 means "never recorded" rather than "just now", so report null.
            secondsSinceLastGroupEvent = if (lastEvent == 0UL) {
                null
            } else {
                maxOf(0L, System.currentTimeMillis() / 1000 - lastEvent.toLong()).toInt()
            }
        )

        return DiagnosticsReport(
            app = app,
            identity = identitySnapshot,
            groups = groups,
            relays = relays,
            settings = settingsSnapshot,
            // Reserved. GroupHealthTracker counts failures per group but does
            // not classify them, and per-group counts already appear above.
            // Populating this needs error-type capture at the MLS boundary.
            recentFailures = emptyList(),
            volatile = volatile
        )
    }

    companion object {
        /**
         * MDK revision this build was compiled against.
         *
         * Hand-maintained, mirroring the iOS constant. **Update this whenever
         * the MDK dependency changes** — a report naming the wrong protocol
         * build is worse than one naming none, because it sends whoever reads
         * it looking at the wrong source.
         */
        const val PINNED_MDK_REVISION = "8a7a0a5"
    }
}
