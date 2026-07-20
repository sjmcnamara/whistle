import SwiftUI
import UIKit
import WhistleCore

/// A group's shared photo — set by an admin and broadcast to every member.
///
/// Distinct from `LocalGroupAvatarStore`, which is a purely personal per-device
/// picture for a group. When both exist the **local one wins**: a member who has
/// chosen their own picture for a group keeps seeing it, and an admin changing
/// the shared photo does not override that choice. Use `resolvedImage(for:)`
/// rather than reading either store directly.
///
/// Stored as JPEGs in the app container, keyed by MLS group id.
@MainActor
final class SharedGroupAvatarStore: ObservableObject {

    /// Bumped whenever a shared avatar changes so observing views re-read.
    @Published private(set) var revision = 0

    private var cache: [String: UIImage] = [:]
    private let dir: URL

    init(directoryName: String = "SharedGroupAvatars") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Read

    func image(for groupId: String) -> UIImage? {
        if let cached = cache[groupId] { return cached }
        guard let img = UIImage(contentsOfFile: fileURL(groupId).path) else { return nil }
        cache[groupId] = img
        return img
    }

    func hasImage(for groupId: String) -> Bool {
        cache[groupId] != nil || FileManager.default.fileExists(atPath: fileURL(groupId).path)
    }

    /// The picture to show for a group: a personal override if the user set one,
    /// otherwise the admin's shared photo.
    ///
    /// Single place this precedence is decided — call sites must not reach into
    /// either store directly, or the two would drift apart.
    static func resolvedImage(
        for groupId: String,
        local: LocalGroupAvatarStore,
        shared: SharedGroupAvatarStore
    ) -> UIImage? {
        local.image(for: groupId) ?? shared.image(for: groupId)
    }

    // MARK: - Inbound

    /// Apply a group-avatar payload received from an admin.
    ///
    /// The caller is responsible for verifying the sender is an admin — see
    /// `MarmotService`'s dispatch. This store does not know about membership.
    func apply(_ payload: GroupAvatarPayload, for groupId: String) {
        guard !payload.isRemoval else {
            remove(for: groupId)
            return
        }
        guard let data = Data(base64Encoded: payload.img),
              let img = UIImage(data: data) else {
            WhistleLogger.chat.warning("Group avatar for \(groupId) was not decodable — ignoring")
            return
        }
        try? data.write(to: fileURL(groupId), options: .atomic)
        cache[groupId] = img
        revision += 1
    }

    // MARK: - Outbound

    /// Store a newly-picked shared photo and return the payload to broadcast,
    /// or nil if it could not be encoded within the wire cap.
    ///
    /// Reuses `MemberAvatarStore.encodeForWire` so both avatar kinds are
    /// downscaled and quality-stepped identically — they share a size ceiling,
    /// so they must share the encoder that respects it.
    func setImage(data: Data, for groupId: String) async -> GroupAvatarPayload? {
        guard let encoded = await Task.detached(priority: .userInitiated, operation: {
            MemberAvatarStore.encodeForWire(data)
        }).value else {
            WhistleLogger.chat.error("Could not encode group avatar within \(GroupAvatarPayload.maxEncodedBytes) bytes")
            return nil
        }
        guard let img = UIImage(data: encoded) else { return nil }
        try? encoded.write(to: fileURL(groupId), options: .atomic)
        cache[groupId] = img
        revision += 1
        return GroupAvatarPayload(base64Image: encoded.base64EncodedString())
    }

    /// Payload announcing removal of the group's photo. Clears locally too.
    func removeImagePayload(for groupId: String) -> GroupAvatarPayload {
        remove(for: groupId)
        return GroupAvatarPayload(base64Image: "")
    }

    /// The group's current shared photo as a broadcastable payload, or nil if
    /// none is set. Used to re-announce to a newly joined member.
    func payload(for groupId: String) -> GroupAvatarPayload? {
        guard let data = try? Data(contentsOf: fileURL(groupId)) else { return nil }
        let payload = GroupAvatarPayload(base64Image: data.base64EncodedString())
        return payload.isWithinSizeLimit ? payload : nil
    }

    // MARK: - Mutate

    func remove(for groupId: String) {
        try? FileManager.default.removeItem(at: fileURL(groupId))
        cache[groupId] = nil
        revision += 1
    }

    /// Clear every stored shared avatar (e.g. on identity burn).
    func removeAll() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cache.removeAll()
        revision += 1
    }

    // MARK: - Private

    private func fileURL(_ groupId: String) -> URL {
        // Group ids are hex, safe as a filename.
        dir.appendingPathComponent("\(groupId).jpg")
    }
}
