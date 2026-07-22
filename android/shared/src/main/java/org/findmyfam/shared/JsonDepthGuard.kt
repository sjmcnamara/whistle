package org.findmyfam.shared

/**
 * Rejects pathologically nested JSON before it reaches `org.json.JSONObject`.
 *
 * org.json's tokenizer recurses once per `[`/`{` with no depth cap, so a few
 * hundred nested brackets exhaust the stack and throw `StackOverflowError` — an
 * [Error], which the `catch (e: Exception)` blocks around our decode sites do
 * NOT catch, so it crashes the app. Whistle feeds these parsers
 * attacker-influenceable bytes (the inner payload of a kind-445 MLS message, an
 * invite string), so without this guard a hostile group member could crash
 * every recipient with a tiny `[[[[…` payload — a remote DoS the encrypted
 * transport does nothing to prevent.
 *
 * Mirrors iOS `WhistleCore.JSONNestingGuard`. Found by the ClusterFuzzLite
 * `Fuzz_LocationPayload` target on the iOS side (crash input: 513 `[` bytes).
 * Legitimate Whistle payloads nest at most ~3 deep; the cap is a generous 32.
 */
object JsonDepthGuard {

    /** Maximum structural nesting depth accepted by [validate]. */
    const val MAX_DEPTH = 32

    class TooDeeplyNestedException(message: String) : IllegalArgumentException(message)

    /**
     * Throws [TooDeeplyNestedException] if [json] nests containers (`[` / `{`)
     * deeper than [maxDepth].
     *
     * A single linear, non-recursive scan — it cannot itself overflow. String
     * contents and `\`-escapes are skipped so brackets inside a JSON string
     * value (e.g. a chat message that literally contains "[[[") don't count.
     */
    fun validate(json: String, maxDepth: Int = MAX_DEPTH) {
        var depth = 0
        var inString = false
        var escaped = false
        for (c in json) {
            if (inString) {
                when {
                    escaped -> escaped = false
                    c == '\\' -> escaped = true
                    c == '"' -> inString = false
                }
                continue
            }
            when (c) {
                '"' -> inString = true
                '[', '{' -> {
                    depth++
                    if (depth > maxDepth) {
                        throw TooDeeplyNestedException("JSON nested deeper than $maxDepth")
                    }
                }
                ']', '}' -> if (depth > 0) depth--
            }
        }
    }
}
