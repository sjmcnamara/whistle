import Foundation

/// A group as the app layer sees it, with no MLS or MDK types in sight.
///
/// This exists so ViewModels and Views stop consuming `MDKBindings.Group`
/// directly. That direct coupling is what makes the MLS backend hard to
/// replace: the MDK 2.0 / MarmotKit migration swaps the entire MLS + relay
/// stack underneath (see ROADMAP.md), and anything holding an `MDKBindings`
/// type has to change with it.
///
/// It deliberately lives in `WhistleCore`, which has no dependency on
/// `MDKBindings` and cannot acquire one without a `Package.swift` change —
/// so the boundary is enforced by the build graph rather than by convention.
///
/// `mlsGroupId` keeps its name rather than becoming a bare `id`: it is the
/// protocol-level group identifier on both sides of the migration (MarmotKit
/// calls it `group_id_hex`), and renaming it would churn every call site for
/// no gain. `Identifiable` is satisfied without that churn.
/// Fields are limited to what the app layer actually reads. Group membership
/// and per-group relays are deliberately absent: both are separate queries
/// against the MLS state rather than properties of a group row, and the app
/// reads relay configuration from `AppSettings`, not from the group.
public struct WhistleGroup: Equatable, Identifiable, Sendable {
    public let mlsGroupId: String
    public let name: String
    public let isActive: Bool
    public let epoch: UInt64
    public let adminPubkeys: [String]
    /// Timestamp of the last MLS event seen for this group, in seconds since
    /// the epoch. Advances on *any* event — location, chat, nickname, commit —
    /// not just chat, so it reads as group liveness rather than chat activity.
    /// `nil` when nothing has ever been recorded.
    public let lastMessageAt: UInt64?

    public var id: String { mlsGroupId }

    public init(
        mlsGroupId: String,
        name: String,
        isActive: Bool,
        epoch: UInt64 = 0,
        adminPubkeys: [String] = [],
        lastMessageAt: UInt64? = nil
    ) {
        self.mlsGroupId = mlsGroupId
        self.name = name
        self.isActive = isActive
        self.epoch = epoch
        self.adminPubkeys = adminPubkeys
        self.lastMessageAt = lastMessageAt
    }

    /// Group name for display, falling back when the group carries no name.
    public var displayName: String {
        name.isEmpty ? "Unnamed Group" : name
    }

    public func isAdmin(_ pubkeyHex: String) -> Bool {
        adminPubkeys.contains(pubkeyHex)
    }
}
