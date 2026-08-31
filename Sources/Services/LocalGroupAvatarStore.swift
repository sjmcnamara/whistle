import SwiftUI
import UIKit

/// Local, per-user, per-device group avatars.
///
/// These are **not** shared with other members and **not** synced across devices
/// — purely a personal touch on your own view of a group, so this needs no
/// protocol support, no encrypted blob distribution, and no admin control.
/// Stored as downscaled JPEGs in the app container, keyed by MLS group id.
///
/// (A future shared/admin-controlled avatar via `GroupDataUpdate.imageHash` can
/// take precedence over this local override when it ships.)
@MainActor
final class LocalGroupAvatarStore: ObservableObject {

    static let shared = LocalGroupAvatarStore()

    /// Bumped whenever an avatar changes so observing views re-read.
    @Published private(set) var revision = 0

    private var cache: [String: UIImage] = [:]
    private let dir: URL

    /// Longest-edge cap for stored thumbnails — keeps local storage tiny.
    private static let maxDimension: CGFloat = 256

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("GroupAvatars", isDirectory: true)
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

    // MARK: - Mutate

    /// Downscale and save picked image data for a group.
    func setImage(data: Data, for groupId: String) {
        guard let raw = UIImage(data: data) else { return }
        let img = Self.downscaled(raw, maxDimension: Self.maxDimension)
        guard let jpeg = img.jpegData(compressionQuality: 0.8) else { return }
        try? jpeg.write(to: fileURL(groupId), options: .atomic)
        cache[groupId] = img
        revision += 1
    }

    func removeImage(for groupId: String) {
        try? FileManager.default.removeItem(at: fileURL(groupId))
        cache[groupId] = nil
        revision += 1
    }

    /// Clear all local avatars (e.g. on identity burn).
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

    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        // Render at scale 1 so the stored JPEG is exactly `newSize` pixels, not
        // newSize × screen-scale (a @3x device would otherwise persist a 768px
        // thumbnail for a 256pt target).
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
