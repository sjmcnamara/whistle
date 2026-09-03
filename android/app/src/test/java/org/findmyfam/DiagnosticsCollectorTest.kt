package org.findmyfam

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.findmyfam.models.AppSettings
import org.findmyfam.services.DiagnosticsCollector
import org.findmyfam.services.GroupHealthTracker
import org.findmyfam.services.IdentityService
import org.findmyfam.services.MLSService
import org.findmyfam.services.MarmotService
import org.findmyfam.services.RelayService
import org.findmyfam.shared.models.RelayConfig
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/**
 * Tests for DiagnosticsCollector's mapping of live app state → DiagnosticsReport.
 * The report model's ordering/redaction is covered by DiagnosticsReportTest;
 * this covers the collector. Parity with iOS DiagnosticsCollectorTests.
 *
 * All six injected services are mocked (MockK). Groups are left empty (the
 * MLS-crypto-dependent branch is instrumented-test territory).
 */
class DiagnosticsCollectorTest {

    private lateinit var context: Context
    private lateinit var marmot: MarmotService
    private lateinit var mls: MLSService
    private lateinit var identity: IdentityService
    private lateinit var settings: AppSettings
    private lateinit var relay: RelayService
    private lateinit var collector: DiagnosticsCollector

    @Before
    fun setUp() {
        context = mockk(relaxed = true)
        val pkg = PackageInfo().apply {
            versionName = "1.8.0"
            @Suppress("DEPRECATION")
            versionCode = 46
        }
        every { context.packageName } returns "org.findmyfam"
        every { context.packageManager.getPackageInfo("org.findmyfam", 0) } returns pkg
        every { context.packageManager.getPackageInfo(any<String>(), any<Int>()) } returns pkg

        marmot = mockk(relaxed = true)
        every { marmot.groups } returns MutableStateFlow(emptyList())

        mls = mockk(relaxed = true)

        identity = mockk(relaxed = true)
        every { identity.publicKeyHex } returns "abcd1234ef567890"

        relay = mockk(relaxed = true)
        every { relay.connectedRelayUrls } returns MutableStateFlow(emptyList())

        settings = mockk(relaxed = true)
        every { settings.relays } returns emptyList()
        every { settings.locationIntervalSeconds } returns 3600
        every { settings.isMotionAdaptiveEnabled } returns false
        every { settings.locationFuzzMeters } returns 0
        every { settings.keyRotationIntervalDays } returns 7
        every { settings.isLocationPaused } returns false
        every { settings.lastEventTimestamp } returns 0UL

        collector = DiagnosticsCollector(context, marmot, mls, identity, settings, relay)
    }

    // MARK: - App section

    @Test
    fun reportsAndroidPlatform() = runTest {
        assertEquals("Android", collector.collect().app.platform)
    }

    @Test
    fun reportsPinnedMdkRevision() = runTest {
        val app = collector.collect().app
        assertEquals(DiagnosticsCollector.PINNED_MDK_REVISION, app.mdkRevision)
        assertTrue(app.mdkRevision.isNotEmpty())
    }

    @Test
    fun reportsVersionFromPackageInfo() = runTest {
        val app = collector.collect().app
        assertEquals("1.8.0", app.version)
        assertEquals("46", app.build)
    }

    // MARK: - Groups

    @Test
    fun noActiveGroups_producesNoGroups() = runTest {
        assertTrue(collector.collect().groups.isEmpty())
    }

    // MARK: - Settings mapping

    @Test
    fun settingsSnapshotMirrorsAppSettings() = runTest {
        every { settings.locationIntervalSeconds } returns 900
        every { settings.isMotionAdaptiveEnabled } returns true
        every { settings.locationFuzzMeters } returns 150
        every { settings.keyRotationIntervalDays } returns 14
        every { settings.isLocationPaused } returns true

        val s = collector.collect().settings
        assertEquals(900, s.locationIntervalSeconds)
        assertTrue(s.movementAware)
        assertEquals(150, s.locationFuzzMeters)
        assertEquals(14, s.keyRotationDays)
        assertTrue(s.locationPaused)
    }

    // MARK: - Relays mapping

    @Test
    fun relaysReflectSettingsAndDisconnectedState() = runTest {
        every { settings.relays } returns listOf(
            RelayConfig(url = "wss://alpha.example", isEnabled = true),
            RelayConfig(url = "wss://beta.example", isEnabled = false)
        )
        val relays = collector.collect().relays
        assertEquals(setOf("wss://alpha.example", "wss://beta.example"), relays.map { it.url }.toSet())
        assertTrue("nothing was told to connect", relays.none { it.connected })
        assertEquals(false, relays.first { it.url == "wss://beta.example" }.enabled)
    }

    // MARK: - Volatile / last-event

    @Test
    fun secondsSinceLastEvent_isNull_whenNeverRecorded() = runTest {
        every { settings.lastEventTimestamp } returns 0UL
        assertNull(collector.collect().volatile.secondsSinceLastGroupEvent)
    }

    @Test
    fun secondsSinceLastEvent_isNonNegative_whenRecorded() = runTest {
        every { settings.lastEventTimestamp } returns (System.currentTimeMillis() / 1000 - 60).toULong()
        val seconds = collector.collect().volatile.secondsSinceLastGroupEvent
        assertNotNull(seconds)
        assertTrue(seconds!! >= 0)
    }

    @Test
    fun generatedAt_isIso8601Utc() = runTest {
        assertTrue(collector.collect().volatile.generatedAt.endsWith("Z"))
    }

    // MARK: - Identity redaction

    @Test
    fun identityPrefix_isAtMostEightChars() = runTest {
        assertTrue(collector.collect().identity.pubkeyPrefix.length <= 8)
    }

    // MARK: - Recent failures (GroupHealthTracker failure-type classification)

    @Test
    fun recentFailures_isEmpty_whenNoneRecorded() = runTest {
        every { marmot.healthTracker } returns GroupHealthTracker()
        assertTrue(collector.collect().recentFailures.isEmpty())
    }

    @Test
    fun recentFailures_reflectsHealthTrackerFailureTypes() = runTest {
        val healthTracker = GroupHealthTracker()
        // previouslyFailed carries no group id at the MDK boundary, so this is
        // the only place a permanently-stuck group's failure is ever recorded.
        healthTracker.recordFailureType(GroupHealthTracker.FailureType.PREVIOUSLY_FAILED)
        healthTracker.recordFailureType(GroupHealthTracker.FailureType.PREVIOUSLY_FAILED)
        healthTracker.recordFailureType(GroupHealthTracker.FailureType.UNPROCESSABLE)
        every { marmot.healthTracker } returns healthTracker

        val failures = collector.collect().recentFailures
        assertEquals(2, failures.size)
        assertEquals(2, failures.first { it.type == GroupHealthTracker.FailureType.PREVIOUSLY_FAILED }.count)
        assertEquals(1, failures.first { it.type == GroupHealthTracker.FailureType.UNPROCESSABLE }.count)
    }
}
