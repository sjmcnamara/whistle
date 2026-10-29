import XCTest
@testable import Whistle

/// History notices against a real MarmotKit runtime.
///
/// The Android port can only mock this boundary — its unit tests run on the JVM
/// and cannot load the native library — so the behaviours that depend on what
/// MarmotKit actually returns are pinned here: a fresh account has no notices,
/// and dismissing an id that no longer exists is a `false`, not an error.
final class MarmotKitHistoryNoticeTests: XCTestCase {

    private var relay: LoopbackRelay!
    private var rootPath: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        relay = try LoopbackRelay()
        try relay.start()
    }

    override func tearDown() {
        relay?.stop(); relay = nil
        if let rootPath { try? FileManager.default.removeItem(atPath: rootPath) }
        rootPath = nil
        super.tearDown()
    }

    @MainActor
    private func startedService() async throws -> MarmotKitService {
        let root = NSTemporaryDirectory().appending("marmotkit-notices-\(UUID().uuidString)")
        rootPath = root
        let service = try MarmotKitService(
            rootPath: root,
            relayUrls: [try XCTUnwrap(relay.url)],
            allowLoopback: true,
            secretStore: InMemorySecretStore()
        )
        _ = try await service.startWithNewIdentity()
        return service
    }

    @MainActor
    func testAFreshAccountHasNoHistoryNotices() async throws {
        let service = try await startedService()

        await service.refreshHistoryNotices()

        XCTAssertTrue(service.historyNotices.isEmpty)
    }

    /// 48 lowercase hex characters is the shape of a real id; one that matches
    /// nothing is exactly what a notice recovery has since re-armed looks like.
    @MainActor
    func testDismissingAStaleNoticeIdIsNotAnError() async throws {
        let service = try await startedService()
        let stale = String(repeating: "0", count: 48)

        await service.dismissHistoryNotices([stale])

        XCTAssertTrue(service.historyNotices.isEmpty)
    }

    @MainActor
    func testRefreshingBeforeAnAccountExistsDoesNothing() async throws {
        let root = NSTemporaryDirectory().appending("marmotkit-notices-\(UUID().uuidString)")
        rootPath = root
        let service = try MarmotKitService(
            rootPath: root,
            relayUrls: [try XCTUnwrap(relay.url)],
            allowLoopback: true,
            secretStore: InMemorySecretStore()
        )

        await service.refreshHistoryNotices()

        XCTAssertTrue(service.historyNotices.isEmpty)
    }
}
