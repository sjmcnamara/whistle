import SwiftUI
import UIKit
import WhistleCore

/// Member avatars, keyed by Nostr public key hex.
///
/// Unlike `LocalGroupAvatarStore` — which is a purely personal, per-device
/// touch — these **are** shared: your own avatar is broadcast to every active
/// group as an `AvatarPayload` inside an MLS application message, and other
/// members' avatars arrive the same way. Stored as downscaled JPEGs in the app
/// container, exactly as group avatars are.
///
/// Received images are held on the same footing as your own. There is no
/// separate "mine" vs "theirs" storage: the pubkey is the key, and your own
/// entry is simply the one matching your identity.
@MainActor
final class MemberAvatarStore: ObservableObject {

    /// Bumped whenever any avatar changes so observing views re-read.
    @Published private(set) var revision = 0

    private var cache: [String: UIImage] = [:]
    private let dir: URL

    init(directoryName: String = "MemberAvatars") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Read

    func image(for pubkeyHex: String) -> UIImage? {
        if let cached = cache[pubkeyHex] { return cached }
        guard let img = UIImage(contentsOfFile: fileURL(pubkeyHex).path) else { return nil }
        cache[pubkeyHex] = img
        return img
    }

    func hasImage(for pubkeyHex: String) -> Bool {
        cache[pubkeyHex] != nil || FileManager.default.fileExists(atPath: fileURL(pubkeyHex).path)
    }

    // MARK: - Inbound

    /// Apply an avatar payload received from another member.
    ///
    /// A removal payload (empty `img`) clears the stored image rather than
    /// being ignored, so "I deleted my avatar" actually propagates.
    func apply(_ payload: AvatarPayload, from pubkeyHex: String) {
        guard !payload.isRemoval else {
            remove(for: pubkeyHex)
            return
        }
        guard let data = Data(base64Encoded: payload.img),
              let img = UIImage(data: data) else {
            WhistleLogger.chat.warning("Avatar from \(pubkeyHex.prefix(8)) was not decodable — ignoring")
            return
        }
        try? data.write(to: fileURL(pubkeyHex), options: .atomic)
        cache[pubkeyHex] = img
        revision += 1
    }

    // MARK: - Outbound

    /// Store a newly-picked image for the local user and return the payload to
    /// broadcast, or nil if the image could not be encoded within the wire cap.
    ///
    /// The stored copy is the *same* bytes that go on the wire, so what other
    /// members see matches what we show for ourselves.
    func setOwnImage(data: Data, pubkeyHex: String) async -> AvatarPayload? {
        // Encoding decodes a full-size photo, downscales it, and JPEG-encodes it
        // up to six times hunting for the size cap. This type is @MainActor, so
        // running that inline blocked the UI for as long as it took — noticeably
        // for a 12MP camera-roll image. Hand it to a background task.
        guard let encoded = await Task.detached(priority: .userInitiated, operation: {
            Self.encodeForWire(data)
        }).value else {
            WhistleLogger.chat.error("Could not encode avatar within \(AvatarPayload.maxEncodedBytes) bytes")
            return nil
        }
        guard let img = UIImage(data: encoded) else { return nil }
        try? encoded.write(to: fileURL(pubkeyHex), options: .atomic)
        cache[pubkeyHex] = img
        revision += 1
        return AvatarPayload(base64Image: encoded.base64EncodedString())
    }

    /// Payload announcing removal of the local user's avatar. Clears locally too.
    func removeOwnImage(pubkeyHex: String) -> AvatarPayload {
        remove(for: pubkeyHex)
        return AvatarPayload(base64Image: "")
    }

    /// The local user's current avatar as a broadcastable payload, or nil if
    /// none is set. Used to re-announce on joining a new group.
    func ownPayload(pubkeyHex: String) -> AvatarPayload? {
        guard let data = try? Data(contentsOf: fileURL(pubkeyHex)) else { return nil }
        let payload = AvatarPayload(base64Image: data.base64EncodedString())
        return payload.isWithinSizeLimit ? payload : nil
    }

    // MARK: - Mutate

    func remove(for pubkeyHex: String) {
        try? FileManager.default.removeItem(at: fileURL(pubkeyHex))
        cache[pubkeyHex] = nil
        revision += 1
    }

    /// Clear every stored avatar (e.g. on identity burn).
    func removeAll() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cache.removeAll()
        revision += 1
    }

    // MARK: - Encoding

    /// Downscale to `AvatarPayload.targetEdge` and JPEG-encode, stepping quality
    /// down until the base64 form fits `AvatarPayload.maxEncodedBytes`.
    ///
    /// The size check is on the *base64* length, not the JPEG length, because
    /// that is what actually travels — base64 inflates by roughly 4/3, and
    /// checking the wrong one would let an oversized event reach the relay.
    /// Returns nil if even the lowest quality will not fit, so callers can
    /// refuse rather than publish something a relay may silently drop.
    nonisolated static func encodeForWire(_ data: Data) -> Data? {
        guard let raw = UIImage(data: data) else { return nil }
        let img = downscaled(raw, maxDimension: CGFloat(AvatarPayload.targetEdge))
        for quality in stride(from: 0.7, through: 0.2, by: -0.1) {
            guard let jpeg = img.jpegData(compressionQuality: quality) else { continue }
            if jpeg.base64EncodedString().utf8.count <= AvatarPayload.maxEncodedBytes {
                return jpeg
            }
        }
        return nil
    }

    // MARK: - Private

    private func fileURL(_ pubkeyHex: String) -> URL {
        // Pubkeys are hex, safe as a filename.
        dir.appendingPathComponent("\(pubkeyHex).jpg")
    }

    nonisolated private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
