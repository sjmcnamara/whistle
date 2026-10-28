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
import org.findmyfam.services.IdentityService
import org.findmyfam.services.MarmotKitService
import org.findmyfam.shared.models.RelayConfig
import org.findmyfam.shared.models.WhistleGroup
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/**
 * Tests for DiagnosticsCollector's mapping of live app state → DiagnosticsReport.
 * The report model's ordering/redaction is covered by DiagnosticsReportTest;
 * this covers the collector. Parity with iOS DiagnosticsCollectorTests.
 *
 * The injected services are mocked (MockK); MarmotKit's native library cannot
 * load in a JVM test, so nothing here touches a real runtime.
 */
class DiagnosticsCollectorTest {

    private lateinit var context: Context
    private lateinit var marmot: MarmotKitService
    private lateinit var identity: IdentityService
    private lateinit var settings: AppSettings
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

        identity = mockk(relaxed = true)
        every { identity.publicKeyHex } returns "abcd1234ef567890"

        every { marmot.relayStatus } returns MutableStateFlow(MarmotKitService.RelayStatus())

        settings = mockk(relaxed = true)
        every { settings.relays } returns emptyList()
        every { settings.locationIntervalSeconds } returns 3600
        every { settings.isMotionAdaptiveEnabled } returns false
        every { settings.locationFuzzMeters } returns 0
        every { settings.keyRotationIntervalDays } returns 7
        every { settings.isLocationPaused } returns false
        every { settings.lastEventTimestamp } returns 0UL

        collector = DiagnosticsCollector(context, marmot, identity, settings)
    }

    private fun group(lastMessageAt: Long?) = WhistleGroup(
        mlsGroupId = "abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234",
        name = "Test",
        isActive = true,
        epoch = 1,
        adminPubkeys = emptyList(),
        lastMessageAt = lastMessageAt,
    )

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

    // MARK: - Per-group last-event (v2: moved out of Volatile into GroupSnapshot)

    @Test
    fun groupSnapshot_secondsSinceLastEvent_reflectsThatGroupsLastMessageAt() = runTest {
        val lastMessageAt = System.currentTimeMillis() / 1000 - 60
        val group = group(lastMessageAt = lastMessageAt)
        every { marmot.groups } returns MutableStateFlow(listOf(group))

        val snapshot = collector.collect().groups.first()
        val seconds = snapshot.secondsSinceLastEvent
        assertNotNull(seconds)
        assertTrue(seconds!! >= 0)
    }

    @Test
    fun groupSnapshot_secondsSinceLastEvent_isNullWhenGroupHasNoLastMessageAt() = runTest {
        val group = group(lastMessageAt = null)
        every { marmot.groups } returns MutableStateFlow(listOf(group))

        // null lastMessageAt must stay null ("never recorded"), not 0 ("just now").
        assertNull(collector.collect().groups.first().secondsSinceLastEvent)
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
    fun relaysReflectSettingsAndPolicy() = runTest {
        every { marmot.relayStatus } returns MutableStateFlow(
            MarmotKitService.RelayStatus(policies = mapOf("wss://alpha.example" to "retired"))
        )
        every { settings.relays } returns listOf(
            RelayConfig(url = "wss://alpha.example", isEnabled = true),
            RelayConfig(url = "wss://beta.example", isEnabled = false)
        )
        val relays = collector.collect().relays
        assertEquals(setOf("wss://alpha.example", "wss://beta.example"), relays.map { it.url }.toSet())
        assertEquals("retired", relays.first { it.url == "wss://alpha.example" }.policy)
        assertNull(relays.first { it.url == "wss://beta.example" }.policy)
        assertEquals(false, relays.first { it.url == "wss://beta.example" }.enabled)
    }

    // MARK: - Volatile / generatedAt

    @Test
    fun generatedAt_isIso8601Utc() = runTest {
        assertTrue(collector.collect().volatile.generatedAt.endsWith("Z"))
    }

    // MARK: - Identity redaction

    @Test
    fun identityPrefix_isAtMostEightChars() = runTest {
        assertTrue(collector.collect().identity.pubkeyPrefix.length <= 8)
    }

    // MARK: - Recent failures

    @Test
    fun recentFailures_isEmpty() = runTest {
        // v1 tallied decrypt failures by type; MarmotKit reports an
        // unrecoverable group as a typed error, so there is nothing to count.
        assertTrue(collector.collect().recentFailures.isEmpty())
    }
}
