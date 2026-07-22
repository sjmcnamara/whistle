import Foundation

/// Rejects pathologically nested JSON before it reaches `JSONDecoder`.
///
/// Foundation's JSON scanner recurses once per `[`/`{` with no depth cap, so a
/// few hundred nested brackets exhaust the stack and hard-crash the process —
/// verified on both Apple and swift-corelibs Foundation. Whistle feeds these
/// decoders attacker-influenceable bytes (the inner payload of a kind-445 MLS
/// message, an invite string), so without this guard a hostile group member
/// could crash every recipient with a tiny `[[[[…` payload — a remote DoS the
/// encrypted transport does nothing to prevent.
///
/// Found by the ClusterFuzzLite `Fuzz_LocationPayload` target (crash input:
/// 513 `[` bytes). Legitimate Whistle payloads nest at most ~3 deep; the cap
/// is a generous 32.
public enum JSONNestingGuard {

    /// Maximum structural nesting depth accepted by ``validate(_:maxDepth:)``.
    public static let maxDepth = 32

    public enum GuardError: Error {
        case tooDeeplyNested
    }

    /// Throws ``GuardError/tooDeeplyNested`` if `data` nests JSON containers
    /// (`[` / `{`) deeper than `maxDepth`.
    ///
    /// A single linear, non-recursive scan — it cannot itself overflow. String
    /// contents and `\`-escapes are skipped so brackets inside a JSON string
    /// value (e.g. a chat message that literally contains "[[[") don't count.
    public static func validate(_ data: Data, maxDepth: Int = maxDepth) throws {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {        // backslash
                    escaped = true
                } else if byte == 0x22 {        // closing quote
                    inString = false
                }
                continue
            }
            switch byte {
            case 0x22:                          // opening quote
                inString = true
            case 0x5B, 0x7B:                    // [ or {
                depth += 1
                if depth > maxDepth {
                    throw GuardError.tooDeeplyNested
                }
            case 0x5D, 0x7D:                    // ] or }
                if depth > 0 { depth -= 1 }
            default:
                break
            }
        }
    }
}
