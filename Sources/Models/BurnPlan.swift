import Foundation

/// What burning identity will do to each of the user's active groups,
/// computed before showing any confirmation UI so the user sees the real
/// consequences rather than a generic warning. Every active group falls
/// into exactly one of three camps.
struct BurnPlan {
    struct Candidate: Identifiable {
        let pubkeyHex: String
        let displayName: String
        var id: String { pubkeyHex }
    }

    /// Camp 1: another admin remains — leaving is automatic, the group
    /// survives untouched.
    struct LeavingGroup: Identifiable {
        let groupId: String
        let groupName: String
        var id: String { groupId }
    }

    /// Camp 2: the user is the sole admin and at least one other member
    /// exists — needs a decision: promote someone, or let it end.
    struct PromoteOrEndGroup: Identifiable {
        let groupId: String
        let groupName: String
        let candidates: [Candidate]
        var id: String { groupId }
    }

    /// Camp 3: a solo group (sole admin, no other members) — burning
    /// always ends it, and there is nothing to decide.
    struct EndingGroup: Identifiable {
        let groupId: String
        let groupName: String
        var id: String { groupId }
    }

    let leaving: [LeavingGroup]
    let promoteOrEnd: [PromoteOrEndGroup]
    let ending: [EndingGroup]

    var needsReview: Bool { !promoteOrEnd.isEmpty || !ending.isEmpty }
}
