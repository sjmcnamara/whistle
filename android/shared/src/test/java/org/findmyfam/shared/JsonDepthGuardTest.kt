package org.findmyfam.shared

import org.findmyfam.shared.models.ChatPayload
import org.findmyfam.shared.models.InviteCode
import org.findmyfam.shared.models.JoinRequest
import org.findmyfam.shared.models.LocationPayload
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertFailsWith

/**
 * Regression coverage for the deeply-nested-JSON crash found by the iOS
 * ClusterFuzzLite `Fuzz_LocationPayload` target. org.json recurses per bracket
 * with no depth cap, so nested input throws `StackOverflowError` (an Error the
 * decode sites' `catch (Exception)` blocks do NOT catch) and crashes the app.
 * Since these decoders run on post-decrypt payloads, a hostile group member
 * could remotely crash every recipient. Each decoder must now reject such input
 * with a caught exception rather than crash.
 */
class JsonDepthGuardTest {

    private fun nestedBrackets(count: Int) = "[".repeat(count)

    @Test
    fun `validate accepts shallow json`() {
        JsonDepthGuard.validate("""{"a":[1,2,{"b":3}]}""")
    }

    @Test
    fun `validate rejects beyond max depth`() {
        assertFailsWith<JsonDepthGuard.TooDeeplyNestedException> {
            JsonDepthGuard.validate(nestedBrackets(JsonDepthGuard.MAX_DEPTH + 1))
        }
    }

    @Test
    fun `validate accepts exactly max depth`() {
        val json = nestedBrackets(JsonDepthGuard.MAX_DEPTH) + "]".repeat(JsonDepthGuard.MAX_DEPTH)
        JsonDepthGuard.validate(json)
    }

    @Test
    fun `validate ignores brackets inside strings`() {
        // A chat message that literally contains many brackets is string
        // content, not structural nesting, and must not trip the guard.
        val json = """{"text":"${nestedBrackets(200)}"}"""
        JsonDepthGuard.validate(json)
    }

    @Test
    fun `validate handles escaped quote inside string`() {
        JsonDepthGuard.validate("""{"text":"he said \"[[[\" ok"}""")
    }

    // Decoders must throw (a caught Exception), not crash with StackOverflowError.

    @Test
    fun `LocationPayload rejects deeply nested input`() {
        assertFailsWith<JsonDepthGuard.TooDeeplyNestedException> {
            LocationPayload.fromJson(nestedBrackets(513))
        }
        assertFailsWith<JsonDepthGuard.TooDeeplyNestedException> {
            LocationPayload.fromJson(nestedBrackets(100_000))
        }
    }

    @Test
    fun `ChatPayload rejects deeply nested input`() {
        assertFailsWith<JsonDepthGuard.TooDeeplyNestedException> {
            ChatPayload.fromJson(nestedBrackets(513))
        }
    }

    @Test
    fun `JoinRequest rejects deeply nested input`() {
        assertFailsWith<JsonDepthGuard.TooDeeplyNestedException> {
            JoinRequest.fromJson(nestedBrackets(513))
        }
    }

    @Test
    fun `InviteCode rejects deeply nested input`() {
        val encoded = Base64.getEncoder().encodeToString(nestedBrackets(513).toByteArray(Charsets.UTF_8))
        assertFailsWith<JsonDepthGuard.TooDeeplyNestedException> {
            InviteCode.decode(encoded)
        }
    }
}
