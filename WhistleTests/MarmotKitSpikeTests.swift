import XCTest
import MarmotKit

/// MDK 2.0 / MarmotKit migration spike (ROADMAP.md "Deferred" — MDK 2.0 / MarmotKit migration,
/// step 1: "iOS spike branch, no UI changes... prove one identity + one group + one
/// custom-kind message round-trip in a test").
///
/// `MarmotKitBindings` is wired into `WhistleTests` only (see project.yml) — it is NOT a
/// dependency of the shipping `Whistle` app target yet. This proves the package resolves,
/// compiles, and the API shape documented in `crates/marmot-uniffi/API-REFERENCE.md`
/// (marmot-protocol/mdk, marmotkit-v0.10.4) matches what the generated Swift bindings
/// actually expose — before `MarmotService` is rewritten around it (step 3).
///
/// The round-trip itself needs a real relay: MarmotKit owns its own relay pub/sub
/// (unlike today's mdk-swift + hand-rolled `RelayService`, there is no injectable mock at
/// this layer), so it is gated behind `MARMOTKIT_SPIKE_LIVE_RELAY` and skipped by default —
/// it must not make `./scripts/build.sh test` flaky or depend on network in ordinary CI runs.
/// Run locally with that env var set (any value) to actually exercise it against
/// wss://relay.damus.io, the same relay already in `AppDefaults.defaultRelays`.
final class MarmotKitSpikeTests: XCTestCase {

    /// Nostr kind for the spike's own custom event. Arbitrary and outside MDK's reserved
    /// list (chat, reaction, edit, delete, agent, group system, push token) — see
    /// API-REFERENCE.md's `send_custom_event` doc comment.
    private static let spikeKind: UInt64 = 30078

    func testIdentityGroupAndCustomEventRoundTrip() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MARMOTKIT_SPIKE_LIVE_RELAY"] != nil,
            "Needs a real relay round-trip — set MARMOTKIT_SPIKE_LIVE_RELAY to run this locally."
        )

        let rootPath = NSTemporaryDirectory().appending("marmotkit-spike-\(UUID().uuidString)")
        let relayUrls = ["wss://relay.damus.io"]

        let marmot = try Marmot(rootPath: rootPath, relayUrls: relayUrls)
        try await marmot.start()

        let identity = try await marmot.createIdentityWithProfile(
            defaultRelays: relayUrls,
            bootstrapRelays: relayUrls
        )
        let accountRef = identity.account.accountIdHex
        XCTAssertFalse(accountRef.isEmpty)

        let groupId = try await marmot.createGroup(
            accountRef: accountRef,
            name: "MarmotKit spike group",
            memberRefs: [],
            description: nil
        )
        XCTAssertFalse(groupId.isEmpty)

        let subscription = try await marmot.subscribeMessages(
            accountRef: accountRef,
            groupIdHex: groupId,
            limit: nil,
            kinds: [Self.spikeKind]
        )

        let payload = "marmotkit-spike-\(UUID().uuidString)"
        _ = try await marmot.sendCustomEvent(
            accountRef: accountRef,
            groupIdHex: groupId,
            kind: Self.spikeKind,
            tags: [],
            content: payload
        )

        guard let update = await subscription.next() else {
            XCTFail("subscription ended without receiving the round-tripped custom event")
            return
        }

        switch update {
        case .message(let received):
            XCTAssertEqual(received.message.kind, Self.spikeKind)
            XCTAssertEqual(received.message.plaintext, payload)
        case .agentStreamStarted:
            XCTFail("expected a plain message update, got an agent stream start")
        }
    }
}
