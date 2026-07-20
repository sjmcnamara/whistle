package org.findmyfam.shared

import org.findmyfam.shared.models.DiagnosticsReport
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class DiagnosticsReportTest {

    private fun group(id: String, epoch: Long = 1L) = DiagnosticsReport.GroupSnapshot(
        id = id, epoch = epoch, memberCount = 3, adminCount = 1,
        isAdmin = true, healthy = true, consecutiveFailures = 0
    )

    private fun report(
        groups: List<DiagnosticsReport.GroupSnapshot> = emptyList(),
        relays: List<DiagnosticsReport.RelaySnapshot> = emptyList(),
        failures: List<DiagnosticsReport.FailureCount> = emptyList(),
        generatedAt: String = "2026-07-20T12:00:00Z"
    ) = DiagnosticsReport(
        app = DiagnosticsReport.App("1.8.0", "46", "Android", "15", "8a7a0a5"),
        identity = DiagnosticsReport.Identity("45de1c25"),
        groups = groups,
        relays = relays,
        settings = DiagnosticsReport.Settings(3600, true, 0, 7, false),
        recentFailures = failures,
        volatile = DiagnosticsReport.Volatile(generatedAt, 42)
    )

    // region deterministic ordering

    @Test
    fun `groups are sorted by id`() {
        val r = report(groups = listOf(group("cccccccc"), group("aaaaaaaa"), group("bbbbbbbb")))
        assertEquals(listOf("aaaaaaaa", "bbbbbbbb", "cccccccc"), r.sortedGroups.map { it.id })
    }

    @Test
    fun `relays are sorted by url`() {
        val r = report(relays = listOf(
            DiagnosticsReport.RelaySnapshot("wss://zebra.example", true, true),
            DiagnosticsReport.RelaySnapshot("wss://alpha.example", true, false)
        ))
        assertEquals(
            listOf("wss://alpha.example", "wss://zebra.example"),
            r.sortedRelays.map { it.url }
        )
    }

    @Test
    fun `input order does not affect output`() {
        // The whole point: two devices listing the same groups in different
        // orders must produce identical JSON, or a diff is meaningless.
        val a = report(groups = listOf(group("aaaaaaaa"), group("bbbbbbbb"))).toJson()
        val b = report(groups = listOf(group("bbbbbbbb"), group("aaaaaaaa"))).toJson()
        assertEquals(a, b)
    }

    @Test
    fun `json keys are emitted in sorted order`() {
        // Guards against relying on org.json's iteration order: the JVM
        // implementation backs onto a HashMap, so a renderer that trusted
        // insertion order would pass by luck and fail unpredictably.
        val json = report(groups = listOf(group("aaaaaaaa"))).toJson()
        val appIdx = json.indexOf("\"app\"")
        val groupsIdx = json.indexOf("\"groups\"")
        val identityIdx = json.indexOf("\"identity\"")
        val schemaIdx = json.indexOf("\"schema\"")
        assertTrue(appIdx in 0 until groupsIdx, "app must precede groups")
        assertTrue(groupsIdx < identityIdx, "groups must precede identity")
        assertTrue(identityIdx < schemaIdx, "identity must precede schema")
    }

    @Test
    fun `output is stable across repeated renders`() {
        val r = report(groups = listOf(group("aaaaaaaa"), group("bbbbbbbb")))
        val renders = (1..20).map { r.toJson() }.toSet()
        assertEquals(1, renders.size, "render must be deterministic")
    }

    // endregion

    // region diffability

    @Test
    fun `only the timestamp line differs between otherwise identical reports`() {
        val a = report(generatedAt = "2026-07-20T12:00:00Z").toJson().lines()
        val b = report(generatedAt = "2026-07-20T13:00:00Z").toJson().lines()
        val differing = a.zip(b).filter { (x, y) -> x != y }
        assertEquals(1, differing.size)
        assertTrue(differing.first().first.contains("generatedAt"))
    }

    @Test
    fun `an epoch difference shows up as a single changed line`() {
        // A fork is exactly this: same group, different epoch.
        val a = report(groups = listOf(group("aaaaaaaa", epoch = 12))).toJson().lines()
        val b = report(groups = listOf(group("aaaaaaaa", epoch = 13))).toJson().lines()
        val differing = a.zip(b).filter { (x, y) -> x != y }
        assertEquals(1, differing.size)
        assertTrue(differing.first().first.contains("epoch"))
    }

    // endregion

    // region privacy

    @Test
    fun `shortHex truncates to eight characters`() {
        assertEquals(8, DiagnosticsReport.shortHex("a".repeat(64)).length)
    }

    @Test
    fun `report carries no full-length hex identifiers`() {
        // Guards the rule rather than the current field list: if someone adds a
        // field later and puts a full pubkey or group id in it, this fails.
        val json = report(
            groups = listOf(group("aaaaaaaa")),
            relays = listOf(DiagnosticsReport.RelaySnapshot("wss://relay.example", true, true))
        ).toJson()
        val longHex = Regex("[0-9a-f]{32,}")
        assertTrue(
            longHex.findAll(json).none(),
            "diagnostics must not contain full-length hex identifiers"
        )
    }

    // endregion

    @Test
    fun `schema version is recorded`() {
        assertEquals(DiagnosticsReport.SCHEMA_VERSION, report().schema)
        assertTrue(report().toJson().contains("\"schema\": 1"))
    }
}
