import Foundation
import WhistleCore
import MarmotKit

/// Marmot protocol v2 group operations, backed by MarmotKit (MDK 0.10.x).
///
/// Step 3b of the MDK 2.0 / MarmotKit migration (see ROADMAP.md). This exists
/// **alongside** `MarmotService` rather than replacing it: the v1 service
/// carries fixes earned the hard way (the v1.11.1 burn bug, v1.11.2's
/// relay-delivery-order buffer, the leave/admin guards) and nothing is deleted
/// from it until step 3c's two-device comparison shows MarmotKit's own
/// convergence machinery actually covers the same ground. It is not wired into
/// the app; tests drive it.
///
/// Deliberately not expressed as a protocol shared with `MarmotService` yet.
/// With the v1 path untouched such a protocol would have a single conformer
/// and a shape guessed rather than observed, and step 3c compares the two
/// concrete implementations regardless. It gets extracted at the cutover,
/// when both sides are known to line up.
///
/// ## What changes versus the v1 stack
///
/// - **Transport is MarmotKit's.** It owns relay connections, publication
///   retry (`GroupSendQueueFull` when a group's outbound queue saturates) and
///   catch-up (`AccountCatchUp`). The app no longer builds kind-445 events,
///   runs its own subscription, or re-sorts a backlog by `created_at`.
/// - **Groups are "chats".** There is no single group read: identity and
///   activity come from `chatList`, admins and epoch from `groupDetails`.
/// - **Leave is durable.** `leaveGroup` registers an intent that survives
///   restarts and keeps re-proposing until a commit removes us, rather than
///   publishing-and-verifying synchronously. `leaveRequestPending` reports it.
/// - **Admin rules are typed.** `WouldRemoveLastAdmin` / `AdminCannotSelfRemove`
///   / `NotGroupAdmin` replace v1's parsing of MDK error *strings*.
@MainActor
final class MarmotKitService: ObservableObject {

    // MARK: - Published state

    /// Mirrors `MarmotService`'s published surface so the app layer can be
    /// swapped onto this service without ViewModels changing shape.
    @Published private(set) var groups: [WhistleGroup] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastChatMessageGroupId: String?
    @Published private(set) var lastJoinedGroupId: String?
    @Published private(set) var lastGroupMembershipChangeId: (String, Date)?

    // MARK: - Injected stores
    //
    // Same set as the v1 service, minus two that protocol v2 makes
    // meaningless: `pendingInviteStore` and `joinRequestStore`. With no
    // out-of-group messaging there is no join-request to collect and no
    // pending-invite state to track (ROADMAP.md step 4).

    var locationCache: LocationCache?
    var nicknameStore: NicknameStore?
    var memberAvatarStore: MemberAvatarStore?
    var sharedGroupAvatarStore: SharedGroupAvatarStore?
    var batteryAlertService: BatteryAlertService?

    // MARK: - Errors

