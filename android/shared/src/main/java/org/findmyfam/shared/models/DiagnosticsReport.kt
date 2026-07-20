package org.findmyfam.shared.models

import org.json.JSONArray
import org.json.JSONObject

/**
 * A snapshot of app and group state, safe to share publicly.
 *
 * Exists to make a fork diagnosable from outside the device. A fork is two
 * members sitting on different epochs for the same group — obvious when two
 * reports are placed side by side, and invisible in prose. So the format is
 * JSON with **deterministic ordering**: sorted keys, groups sorted by id,
 * relays by URL, failures by type. Two reports from two devices should differ
 * only where the devices genuinely differ.
 *
 * ## What must never appear here
 *
 * The report is meant to be pasteable into a public issue, so it carries no
 * message content, no locations, no nicknames (they name family members), no
 * secret key material, and no full public keys — those are truncated to the
 * same 8-character prefix the logs use. Adding a field means asking whether a
 * stranger reading it learns anything about the family.
 *
 * Key ordering is applied by hand: `org.json.JSONObject` iterates a HashMap and
 * gives no ordering guarantee, so the encoder below writes keys in sorted order
 * rather than trusting the library. Swift gets this from
 * `JSONEncoder.OutputFormatting.sortedKeys`; the two must agree byte for byte.
 */
data class DiagnosticsReport(
    val app: App,
    val identity: Identity,
    val groups: List<GroupSnapshot>,
    val relays: List<RelaySnapshot>,
    val settings: Settings,
    val recentFailures: List<FailureCount>,
    val volatile: Volatile
) {
    val schema: Int = SCHEMA_VERSION

    data class App(
        val version: String,
        val build: String,
        val platform: String,
        val os: String,
        /** Pinned MDK revision, so a report names the protocol code it ran. */
        val mdkRevision: String
    )

    data class Identity(
        /**
         * First 8 hex characters only — enough to correlate two reports, not
         * enough to identify the person.
         */
        val pubkeyPrefix: String
    )

    data class GroupSnapshot(
        /** First 8 hex characters of the MLS group id. */
        val id: String,
        /** The number that matters: members on different epochs are forked. */
        val epoch: Long,
        val memberCount: Int,
        val adminCount: Int,
        val isAdmin: Boolean,
        /** From GroupHealthTracker — whether recent MLS operations failed. */
        val healthy: Boolean,
        val consecutiveFailures: Int
    )

    data class RelaySnapshot(val url: String, val enabled: Boolean, val connected: Boolean)

    data class Settings(
        val locationIntervalSeconds: Int,
        val movementAware: Boolean,
        val locationFuzzMeters: Int,
        val keyRotationDays: Int,
        val locationPaused: Boolean
    )

    /**
     * An error *type* and how often it occurred. Never the message body — those
     * can contain group or member identifiers.
     */
    data class FailureCount(val type: String, val count: Int)

    data class Volatile(
        /** ISO-8601, UTC. */
        val generatedAt: String,
        /** Seconds since this device last processed any group event. */
        val secondsSinceLastGroupEvent: Int?
    )

    /** Groups sorted by id, relays by url, failures by type. */
    val sortedGroups: List<GroupSnapshot> get() = groups.sortedBy { it.id }
    val sortedRelays: List<RelaySnapshot> get() = relays.sortedBy { it.url }
    val sortedFailures: List<FailureCount> get() = recentFailures.sortedBy { it.type }

    /**
     * Pretty-printed JSON with sorted keys, newline-terminated — matching the
     * iOS encoder so a report from either platform diffs against the other.
     *
     * Rendered by [renderSorted] rather than `JSONObject.toString()`: the JVM's
     * org.json backs onto a HashMap, so insertion order means nothing and the
     * output would be unstable between runs. Unstable output would defeat the
     * entire purpose of the format.
     */
    fun toJson(): String {
        val root = JSONObject().apply {
            put("app", JSONObject().apply {
                put("build", app.build)
                put("mdkRevision", app.mdkRevision)
                put("os", app.os)
                put("platform", app.platform)
                put("version", app.version)
            })
            put("groups", JSONArray(sortedGroups.map {
                JSONObject().apply {
                    put("adminCount", it.adminCount)
                    put("consecutiveFailures", it.consecutiveFailures)
                    put("epoch", it.epoch)
                    put("healthy", it.healthy)
                    put("id", it.id)
                    put("isAdmin", it.isAdmin)
                    put("memberCount", it.memberCount)
                }
            }))
            put("identity", JSONObject().apply { put("pubkeyPrefix", identity.pubkeyPrefix) })
            put("recentFailures", JSONArray(sortedFailures.map {
                JSONObject().apply {
                    put("count", it.count)
                    put("type", it.type)
                }
            }))
            put("relays", JSONArray(sortedRelays.map {
                JSONObject().apply {
                    put("connected", it.connected)
                    put("enabled", it.enabled)
                    put("url", it.url)
                }
            }))
            put("schema", schema)
            put("settings", JSONObject().apply {
                put("keyRotationDays", settings.keyRotationDays)
                put("locationFuzzMeters", settings.locationFuzzMeters)
                put("locationIntervalSeconds", settings.locationIntervalSeconds)
                put("locationPaused", settings.locationPaused)
                put("movementAware", settings.movementAware)
            })
            put("volatile", JSONObject().apply {
                put("generatedAt", volatile.generatedAt)
                put(
                    "secondsSinceLastGroupEvent",
                    volatile.secondsSinceLastGroupEvent ?: JSONObject.NULL
                )
            })
        }
        return renderSorted(root, 0) + "\n"
    }

    companion object {
        /** Bumped when the shape changes, so an old report is still readable. */
        const val SCHEMA_VERSION = 1

        /**
         * Truncate a hex key to the 8-character prefix used throughout the
         * report and the logs.
         */
        fun shortHex(hex: String): String = hex.take(8)

        /**
         * Render JSON with keys in sorted order and two-space indentation.
         *
         * Written by hand because neither org.json implementation sorts: the
         * JVM one uses a HashMap (arbitrary order, and it can vary run to run)
         * and Android's uses a LinkedHashMap (insertion order). Relying on
         * either would give output that is not reliably diffable, which is the
         * one property this format needs. Escaping is delegated to
         * JSONObject.quote so strings stay correct.
         */
        internal fun renderSorted(value: Any?, indent: Int): String {
            val pad = " ".repeat(indent)
            val padInner = " ".repeat(indent + 2)
            return when (value) {
                is JSONObject -> {
                    val keys = value.keys().asSequence().sorted().toList()
                    if (keys.isEmpty()) return "{}"
                    keys.joinToString(
                        separator = ",\n",
                        prefix = "{\n",
                        postfix = "\n$pad}"
                    ) { k -> "$padInner${JSONObject.quote(k)}: ${renderSorted(value.get(k), indent + 2)}" }
                }
                is JSONArray -> {
                    if (value.length() == 0) return "[]"
                    (0 until value.length()).joinToString(
                        separator = ",\n",
                        prefix = "[\n",
                        postfix = "\n$pad]"
                    ) { i -> "$padInner${renderSorted(value.get(i), indent + 2)}" }
                }
                null, JSONObject.NULL -> "null"
                is String -> JSONObject.quote(value)
                is Boolean, is Int, is Long, is Double -> value.toString()
                else -> JSONObject.quote(value.toString())
            }
        }
    }
}
