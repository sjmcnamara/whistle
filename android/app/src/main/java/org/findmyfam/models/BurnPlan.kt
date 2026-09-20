package org.findmyfam.models

/**
 * What burning identity will do to each of the user's active groups,
 * computed before showing any confirmation UI so the user sees the real
 * consequences rather than a generic warning.
 */
data class BurnPlan(
    /** Groups the user can just leave automatically -- not the sole admin. */
    val autoLeaveGroupIds: List<String>,

    /** Groups needing a decision: promote someone, or accept the group ends. */
    val soleAdminGroups: List<SoleAdminGroup>
) {
    /** A group where the user is currently the sole admin. Burning without
     * resolving this ends the group for everyone unless another member is
     * promoted first. */
    data class SoleAdminGroup(
        val groupId: String,
        val groupName: String,
        val candidates: List<Candidate>
    )

    data class Candidate(
        val pubkeyHex: String,
        val displayName: String
    )

    val needsReview: Boolean get() = soleAdminGroups.isNotEmpty()
}