    enum ServiceError: LocalizedError {
        case notStarted
        case lastAdminCannotLeave
        case notGroupAdmin
        case alreadyMember
        case memberNotInGroup
        case leaveAlreadyRequested
        /// The group is halted and only a re-admit by another member can
        /// revive it — MarmotKit's `GroupUnrecoverableRepairRequired`. The v1
        /// stack inferred this state from consecutive failures; here it is
        /// reported outright.
        case groupNeedsRepair
        case sendQueueFull
        case avatarTooLarge
        case reAddFailed(String)
        case unrecognisedMemberCode
        /// The nsec being adopted does not belong to the identity the caller
        /// said it did. Never expected in normal operation — it means the app
        /// would otherwise have started as the wrong person.
        case identityMismatch(expected: String, adopted: String)
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case .notStarted:
                return "Marmot is not started yet."
            case .lastAdminCannotLeave:
                return "You're the only admin of this group. Promote another member to admin before leaving."
            case .notGroupAdmin:
                return "Only an admin can do that."
            case .alreadyMember:
                return "This person is already a member of the group"
            case .memberNotInGroup:
                return "That person isn't a member of this group."
            case .leaveAlreadyRequested:
                return "You're already leaving this group — it will complete shortly."
            case .groupNeedsRepair:
                return "This group needs to be re-joined. Ask an admin to re-invite you."
            case .sendQueueFull:
                return "This group is stuck sending. Try again once it catches up."
            case .avatarTooLarge:
                return "That picture is too large to share. Try a different one."
            case .reAddFailed:
                return "Removed the member, but re-adding them failed. Tap Resync again to retry."
            case .unrecognisedMemberCode:
                return "That code isn't a Whistle member code. Ask them to show theirs from Settings → My Member Code."
            case .identityMismatch(let expected, let adopted):
                return "Identity mismatch: expected \(expected.prefix(8))…, adopted \(adopted.prefix(8))…"
            case .underlying(let detail):
                return detail
            }
        }
    }

    /// Translate MarmotKit's typed errors into app-level ones.
    ///
    /// The point of doing this at all is that v1 had to pattern-match MDK's
    /// error *text* (`"last active admin"`, `"only admins can perform this
    /// operation"`) because 0.8 surfaced these as untyped strings. These are
    /// first-class cases now, so the matching is exhaustive instead of
    /// fragile.
    private static func mapError(_ error: Error) -> ServiceError {
        // Pass our own errors straight through. Everything in this service
        // runs inside `run`, which maps on the way out — so a `ServiceError`
        // thrown *inside* (by `requireAccount`, or the identity-mismatch
        // check) would otherwise be re-wrapped as `.underlying`, losing the
        // case a caller is trying to `catch`.
        if let serviceError = error as? ServiceError {
            return serviceError
        }
        guard let kitError = error as? MarmotKitError else {
            return .underlying(error.localizedDescription)
        }
        switch kitError {
        case .WouldRemoveLastAdmin:
            return .lastAdminCannotLeave
        case .NotGroupAdmin, .NotAdmin:
            return .notGroupAdmin
        case .AlreadyAdmin:
            return .alreadyMember
        case .MemberNotInGroup:
            return .memberNotInGroup
        case .LeaveAlreadyRequested:
            return .leaveAlreadyRequested
        case .GroupUnrecoverableRepairRequired:
            return .groupNeedsRepair
        case .GroupSendQueueFull:
            return .sendQueueFull
        default:
            return .underlying(String(describing: kitError))
        }
    }

    private static func run<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw mapError(error)
        }
    }

    // MARK: - State

    private let marmot: Marmot
    private let relayUrls: [String]
    private var accountRef: String?

    /// Account reference for the started identity, for callers that need to
    /// pass it back into MarmotKit directly (tests, diagnostics).
    var currentAccountRef: String? { accountRef }

    // MARK: - Init

    /// - Parameters:
    ///   - rootPath: Directory MarmotKit owns its account database under. This
    ///     is a store of its own, entirely separate from v1's `whistle.db` —
    ///     v1 groups do not migrate, so the two never share state.
    ///   - relayUrls: Relays to dial.
    ///   - allowLoopback: Opt into loopback relay endpoints. Upstream gates
    ///     this behind an explicit development flag
    ///     (`RelayPolicyFfi.allowLoopback`); it is what lets a test point this
    ///     service at a relay it controls, since MarmotKit exposes no
    ///     injectable transport.
    ///   - secretStore: Where account signing keys live. `nil` uses
    ///     MarmotKit's default platform keyring, which is right for the app
    ///     but unavailable to an XCTest bundle — without the app's
    ///     entitlement the runtime fails with `KeystoreUnavailable` before it
    ///     reaches the network at all, which reads misleadingly like a
    ///     connectivity fault. Tests pass their own store.
    init(
        rootPath: String,
        relayUrls: [String],
        allowLoopback: Bool = false,
        secretStore: SecretStore? = nil
    ) throws {
        self.relayUrls = relayUrls
        let options = MarmotOptions(
            relayPolicy: allowLoopback ? .allowLoopbackRelaysAndBlobs : .publicOnly,
            secretStore: secretStore
        )
        self.marmot = try Marmot.newWithConfiguration(
            rootPath: rootPath,
            relayUrls: relayUrls,
            options: options
        )
    }

    // MARK: - Relay policy

    private static let generationKey = "marmotkit.rootGeneration"

    /// The directory MarmotKit owns its account database under.
    ///
    /// Deliberately a sibling of v1's `whistle.db` rather than a replacement:
    /// protocol v2 is not wire-compatible, v1 groups do not migrate, and
    /// keeping the two stores apart means an install that falls back to v1
    /// still finds its data intact.
    ///
    /// **The path must be fully symlink-resolved.** MarmotKit opens this as a
    /// "complete authorized directory path" and refuses any symlink along the
    /// way with `ELOOP` ("Too many levels of symbolic links", os error 62) —
    /// and on iOS `/var` *is* a symlink to `/private/var`, which is exactly
    /// what `FileManager.urls(for:in:)` hands back. On device that failed
    /// startup outright with an error naming the leaf directory, which reads
    /// like the directory is broken rather than the prefix. The spike harness
    /// that worked on device used `NSTemporaryDirectory()`, which is already
    /// `/private/var/…`, so nothing caught this until the real root was used.
    ///
    /// Suffixed with a generation number, which `advanceIdentityGeneration()`
    /// bumps on identity replacement. A runtime owns its root until its handle
    /// is *dropped*, not until `shutdown()` returns, and the handle can
    /// outlive the swap — a presented view still holding the old service is
    /// enough. Restarting on the same root then fails with `RuntimeBusy`,
    /// which during an import or burn means the user is told their new
    /// identity failed when the key itself was fine. Giving each generation
    /// its own directory removes the contention rather than depending on
    /// release timing.
    ///
    /// Superseded generations are deleted here, at launch, when exactly one
    /// service exists and nothing can still be holding them.
    ///
    /// Throws rather than returning a best-effort path: a directory that
    /// could not be created surfaces downstream as an opaque MarmotKit I/O
    /// error about a path the reader has no reason to suspect, which is how
    /// the symlink bug above presented.
    nonisolated static func defaultRootPath() throws -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let container = base.appendingPathComponent("marmotkit", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        let generation = UserDefaults.standard.integer(forKey: generationKey)
        let name = "gen-\(generation)"
        purgeSupersededGenerations(in: container, keeping: name)

        let root = container.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let resolved = fullyResolved(root.path)
        WhistleLogger.marmot.info("MarmotKit root: \(resolved)")
        return resolved
    }

    /// Fully resolve a path, via `realpath(3)` rather than Foundation.
    ///
    /// `URL.resolvingSymlinksInPath()` is not enough, and the way it fails is
    /// a trap: it *does* resolve `/var` to `/private/var`, and then reading
    /// `.path` back off the result standardizes the `/private` prefix away
    /// again, returning the original unresolved string. The round trip looks
    /// like a no-op, so the first attempt at this fix changed nothing and the
    /// device error came back byte-identical.
    ///
    /// `realpath` resolves every component and never re-standardizes, which
    /// is what MarmotKit requires — it opens its root as a "complete
    /// authorized directory path" and rejects any symlink with `ELOOP`
    /// ("Too many levels of symbolic links", os error 62). The path must
    /// exist, so call this only after creating it.
    nonisolated static func fullyResolved(_ path: String) -> String {
        guard let buffer = realpath(path, nil) else {
            // Nothing better to do than pass the original through; MarmotKit
            // will report what it could not open, and the log line above
            // records exactly what it was given.
            WhistleLogger.marmot.warning("realpath failed for \(path) — passing it through unresolved")
            return path
        }
        defer { free(buffer) }
        return String(cString: buffer)
    }

    /// Move to a fresh root for the next identity. Call before rebuilding the
    /// service on identity replacement.
    nonisolated static func advanceIdentityGeneration() {
        let next = UserDefaults.standard.integer(forKey: generationKey) + 1
        UserDefaults.standard.set(next, forKey: generationKey)
        WhistleLogger.marmot.info("Advanced MarmotKit root generation to \(next)")
    }

    nonisolated private static func purgeSupersededGenerations(in container: URL, keeping current: String) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: container, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.lastPathComponent.hasPrefix("gen-") && url.lastPathComponent != current {
            do {
                try FileManager.default.removeItem(at: url)
                WhistleLogger.marmot.info("Removed superseded MarmotKit root \(url.lastPathComponent)")
            } catch {
                WhistleLogger.marmot.warning("Could not remove \(url.lastPathComponent): \(error)")
            }
        }
    }

    /// The subset of `endpoints` MarmotKit is willing to dial, answered
    /// *before* a service exists.
    ///
    /// Startup needs this ordering: MarmotKit refuses a retired host outright
    /// — a relay-list declaration naming one fails the whole directory fetch
    /// with "relay endpoint host is retired", which on device presented as a
    /// total startup failure rather than one bad URL. So the list has to be
    /// filtered before it is handed to the runtime, not after.
    ///
    /// Classification is an instance method on `Marmot`, so this stands up a
    /// throwaway runtime to ask. It gets a temporary root of its own rather
    /// than the real one: a root is owned exclusively for as long as its
    /// handle lives, and sharing it here would risk the `RuntimeBusy` that
    /// two instances on one root produce. Nothing is dialled — networking
    /// begins at `start()`, which this probe never calls.
    nonisolated static func allowedRelayEndpoints(from endpoints: [String]) -> [String] {
        guard !endpoints.isEmpty else { return [] }
        // Same symlink requirement as `defaultRootPath()` — created first so
        // `resolvingSymlinksInPath()` has something to resolve. This one
        // happened to work on device already, because the temporary directory
        // is reported as `/private/var/…` rather than `/var/…`, but relying on
        // that distinction silently is what hid the bug in the first place.
        let probeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("marmotkit-relay-policy-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
        let resolvedProbeRoot = fullyResolved(probeRoot.path)
        defer { try? FileManager.default.removeItem(atPath: resolvedProbeRoot) }

        guard let probe = try? Marmot.newWithConfiguration(
            rootPath: resolvedProbeRoot,
            relayUrls: [],
            options: MarmotOptions(relayPolicy: .publicOnly, secretStore: nil)
        ) else {
            // Policy unavailable. Returning the input unfiltered is the right
            // failure: it preserves today's behaviour and lets `start()`
            // report the real problem, rather than silently dropping every
            // relay and presenting that as "no relays configured".
            WhistleLogger.marmot.warning("Relay policy probe unavailable — using relays unfiltered")
            return endpoints
        }
        return probe.classifyRelayEndpoints(endpoints: endpoints)
            .filter { $0.policy == .allowed }
            .map { $0.normalizedEndpoint ?? $0.endpoint }
    }

    /// Hostnames MarmotKit "will never dial or adopt".
    ///
    /// The app's own default relay list is not automatically acceptable:
    /// MarmotKit enforces a relay safety policy at the dial boundary and
    /// refuses retired hosts outright, failing identity creation with a
    /// `Runtime` error rather than quietly skipping them. Verified on device —
    /// `wss://relay.damus.io` is retired, and it is the first entry in
    /// `AppDefaults.defaultRelays`.
    nonisolated func retiredRelayHosts() -> [String] {
        marmot.retiredRelayHosts()
    }

    /// Classify relay URLs with the same policy applied when dialling.
    nonisolated func classifyRelays(_ endpoints: [String]) -> [(endpoint: String, policy: String)] {
        marmot.classifyRelayEndpoints(endpoints: endpoints).map {
            ($0.endpoint, String(describing: $0.policy))
        }
    }

    /// The subset of `endpoints` MarmotKit is willing to dial.
    nonisolated func allowedRelays(from endpoints: [String]) -> [String] {
        marmot.classifyRelayEndpoints(endpoints: endpoints)
            .filter { $0.policy == .allowed }
            .map { $0.normalizedEndpoint ?? $0.endpoint }
    }

    /// Relays this service will actually dial, after policy filtering.
    nonisolated var usableRelayEndpoints: [String] { allowedRelays(from: relayUrls) }

    // MARK: - Lifecycle

    /// Start the runtime and create a fresh identity, returning its account ref.
    ///
    /// `createIdentityWithProfile` is used rather than `createIdentity`: the
    /// latter only returns once relay lists and the first KeyPackage have been
    /// published, whereas this returns at local-ready and reports publication
    /// progress through `readiness`. That distinction matters for onboarding —
    /// "show my invite QR" has to gate on the KeyPackage actually being
    /// published, not merely on an identity existing.
    @discardableResult
    func startWithNewIdentity() async throws -> String {
        try await Self.run {
            try await marmot.start()
            let identity = try await marmot.createIdentityWithProfile(
                defaultRelays: relayUrls,
                bootstrapRelays: relayUrls
            )
            let ref = identity.account.accountIdHex
            accountRef = ref
            return ref
        }
    }

    /// Start, adopting an identity the app already has.
    ///
    /// This is the upgrade path, and it is what stops the cutover costing
    /// users their identity. MarmotKit owns accounts itself —
    /// `createIdentityWithProfile` mints a *new* key — so starting that way on
    /// an existing install would hand every user a new npub and silently
    /// orphan them from everyone who knows them. v2.0 breaking groups is
    /// agreed; breaking identity is not.
    ///
    /// `beginOnboarding` persists the supplied nsec and "returns before any
    /// network preflight or publication", so the account exists locally
    /// straight away and publication progress is observed through
    /// `setupReadiness` rather than blocking startup.
    ///
    /// Idempotent: on every launch after the first, the account is already in
    /// MarmotKit's database and this signs back into it instead of
    /// re-onboarding.
    @discardableResult
    func start(
        adoptingNsec nsec: String,
        expecting expectedReference: String?,
        discoveryRelays: [String] = []
    ) async throws -> String {
        try await Self.run {
            try await marmot.start()

            let expectedId = expectedReference.flatMap { marmot.accountIdHex(reference: $0) }
            let existing = try marmot.listAccounts()

            // Match on the account this nsec actually belongs to, never simply
            // the first one present. Taking `.first` looked equivalent and is
            // not: after an identity import or burn, the previous account is
            // still in the database, so the app would sign back into the *old*
            // identity and carry on with its npub and its groups while
            // reporting the import a success.
            if let expectedId, let match = existing.first(where: { $0.accountIdHex == expectedId }) {
                let summary = try await marmot.signInAccount(accountRef: match.accountIdHex)
                accountRef = summary.accountIdHex
                return summary.accountIdHex
            }

            // Accounts present, none of them this one. That is the identity
            // replacement path, and the stale accounts are dropped rather than
            // left behind: a burned identity's keys must not survive it, and
            // leaving them would also make the matching above depend on a
            // database that only ever grows.
            for stale in existing where stale.accountIdHex != expectedId {
                do {
                    try await marmot.removeAccount(accountRef: stale.accountIdHex)
                    WhistleLogger.marmot.info("Removed stale account \(stale.accountIdHex.prefix(8))")
                } catch {
                    // Not fatal: the new account is still adopted below, and
                    // matching is by id so a surviving stale row cannot be
                    // mistaken for it.
                    WhistleLogger.marmot.warning("Could not remove stale account: \(error)")
                }
            }

            let usableRelays = allowedRelays(from: relayUrls)
            let snapshot = try await marmot.beginOnboarding(
                nsec: nsec,
                options: OnboardingOptionsFfi(
                    defaultRelays: usableRelays,
                    discoveryRelays: discoveryRelays.isEmpty ? usableRelays : discoveryRelays
                )
            )
            // `snapshot.ready` is false at this point by design — publication
            // has not been attempted yet. Readiness is observed through
            // `setupReadiness()`, which is what `MemberCodeView` gates on.
            accountRef = snapshot.accountIdHex

            // A mismatch here means the nsec and the reference describe
            // different identities — the caller passed an inconsistent pair.
            // Worth failing loudly: silently continuing would run the app as
            // whoever the nsec belongs to, not who the caller believed.
            if let expectedId, snapshot.accountIdHex != expectedId {
                throw ServiceError.identityMismatch(
                    expected: expectedId,
                    adopted: snapshot.accountIdHex
                )
            }
            return snapshot.accountIdHex
        }
    }

    /// Remove this device's account, destroying its local signing key.
    ///
    /// Called before the service is torn down on identity replacement. Doing
    /// it through MarmotKit rather than deleting the database directory is
    /// deliberate: the runtime owns that root for as long as its handle lives,
    /// so removing files underneath it is not safe while the service exists.
    func forgetCurrentAccount() async {
        guard let account = accountRef else { return }
        do {
            try await marmot.removeAccount(accountRef: account)
            WhistleLogger.marmot.info("Removed account \(account.prefix(8)) on identity replacement")
        } catch {
            WhistleLogger.marmot.error("Failed to remove account on identity replacement: \(error)")
        }
        accountRef = nil
    }

    /// The account's nsec, for key backup and export.
    ///
    /// v1 read this from its own Keychain entry; under v2 MarmotKit holds the
    /// key, so export has to come from here. Throws `KeystoreUnavailable`
    /// when the keychain is locked and `SecretNotFound` for a watch-only
    /// account, both of which a backup screen should report distinctly rather
    /// than as a generic failure.
    func revealNsec() throws -> String {
        let account = try requireAccount()
        do {
            return try marmot.revealNsec(accountRef: account)
        } catch {
            throw Self.mapError(error)
        }
    }

    private func requireAccount() throws -> String {
        guard let accountRef else { throw ServiceError.notStarted }
        return accountRef
    }

    /// Resume the account already stored under this service's root.
    ///
    /// The counterpart to `startWithNewIdentity` for a restart: the signing
    /// key lives in the secret store and the account in the database, so a
    /// relaunch signs back in rather than creating a second identity.
    @discardableResult
    func resumeExistingIdentity() async throws -> String {
        try await Self.run {
            try await marmot.start()
            guard let existing = try marmot.listAccounts().first else {
                throw ServiceError.notStarted
            }
            let summary = try await marmot.signInAccount(accountRef: existing.accountIdHex)
            accountRef = summary.accountIdHex
            return summary.accountIdHex
        }
    }

    /// Stop the runtime.
    ///
    /// Root ownership outlives this call — upstream notes it is held "until
    /// the final `Marmot`/runtime handle is dropped, even after
    /// `Marmot::shutdown`" — so constructing another service on the same root
    /// requires releasing this object first, or the new one fails with
    /// `RuntimeBusy`.
    func shutdown() async {
        await marmot.shutdown()
    }

    /// Ask the runtime to catch up on anything it missed while not running.
    ///
    /// MarmotKit's own equivalent of v1's `catchUpGroup`, which re-fetches 30
    /// days of kind-445 events by hand. Whether this covers the same ground
    /// is what step 3c has to establish before that code is deleted.
    func catchUpAccounts() async throws {
        try await Self.run {
            try await marmot.catchUpAccounts()
        }
    }

    /// Publish a fresh KeyPackage and return its published-at timestamp.
    ///
    /// `createIdentityWithProfile` returns at local-ready, before publication
    /// completes, so an account can exist while nothing discoverable about it
    /// has reached a relay yet. Anyone inviting this account needs its
    /// KeyPackage to be fetchable first — which is also why onboarding has to
    /// gate "show my invite QR" on publication rather than on identity
    /// creation (ROADMAP.md step 4).
    /// Connection counters straight from the runtime, so "no relay
    /// connectivity" is a measurement rather than a symptom.
    func relayDiagnostics() async -> String {
        let health = await marmot.relayHealth()
        var parts: [String] = []
        parts.append("total=\(health.totalRelays)")
        parts.append("connected=\(health.connected)")
        parts.append("connecting=\(health.connecting)")
        parts.append("pending=\(health.pending)")
        parts.append("disconnected=\(health.disconnected)")
        parts.append("terminated=\(health.terminated)")
        parts.append("banned=\(health.banned)")
        parts.append("sleeping=\(health.sleeping)")
        parts.append("attempts=\(health.connectionAttempts)")
        parts.append("successes=\(health.connectionSuccesses)")
        parts.append("sdkBacked=\(health.sdkBacked)")
        parts.append("forwarder=\(health.notificationForwarderRunning)")
        return "relays " + parts.joined(separator: " ")
    }

    /// What the account actually believes its relays are, which is not
    /// necessarily what was passed in at construction.
    func relayListDiagnostics() -> String {
        guard let account = accountRef else { return "no account" }
        guard let lists = try? marmot.accountRelayLists(accountRef: account) else {
            return "relay lists unavailable (setup may be incomplete)"
        }
        return "relay lists: \(String(describing: lists))"
    }

    /// Human-readable dump of the onboarding state machine, for diagnosing a
    /// setup that will not complete. Steps can sit at `needsInput` awaiting a
    /// caller action, and the action list says which.
    func onboardingDiagnostics() throws -> [String] {
        let account = try requireAccount()
        guard let snapshot = try marmot.onboardingSnapshot(accountRef: account) else {
            return ["no onboarding session (account was not created via beginOnboarding)"]
        }
        var header: [String] = []
        header.append("ready=\(snapshot.ready)")
        header.append("revision=\(snapshot.revision)")
        header.append("cancellationPending=\(snapshot.cancellationPending)")
        header.append("proposal=\(snapshot.proposal != nil)")
        header.append("singleDevice=\(snapshot.singleDeviceNotice != nil)")
        var lines = [header.joined(separator: " ")]
        for state in snapshot.steps {
            let step = String(describing: state.step)
            let status = String(describing: state.status)
            let actions = String(describing: state.actions)
            lines.append("step=\(step) status=\(status) actions=\(actions)")
            // The findings are the part that says *why* a step will not pass —
            // `issue` names the fault (`unreachable`, `timedOut`,
            // `retiredRelay`, `authenticationRequired`, `noUsableRoute`, …)
            // and `endpoint` names the relay it happened on. A count alone is
            // useless, which is how the first version of this was written.
            for finding in state.findings {
                let issue = String(describing: finding.issue)
                let endpoint = finding.endpoint ?? "-"
                lines.append("  finding issue=\(issue) endpoint=\(endpoint)")
            }
        }
        return lines
    }

    /// Drive account setup from local-ready to network-ready.
    ///
    /// `beginOnboarding` stops at local-ready — it persists the identity and
    /// returns "before any network preflight or publication" — so until this
    /// completes, anything needing a published account is rejected with
    /// `OnboardingRequired`. That is what "my member code" hit on device.
    ///
    /// Onboarding is a **sequential state machine that blocks on caller
    /// input**, not a single call. Observed directly: after `beginOnboarding`
    /// all six steps are `pending`; one `runOnboarding` moves `profile` to
    /// `needsInput` and every later step stays `pending` behind it. So
    /// `runOnboarding` on its own can never finish — it advances only what it
    /// can decide itself, and the caller has to clear each blocking step. This
    /// loop does that until the snapshot reports `ready`, bounded, and
    /// stopping if a pass produces no revision change (nothing left that we
    /// know how to resolve).
    ///
    /// Called off the launch path, since this is the half that waits on
    /// relays. `MemberCodeView` gates the member code on `setupReadiness()`
    /// reaching `.networkReady`, so showing it early degrades to
    /// "Publishing your key…" rather than handing out a code no admin can
    /// invite.
    @discardableResult
    func completeAccountSetup() async throws -> AccountSetupReadinessFfi {
        let account = try requireAccount()
        return try await Self.run {
            if try marmot.accountSetupReadiness(accountRef: account) == .networkReady {
                return .networkReady
            }
            // No session means the account came from `createIdentityWithProfile`,
            // which runs its own setup — `runOnboarding` would throw
            // `OnboardingActionUnavailable`.
            guard try marmot.onboardingSnapshot(accountRef: account) != nil else {
                return try marmot.accountSetupReadiness(accountRef: account)
            }

            // Every (step, action) pair already tried. Without this the loop
            // re-applies the *same* action on every pass — observed on device,
            // where `inboxRelays` kept being handed our configured relay list
            // and kept coming back `needsInput`, while `useRecommendedRelays`
            // sat unused in the same action list.
            var attempted: Set<String> = []

            for _ in 0..<24 {
                var snapshot = try await marmot.runOnboarding(accountRef: account)
                if snapshot.ready { break }

                let blockedStep: OnboardingStepStateFfi? = snapshot.steps.first { state in
                    let status = state.status
                    return status == .needsInput || status == .retryableFailure
                }
                guard let blocked = blockedStep else { break }

                for finding in blocked.findings {
                    // Composed as a plain String first. Concatenating inside an
                    // os_log interpolation made the type-checker give up on
                    // this expression entirely.
                    let step = String(describing: blocked.step)
                    let issue = String(describing: finding.issue)
                    let endpoint = finding.endpoint ?? "-"
                    let message = "Onboarding \(step) finding: \(issue) endpoint=\(endpoint)"
                    WhistleLogger.marmot.warning("\(message)")
                }

                guard let resolved = try await resolveOnboardingStep(
                    blocked, account: account, snapshot: snapshot, attempted: &attempted
                ) else {
                    // Nothing left to try on this step.
                    break
                }
                snapshot = resolved
                if snapshot.ready { break }
            }

            let readiness = try marmot.accountSetupReadiness(accountRef: account)
            if readiness != .networkReady {
                // Dump the whole picture rather than just the end state: the
                // step findings name the failing relay and the reason, which
                // is the only thing that distinguishes "relay unreachable"
                // from "step needs an action we did not handle".
                WhistleLogger.marmot.error("Account setup stalled at \(String(describing: readiness))")
                for line in (try? onboardingDiagnostics()) ?? [] {
                    WhistleLogger.marmot.error("  \(line)")
                }
                let relayState = await self.relayDiagnostics()
                WhistleLogger.marmot.error("  \(relayState)")
                let listState = self.relayListDiagnostics()
                WhistleLogger.marmot.error("  \(listState)")
            }
            return readiness
        }
    }

    /// Clear one blocking onboarding step.
    ///
    /// Chooses from the actions the step itself offers, in a preference order
    /// per step, and **never repeats an action already tried** — a step that
    /// stays `needsInput` after an action means that action did not work, so
    /// repeating it just burns the loop budget. Returns `nil` when every
    /// offered action has been exhausted.
    ///
    /// `cancelOnboarding` is deliberately absent from every preference list:
    /// it discards the account.
    private func resolveOnboardingStep(
        _ state: OnboardingStepStateFfi,
        account: String,
        snapshot: OnboardingSnapshotFfi,
        attempted: inout Set<String>
    ) async throws -> OnboardingSnapshotFfi? {
        let preference: [OnboardingActionFfi]
        switch state.step {
        case .profile, .follows:
            // Whistle publishes no public Nostr profile and has no social
            // graph: display names and avatars travel inside the group as MLS
            // payloads, so these are out of scope rather than merely optional.
            preference = [.continueWithout, .retry]

        case .relays, .inboxRelays:
            // Our own configured list first — it is policy-filtered, so it
            // cannot reintroduce a retired host. Recommended relays second,
            // because a relay list that will not publish is worse than one we
            // did not choose: without it the account is undiscoverable and
            // nobody can invite us.
            preference = [.editRelays, .useRecommendedRelays, .editDiscoveryRelays, .retry, .continueWithout]

        case .singleDevice:
            // One device is the normal case for this app, not a warning.
            preference = [.continueWithout, .retry]

        case .keyPackage:
            // No `continueWithout`: without a published KeyPackage nobody can
            // add us to a group, which is the whole point of the member code.
            preference = [.retry, .editRelays, .useRecommendedRelays]
        }

        for action in preference {
            guard state.actions.contains(action) else { continue }
            let key = "\(state.step)|\(action)"
            guard attempted.insert(key).inserted else { continue }
            WhistleLogger.marmot.info("Onboarding \(String(describing: state.step)): trying \(String(describing: action))")
            if let next = try await apply(action, step: state.step, account: account, snapshot: snapshot) {
                return next
            }
        }

        if state.step == .singleDevice, snapshot.singleDeviceNotice != nil,
           attempted.insert("singleDevice|acknowledge").inserted {
            return try await marmot.acknowledgeOnboardingSingleDevice(
                accountRef: account, revision: snapshot.revision
            )
        }

        WhistleLogger.marmot.error(
            "Onboarding \(String(describing: state.step)) exhausted every action: \(String(describing: state.actions))"
        )
        return nil
    }

    private func apply(
        _ action: OnboardingActionFfi,
        step: OnboardingStepFfi,
        account: String,
        snapshot: OnboardingSnapshotFfi
    ) async throws -> OnboardingSnapshotFfi? {
        let relays = allowedRelays(from: relayUrls)
        switch action {
        case .continueWithout:
            return try await marmot.continueOnboardingWithout(accountRef: account, step: step)
        case .retry:
            return try await marmot.retryOnboardingStep(accountRef: account, step: step)
        case .editRelays:
            guard !relays.isEmpty else { return nil }
            return try await marmot.proposeOnboardingRelays(
                accountRef: account, step: step, readRelays: relays, writeRelays: relays
            )
        case .useRecommendedRelays:
            return try await marmot.proposeOnboardingRecommendedRelays(accountRef: account, step: step)
        case .editDiscoveryRelays:
            guard !relays.isEmpty else { return nil }
            return try await marmot.setOnboardingDiscoveryRelays(accountRef: account, discoveryRelays: relays)
        case .approveRepair:
            guard snapshot.proposal != nil else { return nil }
            return try await marmot.approveOnboardingRepair(accountRef: account, revision: snapshot.revision)
        default:
            return nil
        }
    }

    /// Mint and publish a **fresh** KeyPackage, superseding the current slot.
    ///
    /// Not a startup call. Upstream documents this as the sanctioned repair
    /// for an epoch-stalled group (`publish_new_key_package` is the legacy
    /// name for `rotateKeyPackage`); the *first* KeyPackage is published by
    /// onboarding, so calling this at launch both fails before setup
    /// completes and needlessly rotates afterwards.
    @discardableResult
    func publishKeyPackage() async throws -> UInt64 {
        let account = try requireAccount()
        return try await Self.run {
            try await marmot.publishNewKeyPackage(accountRef: account)
        }
    }

    // MARK: - Groups

    /// All groups, newest activity first.
    ///
    /// Costs one `chatList` plus a `groupDetails` per group: a chat row carries
    /// identity and activity but neither the admin list nor the epoch. Fine at
    /// this app's scale (a handful of groups), and avoidable later — the only
    /// caller that needs admins off the cached list is `promoteToAdmin`, and
    /// reading those live would be more correct anyway, since v1's own notes
    /// record the cached admin list diverging from live MLS state.
    func groups() async throws -> [WhistleGroup] {
        let account = try requireAccount()
        return try await Self.run {
            let rows = try marmot.chatList(accountRef: account, includeArchived: false)
            var result: [WhistleGroup] = []
            for row in rows {
                let details = try? await marmot.groupDetails(
                    accountRef: account,
                    groupIdHex: row.groupIdHex
                )
                result.append(Self.map(row: row, details: details))
            }
            return result
        }
    }

    func group(id groupIdHex: String) async throws -> WhistleGroup? {
        let account = try requireAccount()
        return try await Self.run {
            guard let row = try marmot.chatListRow(accountRef: account, groupIdHex: groupIdHex) else {
                return nil
            }
            let details = try? await marmot.groupDetails(accountRef: account, groupIdHex: groupIdHex)
            return Self.map(row: row, details: details)
        }
    }

    func members(ofGroup groupIdHex: String) async throws -> [String] {
        let account = try requireAccount()
        return try await Self.run {
            try await marmot.groupMembers(accountRef: account, groupIdHex: groupIdHex)
                .map(\.memberIdHex)
        }
    }

    /// Whether a leave is already in flight — MarmotKit keeps re-proposing a
    /// durable leave until a commit removes us, so a second attempt is
    /// progress to surface rather than an error to retry.
    func isLeavePending(groupIdHex: String) async throws -> Bool {
        let account = try requireAccount()
        return try await Self.run {
            try marmot.chatListRow(accountRef: account, groupIdHex: groupIdHex)?
                .leaveRequestPending ?? false
        }
    }

    @discardableResult
    func createGroup(name: String, description: String? = nil, memberRefs: [String] = []) async throws -> String {
        let account = try requireAccount()
        return try await Self.run {
            try await marmot.createGroup(
                accountRef: account,
                name: name,
                memberRefs: memberRefs,
                description: description
            )
        }
    }

    // MARK: - Scan to invite
    //
    // Protocol v2 has no out-of-group messaging, so the v1 flow — prospect
    // scans an admin's group QR, publishes a KeyPackage, gift-wraps a
    // join-request — has no equivalent and no replacement. The admin's QR is
    // not reversed but obsolete: a non-member scanning it has no action
    // available. What remains runs one way only: the prospective member shows
    // their own code, an admin scans it and invites them (ROADMAP.md step 4).

    /// Resolve a scanned code to the account id the rest of the API expects.
    ///
    /// Delegates to MarmotKit rather than decoding bech32 here: it accepts
    /// npub *and* nprofile, discards nprofile relay hints, and enforces its
    /// own length limits. Re-implementing that against NostrSDK would be a
    /// second, subtly different parser for the same input.
    nonisolated func normalisedAccountReference(_ scanned: String) -> String? {
        marmot.accountIdHex(reference: scanned.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// This account's npub — the code a member shows to be invited.
    ///
    /// Uses MarmotKit's own encoder rather than NostrSDK's `toBech32`, for the
    /// same reason `normalisedAccountReference` uses its decoder: one parser
    /// per direction, not two that can disagree.
    ///
    /// npub rather than the raw hex because it is the portable Nostr form —
    /// a member can paste it into a message if scanning is impractical — and
    /// `accountIdHex(reference:)` normalises either on the way back in.
    /// Main-actor isolated, unlike its decoding counterpart: it reads
    /// `accountRef`, which is mutable actor state. Callers are SwiftUI views,
    /// which are already on the main actor.
    func myMemberCode() -> String? {
        guard let accountRef else { return nil }
        return marmot.npub(accountIdHex: accountRef)
    }

    /// Invite whoever a scanned code refers to.
    ///
    /// Throws `.unrecognisedMemberCode` for anything that isn't a public
    /// identity reference, so a mis-scan is distinguishable from a relay or
    /// permission failure — those look identical to a user otherwise.
    func invite(scannedCode: String, toGroup groupIdHex: String) async throws {
        guard let memberRef = normalisedAccountReference(scannedCode) else {
            throw ServiceError.unrecognisedMemberCode
        }
        try await invite(memberRefs: [memberRef], toGroup: groupIdHex)
    }

    /// How far account setup has progressed.
    ///
    /// `.networkReady` is the gate for showing a member code: anything
    /// earlier means the KeyPackage has not reached a relay yet, so an admin
    /// who scans the code cannot invite them. The two-device tests only
    /// worked once `publishKeyPackage()` had been called, and a code shown
    /// too early fails in a way that reads as a broken scanner rather than a
    /// timing problem.
    func setupReadiness() throws -> AccountSetupReadinessFfi {
        let account = try requireAccount()
        do {
            return try marmot.accountSetupReadiness(accountRef: account)
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Whether this account can currently be invited by someone else.
    func isReadyToBeInvited() -> Bool {
        (try? setupReadiness()) == .networkReady
    }

    // MARK: - Membership & admin

    /// Add members directly by account reference.
    ///
    /// There is no v1-style join-request round trip here: MarmotKit has no
    /// outside-group messaging, so an admin invites a known npub rather than
    /// receiving a gift-wrapped request carrying a KeyPackage. That is the
    /// product change step 4 covers (reversed invite QR).
    func invite(memberRefs: [String], toGroup groupIdHex: String) async throws {
        let account = try requireAccount()
        _ = try await Self.run {
            try await marmot.inviteMembers(
                accountRef: account,
                groupIdHex: groupIdHex,
                memberRefs: memberRefs
            )
        }
    }

    func removeMembers(_ memberRefs: [String], fromGroup groupIdHex: String) async throws {
        let account = try requireAccount()
        _ = try await Self.run {
            try await marmot.removeMembers(
                accountRef: account,
                groupIdHex: groupIdHex,
                memberRefs: memberRefs
            )
        }
    }

    func promoteToAdmin(_ memberRef: String, inGroup groupIdHex: String) async throws {
        let account = try requireAccount()
        _ = try await Self.run {
            try await marmot.promoteAdmin(
                accountRef: account,
                groupIdHex: groupIdHex,
                memberRef: memberRef
            )
        }
    }

    /// Leave a group.
    ///
    /// Self-demote first when we hold admin: MarmotKit refuses a bare leave
    /// from an admin (`AdminCannotSelfRemove`), and refuses the demote itself
    /// when we are the only admin (`WouldRemoveLastAdmin`) — which surfaces as
    /// `.lastAdminCannotLeave` so the caller can tell the user to promote
    /// someone first. v1 reached the same outcome by parsing error strings.
    func leaveGroup(_ groupIdHex: String) async throws {
        let account = try requireAccount()
        do {
            _ = try await marmot.selfDemoteAdmin(accountRef: account, groupIdHex: groupIdHex)
        } catch let error as MarmotKitError {
            switch error {
            case .WouldRemoveLastAdmin:
                throw ServiceError.lastAdminCannotLeave
            case .NotGroupAdmin, .NotAdmin:
                break  // not an admin — nothing to demote, fall through to leave
            default:
                throw Self.mapError(error)
            }
        }
        _ = try await Self.run {
            try await marmot.leaveGroup(accountRef: account, groupIdHex: groupIdHex)
        }
    }

    func rename(group groupIdHex: String, to name: String) async throws {
        let account = try requireAccount()
        _ = try await Self.run {
            try await marmot.updateGroupProfile(
                accountRef: account,
                groupIdHex: groupIdHex,
                name: name,
                description: nil
            )
        }
    }

    // MARK: - Send

    /// Send an app payload as a custom event.
    ///
    /// `kind` must be outside MDK's reserved set — use `MarmotKind.ProtocolV2`, which
    /// exists precisely because v1's `chat = 9` collides with MDK's own CHAT
    /// and would be rejected here.
    func send(content: String, kind: UInt16, toGroup groupIdHex: String) async throws {
        let account = try requireAccount()
        _ = try await Self.run {
            try await marmot.sendCustomEvent(
                accountRef: account,
                groupIdHex: groupIdHex,
                kind: UInt64(kind),
                tags: [],
                content: content
            )
        }
    }

    func sendLocation(_ payload: LocationPayload, toGroup groupIdHex: String) async throws {
        try await send(
            content: try payload.jsonString(),
            kind: MarmotKind.ProtocolV2.location,
            toGroup: groupIdHex
        )
    }

    func sendChat(_ payload: ChatPayload, toGroup groupIdHex: String) async throws {
        try await send(
            content: try payload.jsonString(),
            kind: MarmotKind.ProtocolV2.chat,
            toGroup: groupIdHex
        )
    }

    // MARK: - Receive

    /// Subscribe to a group's custom events, or to every group when
    /// `groupIdHex` is nil.
    ///
    /// Replaces v1's single relay-wide kind-445 filter plus the EOSE catch-up
    /// buffer: MarmotKit owns the subscription and hands over decrypted
    /// messages. `kinds` filters server-side rather than after decryption.
    func subscribe(
        toGroup groupIdHex: String? = nil,
        kinds: [UInt16] = [MarmotKind.ProtocolV2.location, MarmotKind.ProtocolV2.chat, MarmotKind.ProtocolV2.leaveRequest]
    ) async throws -> MessageStream {
        let account = try requireAccount()
        let subscription = try await Self.run {
            try await marmot.subscribeMessages(
                accountRef: account,
                groupIdHex: groupIdHex,
                limit: nil,
                kinds: kinds.map(UInt64.init)
            )
        }
        return MessageStream(subscription: subscription)
    }

    /// Pull-based stream of decrypted app messages, mapped to owned types.
    struct MessageStream {
        private let subscription: MessagesSubscription

        init(subscription: MessagesSubscription) {
            self.subscription = subscription
        }

        /// Next message, or `nil` once the subscription ends. Agent-stream
        /// starts are skipped — Whistle sends no agent payloads, and surfacing
        /// them would make every caller handle a case it has no meaning for.
        func next() async -> WhistleMessage? {
            while let update = await subscription.next() {
                guard case .message(let received) = update else { continue }
                return MarmotKitService.map(received: received.message)
            }
            return nil
        }
    }

    // MARK: - Group queries (parity with the v1 service)

    /// Refresh the published `groups` list.
    func refreshGroups() async {
        do {
            groups = try await groups()
        } catch {
            lastError = error.localizedDescription
            WhistleLogger.marmot.error("refreshGroups failed: \(error)")
        }
    }

    /// Is this pubkey an admin of the group, per live MLS state?
    func isAdmin(_ pubkeyHex: String, ofGroup groupIdHex: String) async -> Bool {
        (try? await group(id: groupIdHex))?.isAdmin(pubkeyHex) ?? false
    }

    /// The admin responsible for re-announcing group state to new joiners.
    ///
    /// Lexicographically smallest admin pubkey, as in v1: every admin sees a
    /// join, so without a rule a three-admin group would send three copies of
    /// the group photo, and "first in the array" resolves differently per
    /// device.
    func designatedBroadcaster(forGroup groupIdHex: String) async -> String? {
        (try? await group(id: groupIdHex))?.adminPubkeys.min()
    }

    /// Relays MarmotKit is actually willing to dial from the configured set.
    var activeRelayURLs: [String] {
        allowedRelays(from: relayUrls)
    }

    // MARK: - Message history

    /// One page of history, newest-first, ending before `beforeMessageId`.
    ///
    /// Cursor-based, unlike v1's offset paging — which makes v1's careful
    /// raw-row-count bookkeeping unnecessary rather than merely different.
    /// Offsets drift when new messages land mid-scroll, so v1 had to advance
    /// by the raw store count and infer "more" from `count == pageSize`;
    /// MarmotKit reports `hasMoreBefore` outright and a cursor cannot drift.
    /// - Parameter before: the oldest message already held, or `nil` for the
    ///   newest page. Takes a whole message rather than an id because the
    ///   cursor is compound: the backend rejects a bare id with "timeline
    ///   pagination requires before and before_message_id together", since
    ///   `timelineAt` has one-second resolution and needs the id to break
    ///   ties. Passing the message keeps that detail out of callers.
    func messages(
        inGroup groupIdHex: String,
        before: WhistleMessage? = nil,
        limit: UInt32 = 50
    ) async throws -> (messages: [WhistleMessage], hasMoreBefore: Bool) {
        let account = try requireAccount()
        return try await Self.run {
            let page = try marmot.timelineMessages(
                accountRef: account,
                query: TimelineMessageQueryFfi(
                    groupIdHex: groupIdHex,
                    search: nil,
                    before: before?.createdAt,
                    beforeMessageId: before?.id,
                    after: nil,
                    afterMessageId: nil,
                    limit: limit
                )
            )
            // The backend treats `before` as *inclusive* and returns the
            // cursor row again, so consecutive pages overlap by one. Dropped
            // here rather than left to callers: v1's ChatViewModel dedupes by
            // id and would have hidden the duplicate instead of surfacing it,
            // and anything that trusted the page contents would double-render
            // one message per page.
            let mapped = page.messages
                .map { Self.map(timeline: $0) }
                .filter { $0.id != before?.id }
            return (mapped, page.hasMoreBefore)
        }
    }

    // MARK: - Chat sub-type senders

    /// Nickname, member avatar and group avatar all ride the chat kind with a
    /// `type` discriminator, exactly as in v1 — the wire shape of these
    /// payloads is unchanged by the migration, only the transport is.
    func sendNicknameUpdate(name: String, toGroup groupIdHex: String) async throws {
        try await send(
            content: try NicknamePayload(name: name).jsonString(),
            kind: MarmotKind.ProtocolV2.chat,
            toGroup: groupIdHex
        )
    }

    func sendAvatarUpdate(_ payload: AvatarPayload, toGroup groupIdHex: String) async throws {
        guard payload.isWithinSizeLimit else { throw ServiceError.avatarTooLarge }
        try await send(
            content: try payload.jsonString(),
            kind: MarmotKind.ProtocolV2.chat,
            toGroup: groupIdHex
        )
    }

    func sendGroupAvatarUpdate(_ payload: GroupAvatarPayload, toGroup groupIdHex: String) async throws {
        guard payload.isWithinSizeLimit else { throw ServiceError.avatarTooLarge }
        try await send(
            content: try payload.jsonString(),
            kind: MarmotKind.ProtocolV2.chat,
            toGroup: groupIdHex
        )
    }

    // MARK: - Fork repair

    /// Remove a member and immediately re-invite them.
    ///
    /// Ported forward deliberately. Step 3c showed MarmotKit resolving a
    /// two-admin concurrent-commit fork on its own, but upstream still
    /// documents `GroupUnrecoverableRepairRequired` as a group "halted until
    /// another member re-admits this device" — a state that only exists if
    /// some divergence is unrecoverable, and this is the only cure for it.
    ///
    /// Ordering matches v1: nothing is removed until the re-invite is possible,
    /// and a failure after removal is reported distinctly so the caller can
    /// retry rather than silently stranding the member.
    func resyncMember(_ memberRef: String, inGroup groupIdHex: String) async throws {
        let members = try await members(ofGroup: groupIdHex)
        if members.contains(memberRef) {
            try await removeMembers([memberRef], fromGroup: groupIdHex)
        }
        do {
            try await invite(memberRefs: [memberRef], toGroup: groupIdHex)
        } catch {
            throw ServiceError.reAddFailed(memberRef)
        }
        lastGroupMembershipChangeId = (groupIdHex, Date())
    }

    // MARK: - Receive loop

    private var receiveTask: Task<Void, Never>?

    /// Start consuming decrypted messages and routing them into app state.
    ///
    /// Far smaller than v1's equivalent, and deliberately so. v1 opened raw
    /// kind-445 and kind-1059 relay subscriptions, tracked a `since`
    /// high-water mark, buffered events until EOSE so it could re-sort them
    /// by `created_at`, and polled for missed gift-wraps. MarmotKit owns the
    /// subscription, the ordering and the catch-up — all of which step 3c
    /// verified rather than assumed — so what is left is a loop that decodes
    /// payloads.
    ///
    /// Subscribes account-wide (`toGroup: nil`) rather than per group, so a
    /// group joined while running needs no re-subscribe.
    func startSubscriptions() {
        guard receiveTask == nil else { return }
        receiveTask = Task { [weak self] in
            guard let stream = await self?.openStream() else { return }
            while !Task.isCancelled, let message = await stream.next() {
                await self?.route(message)
            }
        }
    }

    func stopSubscriptions() {
        receiveTask?.cancel()
        receiveTask = nil
        WhistleLogger.marmot.info("Subscriptions stopped")
    }

    private func openStream() async -> MessageStream? {
        do {
            return try await subscribe()
        } catch {
            lastError = error.localizedDescription
            WhistleLogger.marmot.error("Failed to open message subscription: \(error)")
            return nil
        }
    }

    /// Route one decrypted payload. Mirrors v1's `routeApplicationMessage`,
    /// including the parts that must not change.
    private func route(_ message: WhistleMessage) async {
        switch message.kind {
        case MarmotKind.ProtocolV2.location:
            do {
                let payload = try LocationPayload.from(jsonString: message.content)
                locationCache?.update(
                    groupId: message.mlsGroupId,
                    memberPubkeyHex: message.senderPubkey,
                    payload: payload
                )
                batteryAlertService?.check(pubkeyHex: message.senderPubkey, battery: payload.batt)
            } catch {
                WhistleLogger.marmot.error("Failed to decode location payload: \(error)")
            }

        case MarmotKind.ProtocolV2.chat:
            await routeChatPayload(message)

        default:
            WhistleLogger.marmot.debug("Ignoring unknown inner kind \(message.kind)")
        }
    }

    /// Nickname, avatar and group-avatar share the chat kind and are told
    /// apart by a `type` discriminator — unchanged from v1, since only the
    /// transport moved.
    private func routeChatPayload(_ message: WhistleMessage) async {
        switch message.payloadType {
        case "chat", nil:
            // A nil type is plain text from an older client; v1 treated it as
            // chat and dropping it would silently lose messages.
            lastChatMessageGroupId = message.mlsGroupId

        case "nickname":
            if let payload = try? NicknamePayload.from(jsonString: message.content) {
                nicknameStore?.set(name: payload.name, for: message.senderPubkey)
            }

        case "avatar":
            if let payload = try? AvatarPayload.from(jsonString: message.content) {
                memberAvatarStore?.apply(payload, from: message.senderPubkey)
            }

        case "group_avatar":
            // Admin-only, and this check is the only thing enforcing it.
            // Step 3c confirmed MarmotKit accepts a non-admin's custom event
            // intact, so nothing below the app rejects a spoofed group photo
            // — exactly as in v1. Verified by
            // testNonAdminCustomEventIsAcceptedSoTheAppMustCheckAdminItself.
            if await isAdmin(message.senderPubkey, ofGroup: message.mlsGroupId) {
                if let payload = try? GroupAvatarPayload.from(jsonString: message.content) {
                    sharedGroupAvatarStore?.apply(payload, for: message.mlsGroupId)
                }
            } else {
                WhistleLogger.chat.warning(
                    "Ignored group avatar from non-admin \(message.senderPubkey.prefix(8))"
                )
            }

        case .some(let other):
            WhistleLogger.chat.debug("Unknown chat sub-type '\(other)'")
        }
    }

    // MARK: - Mapping

    nonisolated private static func map(row: ChatListRowFfi, details: GroupDetailsFfi?) -> WhistleGroup {
        WhistleGroup(
            mlsGroupId: row.groupIdHex,
            name: row.groupName,
            // A group we have left, been removed from, or that was disbanded
            // is not active. `.unrecoverable` deliberately still counts as
            // active: it needs a re-admit to work again, but hiding it would
            // leave the user unable to see the group they have to act on.
            isActive: row.selfMembership == .member && row.lifecycleState != .disbanded,
            epoch: details?.mlsState.epoch ?? 0,
            adminPubkeys: details?.group.admins ?? [],
            // 0 means "no activity recorded", which v1 represents as nil.
            lastMessageAt: row.activitySortAt == 0 ? nil : row.activitySortAt
        )
    }

    nonisolated private static func map(timeline record: TimelineMessageRecordFfi) -> WhistleMessage {
        WhistleMessage(
            id: record.messageIdHex,
            mlsGroupId: record.groupIdHex,
            senderPubkey: record.sender,
            kind: UInt16(truncatingIfNeeded: record.kind),
            content: record.plaintext,
            createdAt: record.timelineAt
        )
    }

    nonisolated private static func map(received: ReceivedMessageFfi) -> WhistleMessage {
        WhistleMessage(
            id: received.messageIdHex,
            mlsGroupId: received.groupIdHex,
            senderPubkey: received.sender,
            kind: UInt16(truncatingIfNeeded: received.kind),
            content: received.plaintext,
            createdAt: received.sourceEpoch
        )
    }
}
