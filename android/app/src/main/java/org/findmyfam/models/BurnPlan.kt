package org.findmyfam.models

/**
 * What burning identity will do to each of the user's active groups,
 * computed before showing any confirmation UI so the user sees the real
 * consequences rather than a generic warning. Every active group falls
 * into exactly one of three camps.
 */
data class BurnPlan(
    /** Camp 1: another admin remains -- leaving is automatic, the group
     * survives untouched. */
    val leaving: List<LeavingGroup>,

    /** Camp 2: the user is the sole admin and at least one other member
     * exists -- needs a decision: promote someone, or let it end. */
    val promoteOrEnd: List<PromoteOrEndGroup>,

    /** Camp 3: a solo group (sole admin, no other members) -- burning
     * always ends it, and there is nothing to decide. */
    val ending: List<EndingGroup>
) {
    data class LeavingGroup(
        val groupId: String,
        val groupName: String
    )

    data class PromoteOrEndGroup(
        val groupId: String,
        val groupName: String,
        val candidates: List<Candidate>
    )

    data class EndingGroup(
        val groupId: String,
        val groupName: String
    )

    data class Candidate(
        val pubkeyHex: String,
        val displayName: String
    )

    val needsReview: Boolean get() = promoteOrEnd.isNotEmpty() || ending.isNotEmpty()
}
