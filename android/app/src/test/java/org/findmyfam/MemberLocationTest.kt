package org.findmyfam

import org.findmyfam.shared.models.LocationPayload
import org.findmyfam.shared.models.MemberLocation
import org.junit.Assert.*
import org.junit.Test

/**
 * Tests for MemberLocation.isStale.
 *
 * As of v1.2.1 staleness is anchored on `receivedAt` (local clock) rather than
 * `payload.ts` (publisher's clock) so that cross-device clock skew can't
 * corrupt the UI — semantically, "stale" means "we haven't heard from them
 * in a while," which is what users care about.
 *
 * Mirrors iOS LocationCacheTests stale-detection cases.
 */
class MemberLocationTest {

    private val group = "g1"
    private val alice = "a".repeat(64)

    private fun loc(payload: LocationPayload, receivedAtSecondsAgo: Long): MemberLocation =
        MemberLocation(
            groupId = group,
            memberPubkeyHex = alice,
            payload = payload,
            receivedAt = (System.currentTimeMillis() / 1000) - receivedAtSecondsAgo
        )

    private fun freshPayload(interval: Int? = null): LocationPayload =
        LocationPayload(lat = 0.0, lon = 0.0, alt = 0.0, acc = 0.0,
                        ts = System.currentTimeMillis() / 1000, interval = interval)

    @Test
    fun `stale when receivedAt older than 2x interval`() {
        // Received 2 hours ago, 1-hour interval → 2× threshold = 2h → stale
        assertTrue(loc(freshPayload(), receivedAtSecondsAgo = 7200).isStale(3600))
    }

    @Test
    fun `fresh when just received`() {
        assertFalse(loc(freshPayload(), receivedAtSecondsAgo = 0).isStale(3600))
    }

    @Test
    fun `publisher interval preferred over local`() {
        // Publisher is on 1-hour cadence; local device polls every 10s.
        // Without payload.interval this would be stale within 20s; with it,
        // the threshold is 2 × 3600 = 7200s.
        assertFalse(loc(freshPayload(interval = 3600), receivedAtSecondsAgo = 60).isStale(10))
    }

    @Test
    fun `falls back to local interval when payload interval missing`() {
        // Pre-1.2.1 payload (no interval field) — grade against local interval.
        // receivedAt = 25s ago, local threshold = 20s → stale.
        assertTrue(loc(freshPayload(interval = null), receivedAtSecondsAgo = 25).isStale(10))
    }

    @Test
    fun `staleness unaffected by publisher clock skew`() {
        // Regression: previously, isStale used payload.ts directly. A publisher
        // whose clock was 5 minutes behind would always show grey on the
        // receiver even on a just-received message. After the fix, receivedAt
        // drives everything.
        val publisherClockSkewSecs = 300L // publisher's clock is 5 min behind
        val payloadWithSkewedTs = LocationPayload(
            lat = 0.0, lon = 0.0, alt = 0.0, acc = 0.0,
            ts = (System.currentTimeMillis() / 1000) - publisherClockSkewSecs
        )
        assertFalse(
            "Clock skew on the publisher side must not poison local staleness",
            loc(payloadWithSkewedTs, receivedAtSecondsAgo = 0).isStale(10)
        )
    }
}
