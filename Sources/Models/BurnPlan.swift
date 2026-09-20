import Foundation

/// What burning identity will do to each of the user's active groups,
/// computed before showing any confirmation UI so the user sees the real
/// consequences rather than a generic warning.
struct BurnPlan {
    struct Candidate: Identifiable {
        let pubkeyHex: String
        let displayName: String
        var id: String { pubkeyHex }
    }

    /// A group where the user is currently the sole admin. Burning without
    /// resolving this ends the group for everyone unless another member is
    /// promoted first.
    struct SoleAdminGroup: Identifiable {
        let groupId: String
        let groupName: String
        let candidates: [Candidate]
        var id: String { groupId }
    }

    /// Groups the user can just leave automatically — not the sole admin.
    let autoLeaveGroupIds: [String]

    /// Groups needing a decision: promote someone, or accept the group ends.
    let soleAdminGroups: [SoleAdminGroup]

    var needsReview: Bool { !soleAdminGroups.isEmpty }
}
