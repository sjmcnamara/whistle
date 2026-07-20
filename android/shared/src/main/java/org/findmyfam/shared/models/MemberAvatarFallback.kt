package org.findmyfam.shared.models

/**
 * Fallback rendering data for a member with no avatar set.
 *
 * Every member has a display name but only some have an avatar, so this is the
 * normal state rather than an error state. Kept in the shared module (and free
 * of Android types) so it is unit-testable on the JVM and stays in step with
 * the iOS `MemberAvatarView` equivalents.
 */
object MemberAvatarFallback {

    /** Palette size — mirrors the iOS colour list. */
    const val PALETTE_SIZE = 8

    /**
     * Up to two initials from a display name. Falls back to "?" for a name with
     * no usable letters — a nickname can be an emoji or punctuation.
     */
    fun initials(name: String): String {
        val letters = name
            .split(" ")
            .filter { it.isNotEmpty() }
            .mapNotNull { word -> word.firstOrNull { it.isLetter() } }
        if (letters.isEmpty()) return "?"
        return letters.take(2).joinToString("").uppercase()
    }

    /**
     * Stable palette index derived from the pubkey, so a member keeps the same
     * initials circle across launches and across devices.
     *
     * FNV-1a rather than hashCode(): Swift seeds hashValue per process, so an
     * iOS colour derived that way would change on every launch. FNV-1a is
     * trivially reproducible on both platforms and gives the same answer.
     *
     * Takes the *top* bits. FNV-1a's low bits mix poorly, and reducing with
     * `hash % 8` collapsed every one of 60 sample 64-character hex keys onto a
     * single index — every member would have shared one colour. The high byte
     * spreads across the whole palette.
     *
     * (A plain sum of bytes was the first attempt and was degenerate too: the
     * palette size divides 64, so uniform 64-character keys all landed on 0.)
     */
    fun colorIndex(pubkeyHex: String): Int {
        var hash = FNV_OFFSET_BASIS
        for (byte in pubkeyHex.toByteArray(Charsets.UTF_8)) {
            hash = hash xor (byte.toInt() and 0xFF).toUInt()
            hash *= FNV_PRIME
        }
        return ((hash shr 24) % PALETTE_SIZE.toUInt()).toInt()
    }

    private const val FNV_OFFSET_BASIS: UInt = 2166136261u
    private const val FNV_PRIME: UInt = 16777619u
}
