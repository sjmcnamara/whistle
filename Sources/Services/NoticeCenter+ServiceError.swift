import Foundation

/// Routing from `MarmotKitService.ServiceError` to the right notice tier.
///
/// Kept out of `NoticeCenter` itself so that type stays domain-agnostic, and
/// kept in one place so two call sites cannot disagree about whether a given
/// failure is transient or a state.
extension NoticeCenter {

    /// Report a failed operation.
    ///
    /// Most failures are transient and become a toast. The exception is
    /// `groupNeedsRepair`: that is a condition the group is *in* until an
    /// admin re-admits the member, so a toast would disappear while the group
    /// stayed unusable. It becomes a banner instead — which is the entire
    /// reason the two tiers exist.
    func report(_ error: Error, fallback: String, retry: (() async -> Void)? = nil) {
        guard let serviceError = error as? MarmotKitService.ServiceError else {
            postToast(fallback, retry: retry)
            return
        }

        // `ServiceError`'s own descriptions were written to be read by a user
        // ("You're the only admin of this group…"), which is the point of them
        // being typed rather than string-matched. Prefer them over the
        // caller's fallback, and never leak a raw debug description.
        let message = serviceError.errorDescription ?? fallback

        switch serviceError {
        case .groupNeedsRepair:
            post(Banner(cause: .groupNeedsRepair, message: message))

        case .lastAdminCannotLeave, .notGroupAdmin, .memberNotInGroup,
             .alreadyMember, .leaveAlreadyRequested, .unrecognisedMemberCode:
            // Advice, not transient failure. Retrying would fail identically,
            // so no Retry is offered however the caller asked.
            postToast(message)

        default:
            postToast(message, retry: retry)
        }
    }
}
