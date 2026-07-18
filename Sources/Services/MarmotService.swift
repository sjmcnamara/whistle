import Foundation
import WhistleCore
import NostrSDK
import MDKBindings

/// Orchestration layer connecting `MLSService` (MLS state machine) with
/// `RelayService` (Nostr relay I/O) via the four Marmot event kinds.
///
/// MarmotService is the single entry point for all Marmot protocol operations:
/// - **Kind 30443** — Key Package publishing & fetching
/// - **Kind 10051** — Key Package Relay List
/// - **Kind 444** — Welcome (NIP-59 gift-wrapped)
/// - **Kind 445** — Group events (commits, proposals, application messages)
///
/// It never touches raw crypto or relay connections directly — those are
/// delegated to `MLSService` and `RelayServiceProtocol` respectively.
@MainActor
final class MarmotService: ObservableObject {

    // MARK: - Dependencies

    private let relay: RelayServiceProtocol
    private let mls: MLSService
    private let publicKeyHex: String
    private let keys: Keys

    // MARK: - Injected caches (v0.4+)

    /// Injected by AppViewModel — receives decoded location messages.
    var locationCache: LocationCache?

    /// Injected by AppViewModel — receives nickname updates from incoming messages.
    var nicknameStore: NicknameStore?

    /// Injected by AppViewModel — auto-clears pending invites on Welcome receipt.
    var pendingInviteStore: PendingInviteStore?

    /// Injected by AppViewModel — used to persist/read lastEventTimestamp for `since` filter.
    var settings: AppSettings?

    /// Injected by AppViewModel — tracks groups with pending leave requests.
    var pendingLeaveStore: PendingLeaveStore?

    /// Injected by AppViewModel — queues unsolicited Welcomes for user approval.
    var pendingWelcomeStore: PendingWelcomeStore?

    /// Injected by AppViewModel — collects incoming join-requests (invitees who
    /// accepted an invite) so an admin can batch-add them.
    var joinRequestStore: JoinRequestStore?

    /// Injected by AppViewModel — fires local notifications on low battery.
    var batteryAlertService: BatteryAlertService?

    /// Called when an MLS-encrypted leave request (kind 2) arrives from a group member.
    /// Parameters: (groupId, memberPubkeyHex).
    var onLeaveRequestReceived: ((String, String) -> Void)?

    /// Tracks consecutive MLS failures per group — not persisted, resets on launch.
    let healthTracker = GroupHealthTracker()

    /// The post-join self-update — an immediate key rotation right after
    /// accepting a Welcome (MIP-02 hardening) — is disabled. It advanced the
    /// joiner to a new epoch during the fragile just-joined window before the
    /// admin's subscription had settled; the admin never converged on that
    /// epoch, so the group forked at formation and every subsequent message
    /// failed to decrypt. The joiner now stays at the Welcome's shared epoch.
    /// Re-enable only once a dropped commit is guaranteed recoverable (see the
    /// catch-up handling in `handleIncomingEvent` / `catchUpGroup`).
    private let postJoinSelfUpdateEnabled = false

    /// Subscription task for cancellation support.
    private var subscriptionTask: Task<Void, Error>?

    // Event IDs already processed — prevents expensive MLS re-processing
    // when `fetchMissedGiftWraps()` polls without a `since` filter (NIP-59
    // timestamp randomisation makes `since` unreliable for gift-wraps).
    // Now persisted in AppSettings to survive restarts.

    // MARK: - Published state

    /// Active MLS groups, refreshed after mutations.
    @Published private(set) var groups: [Group] = []

    /// Last error for UI display (non-fatal).
    @Published private(set) var lastError: String?

    /// Bumped when a chat message is received — ChatViewModel observes this.
    @Published private(set) var lastChatMessageGroupId: String?

    /// Bumped when a welcome is accepted — AppViewModel observes this to
    /// auto-broadcast the user's display name to the newly joined group.
    @Published private(set) var lastJoinedGroupId: String?

    /// Bumped when membership changes (member added/removed via commit events) — ChatViewModel observes
    /// this to refresh memberNames in the chat header. Tuple: (groupId, timestamp).
    @Published private(set) var lastGroupMembershipChangeId: (String, Date)?

    // MARK: - Public accessors

    /// Connected relay URLs — used by GroupDetailViewModel for invite generation.
    var activeRelayURLs: [String] { relay.connectedRelayURLs }

    // MARK: - Subscription tracking

    private var groupEventSubId: String?
    private var giftWrapSubId: String?

    // MARK: - Init

    /// - Parameters:
    ///   - relay: Relay I/O abstraction (production or mock).
    ///   - mls:   MLS state machine.
    ///   - publicKeyHex: Hex public key of the current user.
    ///   - keys: Nostr signing keys.
    init(relay: RelayServiceProtocol, mls: MLSService, publicKeyHex: String, keys: Keys) {
        self.relay = relay
        self.mls = mls
        self.publicKeyHex = publicKeyHex
        self.keys = keys
    }

    // MARK: - Kind 30443 — Key Packages

    /// Create, sign, publish, and return a new MLS key package as a kind-30443
    /// event. The returned JSON is the signed event an admin feeds to
    /// `mls.addMembers` — we also hand it to the inviter inline via the
    /// join-request so they can add us without a separate relay fetch.
    @discardableResult
    func publishKeyPackage(relays: [String]) async throws -> String {
        let kp = try await mls.createKeyPackage(publicKeyHex: publicKeyHex, relays: relays)

        let builder = EventBuilder(kind: Kind(kind: MarmotKind.keyPackage), content: kp.keyPackage)
        // Attach MLS tags from the key package result
        var tags: [Tag] = []
        for tag in kp.tags {
            guard tag.count >= 2 else { continue }
            tags.append(Tag.custom(kind: .unknown(unknown: tag[0]), values: Array(tag.dropFirst())))
        }
        // Sign locally so we can both publish AND embed the signed event inline.
        let signed = try builder.tags(tags: tags).signWithKeys(keys: keys)
        try await relay.sendEvent(signed)

        WhistleLogger.marmot.info("Published key package (kind 30443)")
        return try signed.asJson()
    }

    /// Fetch the latest key package for a given public key.
    func fetchKeyPackage(for pubkeyHex: String) async throws -> [Event] {
        let pk = try PublicKey.parse(publicKey: pubkeyHex)
        let filter = Filter()
            .kind(kind: Kind(kind: MarmotKind.keyPackage))
            .authors(authors: [pk])
            .limit(limit: 1)
        return try await relay.fetchEvents(filter: filter, timeout: 10)
    }

    /// Fetch a member's key package with exponential-backoff retry, returning its
    /// JSON. The invitee's key package may not have propagated to the relay yet
    /// (especially via NearbyShare, where the publish is deferred until after MPC
    /// tears down). Throws `.timeout` past a 60s budget, `.noKeyPackageFound` if
    /// none is ever seen.
    private func fetchKeyPackageWithRetry(for memberHex: String, maxRetries: Int) async throws -> String {
        let startTime = Date()
        let globalTimeout: TimeInterval = 60.0
        let relayCount = relay.connectedRelayURLs.count
        WhistleLogger.marmot.info("Fetching key package for \(memberHex.prefix(8))… from \(relayCount) relay(s)")

        var kpEvents: [Event] = []
        for attempt in 1...maxRetries {
            if Date().timeIntervalSince(startTime) > globalTimeout {
                throw MarmotError.timeout
            }
            do {
                kpEvents = try await fetchKeyPackage(for: memberHex)
            } catch {
                WhistleLogger.marmot.warning("fetchKeyPackage attempt \(attempt) failed: \(error)")
                // Continue retrying — relay may be temporarily unavailable
            }
            if !kpEvents.isEmpty {
                WhistleLogger.marmot.info("Found key package for \(memberHex.prefix(8))… on attempt \(attempt)")
                break
            }
            if attempt < maxRetries {
                let delay = min(0.5 * pow(2.0, Double(attempt - 1)), 30.0)
                WhistleLogger.marmot.info("Key package not found for \(memberHex.prefix(8))… (attempt \(attempt)/\(maxRetries)) — retrying in \(delay) s")
                try await Task.sleep(for: .seconds(delay))
            }
        }
        guard let kpEvent = kpEvents.first else {
            throw MarmotError.noKeyPackageFound(memberHex)
        }
        return try kpEvent.asJson()
    }

    // MARK: - Kind 10051 — Key Package Relay List

    /// Publish a replaceable key package relay list (kind 10051).
    func publishKeyPackageRelayList(relays: [String]) async throws {
        let content = ""
        var tags: [Tag] = []
        for url in relays {
            tags.append(Tag.custom(kind: .relayUrl, values: [url]))
        }
        let builder = EventBuilder(kind: Kind(kind: MarmotKind.keyPackageRelayList), content: content)
            .tags(tags: tags)
        try await relay.publish(builder: builder)

        WhistleLogger.marmot.info("Published key package relay list (kind 10051)")
    }

    /// Fetch the relay list for a given public key.
    func fetchKeyPackageRelayList(for pubkeyHex: String) async throws -> [Event] {
        let pk = try PublicKey.parse(publicKey: pubkeyHex)
        let filter = Filter()
            .kind(kind: Kind(kind: MarmotKind.keyPackageRelayList))
            .authors(authors: [pk])
            .limit(limit: 1)
        return try await relay.fetchEvents(filter: filter, timeout: 10)
    }

    // MARK: - Kind 445 — Group Events

    /// Publish a pre-built group event (kind 445) JSON string from MLS.
    func publishGroupEvent(eventJson: String) async throws {
        let event = try Event.fromJson(json: eventJson)
        var attempts = 0
        let maxRetries = 3
        while attempts < maxRetries {
            do {
                try await relay.sendEvent(event)
                WhistleLogger.marmot.debug("Published group event (kind 445)")
                return
            } catch {
                attempts += 1
                if attempts >= maxRetries {
                    throw error
                }
                let delay = min(0.5 * pow(2.0, Double(attempts - 1)), 10.0)
                WhistleLogger.marmot.warning("Failed to publish group event (attempt \(attempts)) — retrying in \(delay) s: \(error)")
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Verify that an event is retrievable from the relay after publishing.
    /// Retries with short backoff to allow relay indexing.
    /// Required by MIP-02: Commit must be queryable before Welcome is sent.
    private func verifyEventOnRelay(eventId: String, maxAttempts: Int = 3) async throws {
        let parsedId = try EventId.parse(id: eventId)
        let filter = Filter().ids(ids: [parsedId])

        for attempt in 1...maxAttempts {
            let events = try await relay.fetchEvents(filter: filter, timeout: 5)
            if !events.isEmpty { return }
            if attempt < maxAttempts {
                let delay = 0.5 * pow(2.0, Double(attempt - 1))
                WhistleLogger.marmot.info("Commit \(eventId.prefix(8))… not yet on relay (attempt \(attempt)/\(maxAttempts)) — retrying in \(delay)s")
                try await Task.sleep(for: .seconds(delay))
            }
        }
        throw MarmotError.commitVerificationFailed
    }

    /// Publish commit evolution event(s) and confirm they are retrievable from
    /// the relay before returning.
    ///
    /// Unlike a fire-and-forget publish, this re-publishes and re-verifies
    /// across a few rounds. A self-update merges locally *before* it is
    /// published (old epoch secrets are dropped for forward secrecy), so a
    /// commit that silently fails to reach the relay leaves other members
    /// stranded on the previous epoch — the cause of "Some messages couldn't
    /// be decrypted." Confirming propagation (and retrying the publish) closes
    /// that gap. Re-publishing is idempotent: relays dedupe by event id.
    private func publishAndVerifyCommits(_ eventJsons: [String], maxRounds: Int = 2) async throws {
        var lastError: Error?
        for round in 1...maxRounds {
            do {
                for eventJson in eventJsons {
                    try await publishGroupEvent(eventJson: eventJson)
                }
                for eventJson in eventJsons {
                    let event = try Event.fromJson(json: eventJson)
                    try await verifyEventOnRelay(eventId: event.id().toHex())
                }
                return
            } catch {
                lastError = error
                WhistleLogger.marmot.warning("Commit publish/verify round \(round)/\(maxRounds) failed: \(error)")
                if round < maxRounds {
                    try await Task.sleep(for: .seconds(min(1.0 * pow(2.0, Double(round - 1)), 10.0)))
                }
            }
        }
        throw lastError ?? MarmotError.commitVerificationFailed
    }

    /// Encrypt and send a message to a group.
    /// - Parameters:
    ///   - content: Message content string.
    ///   - groupId: MLS group identifier.
    ///   - kind: Inner application kind (default: chat). Use `MarmotKind.location` for location updates.
    func sendMessage(content: String, toGroup groupId: String, kind: UInt16 = MarmotKind.chat) async throws {
        let eventJson = try await mls.createMessage(
            groupId: groupId,
            senderPublicKeyHex: publicKeyHex,
            content: content,
            kind: kind
        )
        try await publishGroupEvent(eventJson: eventJson)

        WhistleLogger.marmot.info("Sent message (kind \(kind)) to group \(groupId)")
    }

    /// Encode a location payload and send as kind-1 application message to a group.
    func sendLocationUpdate(_ payload: LocationPayload, toGroup groupId: String) async throws {
        let json = try payload.jsonString()
        try await sendMessage(content: json, toGroup: groupId, kind: MarmotKind.location)
    }

    /// Broadcast a nickname update to a group.
    func sendNicknameUpdate(name: String, toGroup groupId: String) async throws {
        let payload = NicknamePayload(name: name)
        let json = try payload.jsonString()
        try await sendMessage(content: json, toGroup: groupId, kind: MarmotKind.chat)
    }

    // MARK: - Kind 444 — Welcome (NIP-59 gift-wrap)

    /// Add a member to a group: fetch their key package, run MLS addMembers,
    /// gift-wrap the welcome, and publish group evolution events.
    func addMember(publicKeyHex memberHex: String, toGroup groupId: String, maxRetries: Int = 10) async throws {
        // Pre-flight: don't add yourself
        guard memberHex != publicKeyHex else {
            throw MarmotError.alreadyMember
        }

        // Pre-flight: check if member is already in the group
        if let existingMembers = try? await mls.getMembers(groupId: groupId),
           existingMembers.contains(memberHex) {
            throw MarmotError.alreadyMember
        }

        // Pre-flight: verify relay connectivity
        guard !relay.connectedRelayURLs.isEmpty else {
            throw MarmotError.noRelaysConnected
        }

        // 1. Fetch the member's key package.
        let kpJson = try await fetchKeyPackageWithRetry(for: memberHex, maxRetries: maxRetries)

        // 2. MLS addMembers
        let result = try await mls.addMembers(groupId: groupId, keyPackageEventsJson: [kpJson])
        try await mls.mergePendingCommit(groupId: groupId)

        // 3. Publish the evolution event (kind 445) with retry
        let payload = result.publishPayload(relayURLs: relay.connectedRelayURLs)
        var publishAttempts = 0
        let maxPublishRetries = 3
        while publishAttempts < maxPublishRetries {
            do {
                for eventJson in payload.events {
                    try await publishGroupEvent(eventJson: eventJson)
                }
                break // success
            } catch {
                publishAttempts += 1
                if publishAttempts >= maxPublishRetries {
                    throw error
                }
                let delay = min(0.5 * pow(2.0, Double(publishAttempts - 1)), 10.0)
                WhistleLogger.marmot.warning("Failed to publish group events (attempt \(publishAttempts)) — retrying in \(delay) s: \(error)")
                try await Task.sleep(for: .seconds(delay))
            }
        }

        // 3b. Verify the commit is retrievable from the relay before
        //     sending the Welcome — prevents state forks (MIP-02).
        for eventJson in payload.events {
            let event = try Event.fromJson(json: eventJson)
            try await verifyEventOnRelay(eventId: event.id().toHex())
        }

        // 4. Gift-wrap and publish welcome rumors (kind 444 inside kind 1059)
        try await giftWrapAndPublishWelcomes(
            welcomeRumors: payload.welcomeRumors,
            receiverHex: memberHex
        )

        await refreshGroups()
        WhistleLogger.marmot.info("Added member \(memberHex) to group \(groupId)")
    }

    /// Gift-wrap each welcome rumor and send to the receiver via NIP-59.
    func giftWrapAndPublishWelcomes(welcomeRumors: [String], receiverHex: String) async throws {
        let receiverPK = try PublicKey.parse(publicKey: receiverHex)

        for rumorJson in welcomeRumors {
            let rumor = try UnsignedEvent.fromJson(json: rumorJson)
            try await relay.giftWrap(receiver: receiverPK, rumor: rumor, extraTags: [])
        }

        WhistleLogger.marmot.debug("Gift-wrapped \(welcomeRumors.count) welcome(s) for \(receiverHex)")
    }

    // MARK: - Remove member

    /// Remove a member from a group — verified commit (v1.6.1 anti-fork). An
    /// unconfirmed removal commit would strand the *remaining* members on the old
    /// epoch (they'd still think the removed member is present) while the admin
    /// advanced, desyncing decryption. Clears the member's cached location.
    func removeMember(publicKeyHex memberHex: String, inGroup groupId: String) async throws {
        let result = try await mls.removeMembers(groupId: groupId, memberPublicKeys: [memberHex])
        try await mls.mergePendingCommit(groupId: groupId)
        try await publishAndVerifyCommits(result.publishPayload(relayURLs: relay.connectedRelayURLs).events)
        locationCache?.removeLocation(groupId: groupId, memberPubkeyHex: memberHex)
        await refreshGroups()
        WhistleLogger.marmot.info("Removed member \(memberHex.prefix(8))… from group \(groupId)")
    }

    // MARK: - Hard resync (fork recovery)

    /// Hard resync: remove a member and immediately re-add them with a fresh key
    /// package, rebuilding their leaf in the ratchet tree. This is the only cure
    /// for a true fork — where the member merged a commit others never got — that
    /// soft catch-up (`catchUpGroup`) cannot reach, because MDK permanently marks
    /// such a commit `.previouslyFailed` and refuses to re-apply it.
    ///
    /// Ordering is deliberate: the key package is fetched FIRST, so we never
    /// remove someone we cannot re-add. The only window the member is out of the
    /// group is between a successful remove and the re-add, with their key package
    /// already in hand. If the re-add fails after removal, this throws
    /// `.reAddFailed` so the UI can offer a retry rather than silently stranding
    /// them. Both commits are verified on the relay (v1.6.1 anti-fork).
    func resyncMember(publicKeyHex memberHex: String, inGroup groupId: String) async throws {
        guard memberHex != publicKeyHex else { throw MarmotError.alreadyMember }
        guard !relay.connectedRelayURLs.isEmpty else { throw MarmotError.noRelaysConnected }

        // 1. Fetch the fresh key package FIRST — abort before touching the group.
        let kpJson = try await fetchKeyPackageWithRetry(for: memberHex, maxRetries: 10)

        // 2. Remove the member — verified commit. Skip if a previous attempt
        //    already removed them (re-add failed and the admin tapped Resync
        //    again) — otherwise removeMembers would throw on a non-member.
        let stillMember = (try? await mls.getMembers(groupId: groupId))?.contains(memberHex) ?? true
        if stillMember {
            let removeResult = try await mls.removeMembers(groupId: groupId, memberPublicKeys: [memberHex])
            try await mls.mergePendingCommit(groupId: groupId)
            try await publishAndVerifyCommits(removeResult.publishPayload(relayURLs: relay.connectedRelayURLs).events)
            locationCache?.removeLocation(groupId: groupId, memberPubkeyHex: memberHex)
            WhistleLogger.marmot.info("Hard resync: removed \(memberHex.prefix(8))… from group \(groupId)")
        } else {
            WhistleLogger.marmot.info("Hard resync: \(memberHex.prefix(8))… already removed — re-adding only")
        }

        // 3. Re-add with the key package already in hand — verified commit + Welcome.
        do {
            let addResult = try await mls.addMembers(groupId: groupId, keyPackageEventsJson: [kpJson])
            try await mls.mergePendingCommit(groupId: groupId)
            let addPayload = addResult.publishPayload(relayURLs: relay.connectedRelayURLs)
            try await publishAndVerifyCommits(addPayload.events)
            try await giftWrapAndPublishWelcomes(welcomeRumors: addPayload.welcomeRumors, receiverHex: memberHex)
        } catch {
            WhistleLogger.marmot.error("Hard resync: re-add failed after removing \(memberHex.prefix(8))…: \(error)")
            throw MarmotError.reAddFailed(memberHex)
        }

        await refreshGroups()
        WhistleLogger.marmot.info("Hard resync complete for \(memberHex.prefix(8))… in group \(groupId)")
    }

    // MARK: - Batch add (join-requests)

    /// Outcome of a batch add.
    struct BatchAddResult: Equatable {
        /// Pubkeys now in the group (added by this batch, or already members).
        let added: [String]
    }

    /// Add several joiners from their gift-wrapped join-requests in a SINGLE MLS
    /// commit — one epoch bump for the whole batch, instead of one per person.
    /// Each request carries the member's signed key package inline, so there's no
    /// relay fetch (and no "key package not found" race).
    ///
    /// Atomic: either the whole commit lands (published, verified, welcomes routed)
    /// or the group is left unchanged. A single invalid/stale key package fails the
    /// batch; the admin can dismiss that request and retry. Members already in the
    /// group are skipped and reported as added.
    @discardableResult
    func addMembers(_ requests: [JoinRequest], toGroup groupId: String) async throws -> BatchAddResult {
        guard !requests.isEmpty else { return BatchAddResult(added: []) }
        guard !relay.connectedRelayURLs.isEmpty else { throw MarmotError.noRelaysConnected }

        let existing = (try? await mls.getMembers(groupId: groupId)).map(Set.init) ?? []
        let alreadyIn = requests.filter { existing.contains($0.pubkey) }.map { $0.pubkey }
        let toAdd = requests.filter { !existing.contains($0.pubkey) }
        guard !toAdd.isEmpty else { return BatchAddResult(added: alreadyIn) }

        do {
            // 1. One commit for all the inline key packages.
            let result = try await mls.addMembers(groupId: groupId, keyPackageEventsJson: toAdd.map { $0.keyPackage })
            try await mls.mergePendingCommit(groupId: groupId)

            // 2. Publish the evolution event(s) with retry.
            let payload = result.publishPayload(relayURLs: relay.connectedRelayURLs)
            var attempts = 0
            while true {
                do {
                    for eventJson in payload.events { try await publishGroupEvent(eventJson: eventJson) }
                    break
                } catch {
                    attempts += 1
                    if attempts >= 3 { throw error }
                    try await Task.sleep(for: .seconds(min(0.5 * pow(2.0, Double(attempts - 1)), 10.0)))
                }
            }

            // 3. Verify the commit landed before sending Welcomes (MIP-02 anti-fork).
            for eventJson in payload.events {
                let event = try Event.fromJson(json: eventJson)
                try await verifyEventOnRelay(eventId: event.id().toHex())
            }

            // 4. Route each Welcome to its member by the rumor's `e` tag.
            try await routeWelcomes(payload.welcomeRumors, requests: toAdd)

            await refreshGroups()
            WhistleLogger.marmot.info("Batch-added \(toAdd.count) member(s) to group \(groupId) in one commit")
            return BatchAddResult(added: alreadyIn + toAdd.map { $0.pubkey })
        } catch {
            // Roll back any unmerged pending commit so the group is left unchanged.
            try? await mls.clearPendingCommit(groupId: groupId)
            WhistleLogger.marmot.error("Batch add to group \(groupId) failed — rolled back: \(error)")
            throw error
        }
    }

    /// Gift-wrap each Welcome rumor to its intended member. MDK returns one rumor
    /// per added member, tagged with `e` = the key package event id used to add
    /// them; we map that id back to the member's pubkey. Falls back to positional
    /// order (rumor[i] ← requests[i]) if a tag is missing — see research in PR2b.
    private func routeWelcomes(_ welcomeRumors: [String], requests: [JoinRequest]) async throws {
        var kpIdToPubkey: [String: String] = [:]
        for req in requests {
            if let id = try? Event.fromJson(json: req.keyPackage).id().toHex() {
                kpIdToPubkey[id] = req.pubkey
            }
        }
        for (index, rumorJson) in welcomeRumors.enumerated() {
            let receiverHex: String
            if let kpId = Self.firstETag(inRumorJson: rumorJson), let pk = kpIdToPubkey[kpId] {
                receiverHex = pk
            } else if index < requests.count {
                receiverHex = requests[index].pubkey
                WhistleLogger.marmot.warning("Welcome rumor \(index): no e-tag match — using positional recipient")
            } else {
                WhistleLogger.marmot.error("Welcome rumor \(index): cannot route — skipping")
                continue
            }
            let rumor = try UnsignedEvent.fromJson(json: rumorJson)
            let receiverPK = try PublicKey.parse(publicKey: receiverHex)
            try await relay.giftWrap(receiver: receiverPK, rumor: rumor, extraTags: [])
        }
    }

    /// First `e` tag value (the key package event id) in a rumor's JSON.
    static func firstETag(inRumorJson json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tags = obj["tags"] as? [[String]] else { return nil }
        for tag in tags where tag.count >= 2 && tag[0] == "e" { return tag[1] }
        return nil
    }

    // MARK: - Group Lifecycle

    /// Create a new MLS group and publish welcome events for initial members.
    func createGroup(
        name: String,
        description: String = "",
        memberKeyPackageEventsJson: [String] = [],
        relays: [String]
    ) async throws -> String {
        let result = try await mls.createGroup(
            creatorPublicKeyHex: publicKeyHex,
            memberKeyPackageEventsJson: memberKeyPackageEventsJson,
            name: name,
            description: description,
            relays: relays
        )
        let groupId = result.group.mlsGroupId
        try await mls.mergePendingCommit(groupId: groupId)

        // Gift-wrap welcome rumors to each member
        let payload = result.publishPayload(relayURLs: relays)
        // For creation with members, we'd need to resolve each member's pubkey
        // from their key package. For now, welcomes are empty for solo groups.
        if !payload.welcomeRumors.isEmpty {
            WhistleLogger.marmot.debug("Group created with \(payload.welcomeRumors.count) welcome(s) to send")
        }

        await refreshGroups()
        WhistleLogger.marmot.info("Created group '\(name)' id=\(groupId)")
        return groupId
    }

    /// Send a leave-request message (kind 2) to the group so the admin can
    /// process the removal and trigger MLS key rotation.
    func sendLeaveRequest(groupId: String) async throws {
        try await sendMessage(content: "", toGroup: groupId, kind: MarmotKind.leaveRequest)
        WhistleLogger.marmot.info("Sent leave request for group \(groupId)")
    }

    /// Promote a member to admin: update the group's admin list via MLS metadata.
    func promoteToAdmin(pubkeyHex: String, inGroup groupId: String) async throws {
        guard let group = groups.first(where: { $0.mlsGroupId == groupId }) else { return }
        var admins = group.adminPubkeys
        guard !admins.contains(pubkeyHex) else { return }
        admins.append(pubkeyHex)

        let update = GroupDataUpdate(
            name: nil, description: nil, imageHash: nil,
            imageKey: nil, imageNonce: nil, relays: nil,
            admins: admins
        )
        let result = try await mls.updateGroupData(groupId: groupId, update: update)
        try await mls.mergePendingCommit(groupId: groupId)

        // Confirm the metadata commit reached the relay — like a self-update it
        // merges locally first, so an unpropagated commit desyncs the epoch.
        try await publishAndVerifyCommits(result.publishPayload(relayURLs: relay.connectedRelayURLs).events)

        await refreshGroups()
        WhistleLogger.marmot.info("Promoted \(pubkeyHex) to admin in group \(groupId)")
    }

    /// Rename a group: update MLS metadata, merge, publish the evolution event.
    func renameGroup(_ groupId: String, to newName: String) async throws {
        let update = GroupDataUpdate(
            name: newName,
            description: nil,
            imageHash: nil,
            imageKey: nil,
            imageNonce: nil,
            relays: nil,
            admins: nil
        )
        let result = try await mls.updateGroupData(groupId: groupId, update: update)
        try await mls.mergePendingCommit(groupId: groupId)

        // Confirm the metadata commit reached the relay — like a self-update it
        // merges locally first, so an unpropagated commit desyncs the epoch.
        try await publishAndVerifyCommits(result.publishPayload(relayURLs: relay.connectedRelayURLs).events)

        await refreshGroups()
        WhistleLogger.marmot.info("Renamed group \(groupId) to '\(newName)'")
    }

    // MARK: - Incoming Event Handling

    /// Process an incoming event from a relay subscription.
    func handleIncomingEvent(_ event: Event) async {
        let eventId = event.id().toHex()

        // Skip already-processed events — prevents expensive MLS re-work
        // during fetchMissedGiftWraps polling (which has no `since` filter).
        guard !(settings?.processedEventIds.contains(eventId) ?? false) else {
            WhistleLogger.marmot.debug("Skipping duplicate event \(eventId.prefix(8)) (kind \(event.kind().asU16()))")
            return
        }

        let kind = event.kind().asU16()

        do {
            switch kind {
            case MarmotKind.giftWrap:
                try await handleGiftWrap(event)

            case MarmotKind.groupEvent:
                try await handleGroupEvent(event)

            case MarmotKind.keyPackage:
                // Key package rotation — log for now, fetch on demand.
                WhistleLogger.marmot.debug("Received key package update (kind 30443)")

            default:
                WhistleLogger.marmot.debug("Ignoring event kind \(kind)")
            }

            // If this gift-wrap was previously failed, clear it on success.
            if kind == MarmotKind.giftWrap {
                settings?.pendingGiftWrapEventIds.remove(eventId)
            }

            // Mark as processed so fetchMissedGiftWraps polling skips it.
            settings?.processedEventIds.insert(eventId)
            WhistleLogger.marmot.debug("Processed event \(eventId.prefix(8)) (kind \(kind))")

            // Update the high-water mark so the next subscription reconnect
            // uses a `since` filter and only fetches newer events.
            let eventTs = event.createdAt().asSecs()
            if let settings, eventTs > settings.lastEventTimestamp {
                settings.lastEventTimestamp = eventTs
            }
        } catch let error as MLSService.MLSError {
            // MLS-layer failures (not initialised, epoch mismatch) are for groups
            // we DO belong to. Deliberately NOT marked processed: a commit we
            // couldn't apply yet (out of order, or arriving before we'd settled)
            // must stay eligible so `catchUpGroup` can re-fetch and re-apply it.
            // Marking it processed here is what made forks permanent — a single
            // dropped commit could never be retried by any recovery path.
            if kind == MarmotKind.giftWrap,
               error.localizedDescription.contains("No matching key package") {
                settings?.pendingGiftWrapEventIds.insert(eventId)
                WhistleLogger.marmot.info("Queued gift-wrap \(eventId) for retry after key package refresh")
            }
            WhistleLogger.marmot.warning("MLS error processing event kind \(kind): \(error.localizedDescription)")
        } catch {
            if kind == MarmotKind.giftWrap,
               String(describing: error).contains("No matching key package") {
                settings?.pendingGiftWrapEventIds.insert(eventId)
                WhistleLogger.marmot.info("Queued gift-wrap \(eventId) for retry after key package refresh")
            }

            let msg = String(describing: error)
            // The relay-wide kind-445 filter delivers events for groups we're not
            // in; those throw "group not found" and can never apply, so mark them
            // processed to avoid re-scanning. A failure for one of OUR groups (a
            // commit we can't yet apply, an undecryptable message) is left
            // unrecorded so catch-up can re-apply it once we're able.
            let isForeignGroup = msg.contains("group not found") || msg.contains("not found")
            if kind != MarmotKind.giftWrap, isForeignGroup {
                settings?.processedEventIds.insert(eventId)
            }
            if isForeignGroup {
                WhistleLogger.marmot.debug("MDK skipped event kind \(kind): \(msg)")
            } else {
                lastError = error.localizedDescription
                WhistleLogger.marmot.error("Error handling event kind \(kind): \(error)")
            }
        }
    }

    /// Unwrap a NIP-59 gift-wrap and process the inner welcome (kind 444).
    private func handleGiftWrap(_ event: Event) async throws {
        let gift = try await relay.unwrapGiftWrap(event: event)
        let rumor = gift.rumor()
        let rumorKind = rumor.kind().asU16()

        // Join-request from an invitee who accepted our invite — queue it for the
        // admin to batch-add. (Their KeyPackage rides inline in the payload.)
        if rumorKind == MarmotKind.joinRequest {
            if let request = try? JoinRequest.from(jsonString: rumor.content()) {
                joinRequestStore?.add(request)
                WhistleLogger.marmot.info("Received join-request from \(request.pubkey.prefix(8))… for group \(request.groupId)")
            } else {
                WhistleLogger.marmot.warning("Failed to decode join-request rumor — ignoring")
            }
            return
        }

        guard rumorKind == MarmotKind.welcome else {
            WhistleLogger.marmot.debug("Gift-wrap contained non-welcome kind \(rumorKind), ignoring")
            return
        }

        let wrapperEventId = event.id().toHex()
        let rumorJson = try rumor.asJson()

        let welcome = try await mls.processWelcome(
            wrapperEventId: wrapperEventId,
            rumorEventJson: rumorJson
        )

        // Check if user consented via an invite code
        let hasPendingInvite = pendingInviteStore?.pendingInvites.contains(where: {
            $0.groupHint == welcome.mlsGroupId
        }) ?? false

        if hasPendingInvite {
            // User explicitly accepted an invite — auto-join
            try await acceptWelcomeAndJoin(welcome)
        } else {
            // Unsolicited — queue for user approval
            let senderHex = event.author().toHex()
            let pending = PendingWelcome(
                mlsGroupId: welcome.mlsGroupId,
                senderPubkeyHex: senderHex,
                wrapperEventId: wrapperEventId
            )
            await MainActor.run {
                pendingWelcomeStore?.add(pending)
            }
            WhistleLogger.marmot.info("Queued unsolicited welcome for group \(welcome.mlsGroupId) from \(senderHex.prefix(8)) — awaiting user approval")
        }
    }

    /// Accept a processed Welcome and complete the join flow.
    func acceptWelcomeAndJoin(_ welcome: Welcome) async throws {
        do {
            try await mls.acceptWelcome(welcome)
        } catch {
            // If already accepted, check if group exists
            if (try? await mls.getGroup(mlsGroupId: welcome.mlsGroupId)) != nil {
                WhistleLogger.marmot.info("Welcome already accepted for group \(welcome.mlsGroupId)")
            } else {
                throw error
            }
        }
        await refreshGroups()

        // Post-join self-update: immediately rotate key material so we are not
        // relying on the Welcome's initial key package (MIP-02). Disabled — it
        // forks the group at formation; see `postJoinSelfUpdateEnabled`.
        if postJoinSelfUpdateEnabled {
            do {
                let updateResult = try await mls.selfUpdate(groupId: welcome.mlsGroupId)
                try await mls.mergePendingCommit(groupId: welcome.mlsGroupId)
                // Confirm the commit reached the relay — an unpropagated self-update
                // advances our epoch locally while other members stay behind, which
                // desyncs decryption in both directions.
                try await publishAndVerifyCommits(updateResult.publishPayload(relayURLs: relay.connectedRelayURLs).events)
                WhistleLogger.marmot.info("Post-join self-update completed for group \(welcome.mlsGroupId)")
            } catch {
                // Non-fatal: the join succeeded and we are usable at the Welcome's
                // epoch. The self-update commit could not be confirmed on the relay,
                // so the group may be desynced until the next successful commit.
                WhistleLogger.marmot.error("Post-join self-update failed to confirm on relay for group \(welcome.mlsGroupId): \(error)")
            }
        } else {
            WhistleLogger.marmot.info("Post-join self-update skipped for group \(welcome.mlsGroupId) — staying at Welcome epoch")
        }

        // Clear matching pending invite now that we've joined
        pendingInviteStore?.remove(groupHint: welcome.mlsGroupId)

        // If we had requested leave earlier, clear it now that we're rejoined.
        pendingLeaveStore?.remove(welcome.mlsGroupId)

        // Signal to AppViewModel so it can broadcast our display name
        lastJoinedGroupId = welcome.mlsGroupId

        WhistleLogger.marmot.info("Accepted welcome for group \(welcome.mlsGroupId)")
    }

    /// Accept a pending welcome that the user approved from the UI.
    func approvePendingWelcome(mlsGroupId: String) async throws {
        let welcomes = try await mls.getPendingWelcomes()
        guard let welcome = welcomes.first(where: { $0.mlsGroupId == mlsGroupId }) else {
            WhistleLogger.marmot.warning("No pending MLS welcome found for group \(mlsGroupId)")
            return
        }
        try await acceptWelcomeAndJoin(welcome)
        await MainActor.run {
            pendingWelcomeStore?.remove(mlsGroupId: mlsGroupId)
        }
    }

    /// Decline a pending welcome — discard it without joining.
    func declinePendingWelcome(mlsGroupId: String) async throws {
        let welcomes = try await mls.getPendingWelcomes()
        if let welcome = welcomes.first(where: { $0.mlsGroupId == mlsGroupId }) {
            try await mls.declineWelcome(welcome)
        }
        await MainActor.run {
            pendingWelcomeStore?.remove(mlsGroupId: mlsGroupId)
        }
        WhistleLogger.marmot.info("Declined welcome for group \(mlsGroupId)")
    }

    /// Process an incoming kind-445 group event through MLS.
    private func handleGroupEvent(_ event: Event) async throws {
        let eventJson = try event.asJson()
        let result = try await mls.processIncomingEvent(eventJson: eventJson)

        switch result {
        case .applicationMessage(let message):
            WhistleLogger.marmot.debug("Received application message in group \(message.mlsGroupId)")
            healthTracker.recordSuccess(groupId: message.mlsGroupId)
            routeApplicationMessage(message)

        case .commit(let groupId):
            let epoch = (try? await mls.getGroup(mlsGroupId: groupId))?.epoch ?? 0
            WhistleLogger.mls.info("Epoch advanced: group \(groupId) now at epoch \(epoch)")
            healthTracker.recordSuccess(groupId: groupId)
            // Refresh group state so member count updates reflect any membership changes
            await refreshGroups()
            // Notify subscribers that membership has changed
            lastGroupMembershipChangeId = (groupId, Date())

        case .proposal(let updateResult):
            // Auto-committed proposal — publish the evolution event
            let payload = updateResult.publishPayload(relayURLs: relay.connectedRelayURLs)
            for json in payload.events {
                try await publishGroupEvent(eventJson: json)
            }
            WhistleLogger.marmot.debug("Processed and published auto-committed proposal")
            // Refresh groups to reflect any membership or metadata changes
            await refreshGroups()
            // Notify subscribers that membership/metadata may have changed
            lastGroupMembershipChangeId = (updateResult.mlsGroupId, Date())

        case .pendingProposal(let groupId):
            WhistleLogger.marmot.debug("Stored pending proposal for group \(groupId)")
            // Refresh groups to reflect any membership changes
            await refreshGroups()
            // Notify subscribers that membership may have changed
            lastGroupMembershipChangeId = (groupId, Date())

        case .externalJoinProposal(let groupId):
            WhistleLogger.marmot.debug("External join proposal for group \(groupId)")

        case .unprocessable(let groupId):
            self.healthTracker.recordFailure(groupId: groupId)
            let failCount = self.healthTracker.failureCount(for: groupId)
            WhistleLogger.mls.warning("Unprocessable event for group \(groupId) — old epoch key likely deleted (forward secrecy). Failures: \(failCount)")

        case .ignoredProposal(let groupId, let reason):
            WhistleLogger.marmot.debug("Ignored proposal for \(groupId): \(reason)")

        case .previouslyFailed:
            WhistleLogger.marmot.debug("Skipping previously failed message")
        }
    }

    // MARK: - Application Message Routing

    /// Route a decrypted application message to the appropriate handler.
    ///
    /// Currently supports:
    /// - `MarmotKind.location` (kind 1) → decode `LocationPayload` → `LocationCache`
    /// - All other kinds → logged and ignored.
    private func routeApplicationMessage(_ message: Message) {
        switch message.kind {
        case MarmotKind.location:
            guard let content = message.plaintextContent else {
                WhistleLogger.marmot.warning("Location message missing content in group \(message.mlsGroupId)")
                return
            }
            do {
                let payload = try LocationPayload.from(jsonString: content)
                locationCache?.update(
                    groupId: message.mlsGroupId,
                    memberPubkeyHex: message.senderPubkey,
                    payload: payload
                )
                batteryAlertService?.check(pubkeyHex: message.senderPubkey, battery: payload.batt)
                WhistleLogger.marmot.info("Updated location for \(message.senderPubkey.prefix(8)) in group \(message.mlsGroupId)")
            } catch {
                WhistleLogger.marmot.error("Failed to decode location payload: \(error)")
            }

        case MarmotKind.chat:
            guard let content = message.plaintextContent else {
                WhistleLogger.chat.warning("Chat message missing content in group \(message.mlsGroupId)")
                return
            }
            // Determine sub-type from JSON "type" field
            if let data = content.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type = json["type"] as? String {
                switch type {
                case "chat":
                    lastChatMessageGroupId = message.mlsGroupId
                    WhistleLogger.chat.debug("Chat message in group \(message.mlsGroupId) from \(message.senderPubkey.prefix(8))")
                case "nickname":
                    if let payload = try? NicknamePayload.from(jsonString: content) {
                        nicknameStore?.set(name: payload.name, for: message.senderPubkey)
                        WhistleLogger.chat.info("Nickname update: \(message.senderPubkey.prefix(8)) → \(payload.name)")
                    }
                default:
                    WhistleLogger.chat.debug("Unknown chat sub-type '\(type)' in group \(message.mlsGroupId)")
                }
            } else {
                // Fallback: treat as plain chat text
                lastChatMessageGroupId = message.mlsGroupId
                WhistleLogger.chat.debug("Plain chat message in group \(message.mlsGroupId)")
            }

        case MarmotKind.leaveRequest:
            // A member is requesting to leave. Surface to the admin so they
            // can process the removal (which triggers key rotation).
            settings?.pendingLeaveRequests[message.mlsGroupId, default: Set()].insert(message.senderPubkey)
            onLeaveRequestReceived?(message.mlsGroupId, message.senderPubkey)
            WhistleLogger.marmot.info("Leave request from \(message.senderPubkey.prefix(8)) in group \(message.mlsGroupId)")

        default:
            WhistleLogger.marmot.debug("Unknown application message kind \(message.kind) in group \(message.mlsGroupId)")
        }
    }

    // MARK: - Key Rotation (Forward Secrecy)

    /// Check all groups for stale encryption keys and perform MLS self-update
    /// (epoch advance) on any that exceed the configured rotation interval.
    ///
    /// Each rotation produces a new epoch — old epoch secrets are deleted by
    /// MDK/OpenMLS per RFC 9420 §14.1, providing forward secrecy.
    func rotateStaleGroups() async {
        guard let thresholdSecs = settings?.keyRotationIntervalSecs else { return }

        let staleGroupIds: [String]
        do {
            staleGroupIds = try await mls.groupsNeedingSelfUpdate(thresholdSecs: thresholdSecs)
        } catch {
            WhistleLogger.mls.error("Failed to query stale groups: \(error)")
            return
        }

        guard !staleGroupIds.isEmpty else {
            WhistleLogger.mls.debug("No groups need key rotation (threshold=\(thresholdSecs)s)")
            return
        }

        WhistleLogger.mls.info("Key rotation: \(staleGroupIds.count) group(s) need self-update")

        for groupId in staleGroupIds {
            do {
                // Snapshot epoch before rotation for audit logging
                let oldEpoch = try await mls.getGroup(mlsGroupId: groupId)?.epoch ?? 0

                let result = try await mls.selfUpdate(groupId: groupId)
                try await mls.mergePendingCommit(groupId: groupId)

                let newEpoch = try await mls.getGroup(mlsGroupId: groupId)?.epoch ?? 0
                WhistleLogger.mls.info("Key rotation: group \(groupId) epoch \(oldEpoch) → \(newEpoch)")

                // Publish the evolution event so other members advance their
                // epoch — and confirm it landed. A rotation that merges locally
                // but never reaches the relay strands other members on the old
                // epoch, breaking decryption both ways.
                try await publishAndVerifyCommits(result.publishPayload(relayURLs: relay.connectedRelayURLs).events)

                WhistleLogger.mls.info("Key rotation: published + verified evolution event for group \(groupId)")
            } catch {
                // Per-group error handling — don't let one failure block others
                WhistleLogger.mls.error("Key rotation failed for group \(groupId): \(error)")
            }
        }

        await refreshGroups()
    }

    // MARK: - Subscriptions

    /// Open subscriptions for group events (kind 445) and gift-wraps (kind 1059).
    ///
    /// Applies a `since` filter based on `settings.lastEventTimestamp` so the
    /// device catches up on events missed while offline.
    ///
    /// Wraps `handleNotifications()` in a retry loop — if the notification
    /// stream drops (relay disconnect, network change), we reconnect and resume.
    func startSubscriptions() {
        subscriptionTask = Task {
            while !Task.isCancelled {
                do {
                    try await openSubscriptionsAndListen()
                    // Clean return (e.g. mock in tests) — no retry needed.
                    break
                } catch {
                    if Task.isCancelled { break }
                    WhistleLogger.marmot.error("Notification loop exited: \(error)")
                    lastError = error.localizedDescription
                    // Back off before retrying
                    try? await Task.sleep(for: .seconds(1))
                    await reconnectRelaysIfNeeded()
                }
            }
        }
        // Don't await subscriptionTask?.value — the notification loop is
        // infinite and would block the caller (onAppear) forever. The task
        // is stored in subscriptionTask for cancellation if needed.
    }

    /// Inner subscription setup + notification loop. Throws on error to
    /// trigger the outer retry in `startSubscriptions()`.
    private func openSubscriptionsAndListen() async throws {
        let myPK = try PublicKey.parse(publicKey: publicKeyHex)

        // Build filters — apply `since` if we have a stored timestamp
        var groupFilter = Filter()
            .kind(kind: Kind(kind: MarmotKind.groupEvent))
        var giftFilter = Filter()
            .kind(kind: Kind(kind: MarmotKind.giftWrap))
            .pubkeys(pubkeys: [myPK])

        if let ts = settings?.lastEventTimestamp, ts > 0 {
            let since = Timestamp.fromSecs(secs: ts)
            groupFilter = groupFilter.since(timestamp: since)
            // NOTE: Do NOT apply `since` to the gift-wrap filter.
            // NIP-59 randomises the gift-wrap created_at timestamp to
            // prevent timing analysis — a `since` filter would miss
            // Welcomes whose randomised timestamp falls before the cutoff.
            WhistleLogger.marmot.info("Applying since=\(ts) to group subscription (gift-wrap: no since)")
        }

        groupEventSubId = try await relay.subscribe(filter: groupFilter)
        giftWrapSubId = try await relay.subscribe(filter: giftFilter)

        WhistleLogger.marmot.info("Subscriptions started (group=\(self.groupEventSubId ?? "?"), gift=\(self.giftWrapSubId ?? "?"))")

        // Register notification handler — runs until error or disconnect
        let handler = NotificationHandler { [weak self] _, event in
            Task { @MainActor [weak self] in
                await self?.handleIncomingEvent(event)
            }
        }
        try await relay.handleNotifications(handler: handler)
    }

    /// Reconnect to relays if the connection has dropped.
    private func reconnectRelaysIfNeeded() async {
        guard relay.connectionState != .connected else { return }
        WhistleLogger.marmot.info("Reconnecting to relays…")
        if let settings {
            let enabled = settings.relays.filter(\.isEnabled)
            await relay.connect(keys: keys, relays: enabled)
        }
    }

    /// Force a full relay disconnect + reconnect regardless of current state.
    /// Call after MPC / NearbyShare — the WebSocket may appear connected but
    /// be in a degraded state where it silently drops incoming events.
    func forceReconnectRelays() async {
        WhistleLogger.marmot.info("Force-reconnecting relays (post-MPC)")
        await relay.disconnect()
        if let settings {
            let enabled = settings.relays.filter(\.isEnabled)
            await relay.connect(keys: keys, relays: enabled)
        }
    }

    /// Stop subscriptions and cancel the subscription task.
    func stopSubscriptions() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        groupEventSubId = nil
        giftWrapSubId = nil
        WhistleLogger.marmot.info("Subscriptions stopped")
    }

    /// One-shot fetch of gift-wrap events that may have been missed by the
    /// real-time subscription (e.g. during MPC-induced WiFi disruption).
    /// Safe to call repeatedly — already-processed welcomes will be caught
    /// by the existing MLS error handler and logged at warning level.
    ///
    /// NOTE: No `since` filter is applied. NIP-59 randomises the gift-wrap
    /// `created_at` timestamp to prevent timing analysis, so a time-based
    /// filter would miss Welcomes whose randomised timestamp falls before
    /// the cutoff. The pubkey filter already limits results to our events,
    /// and duplicate processing is handled by MLS error recovery.
    func fetchMissedGiftWraps() async {
        // Ensure relay is connected — MPC activity may have degraded the
        // WebSocket. A fresh connection guarantees the one-shot query works.
        await reconnectRelaysIfNeeded()

        do {
            let myPK = try PublicKey.parse(publicKey: publicKeyHex)

            let filter = Filter()
                .kind(kind: Kind(kind: MarmotKind.giftWrap))
                .pubkeys(pubkeys: [myPK])

            let events = try await relay.fetchEvents(filter: filter, timeout: 10)
            WhistleLogger.marmot.info("fetchMissedGiftWraps: \(events.count) event(s)")

            for event in events {
                await handleIncomingEvent(event)
            }

            if let pendingIds = settings?.pendingGiftWrapEventIds, !pendingIds.isEmpty {
                let pendingEventIds: [EventId] = pendingIds.compactMap { pendingId in
                    do {
                        return try EventId.parse(id: pendingId)
                    } catch {
                        WhistleLogger.marmot.warning("fetchMissedGiftWraps: invalid pending event id '\(pendingId)', removing")
                        settings?.pendingGiftWrapEventIds.remove(pendingId)
                        return nil
                    }
                }

                if !pendingEventIds.isEmpty {
                    // Snapshot the IDs before retry so we can detect which ones still fail.
                    let idsBeforeRetry = pendingIds

                    let pendingFilter = Filter().ids(ids: pendingEventIds)
                    let pendingEvents = try await relay.fetchEvents(filter: pendingFilter, timeout: 10)
                    WhistleLogger.marmot.info("fetchMissedGiftWraps: retrying pending gift-wraps (\(pendingEvents.count))")
                    for event in pendingEvents {
                        await handleIncomingEvent(event)
                    }

                    // Any IDs that are still pending after retry are permanently
                    // unrecoverable (key package gone from a previous DB). Mark
                    // them as processed so we stop refetching every launch.
                    let stillPending = settings?.pendingGiftWrapEventIds.intersection(idsBeforeRetry) ?? []
                    if !stillPending.isEmpty {
                        WhistleLogger.marmot.info("fetchMissedGiftWraps: expiring \(stillPending.count) unrecoverable gift-wrap(s)")
                        for id in stillPending {
                            settings?.pendingGiftWrapEventIds.remove(id)
                            settings?.processedEventIds.insert(id)
                        }
                    }
                }
            }
        } catch {
            WhistleLogger.marmot.error("fetchMissedGiftWraps failed: \(error)")
        }
    }

    /// Soft resync: re-fetch recent group (kind-445) events ignoring the normal
    /// `since` high-water mark and re-process them, so a commit this device
    /// never received — because it was offline or its subscription had a gap
    /// while the commit sat on the relay — can finally be applied and the local
    /// epoch caught up. This is why v1.6.1's publish-verify matters: the missed
    /// commit is now reliably retrievable.
    ///
    /// Deliberately does NOT self-update: a self-update from a behind device
    /// cannot heal a fork and would only deepen divergence. Events already seen
    /// (in `processedEventIds`) are skipped by `handleIncomingEvent`, so a
    /// commit that was received-but-unprocessable (a true fork) is not retried
    /// here — MDK also permanently marks such a message `.previouslyFailed` and
    /// refuses to re-apply it. Both cases need the admin re-invite (hard) path.
    ///
    /// Success is measured by whether the local epoch advanced — i.e. a missed
    /// commit was actually applied — NOT by the health tracker. The 30-day
    /// window can contain an old pre-desync application message that decrypts
    /// fine and would spuriously clear the banner via `recordSuccess` while the
    /// group stays behind on the current epoch. Epoch delta is the only signal
    /// that reflects real recovery.
    ///
    /// Returns true if a missed commit was applied (the group caught up).
    @discardableResult
    func catchUpGroup(groupId: String) async -> Bool {
        // MPC/background activity may have degraded the socket — a fresh
        // connection guarantees the one-shot query works.
        await reconnectRelaysIfNeeded()

        let epochBefore = (try? await mls.getGroup(mlsGroupId: groupId))?.epoch ?? 0

        // Bounded lookback rather than all of history: kind-445 also carries
        // every location update, so an unbounded fetch would be huge. Any
        // still-relevant missed commit is recent (well inside the 7-day
        // rotation interval); 30 days is a generous safety margin.
        let lookbackSecs: UInt64 = 30 * 24 * 3600
        let nowSecs = UInt64(Date().timeIntervalSince1970)
        let sinceSecs = nowSecs > lookbackSecs ? nowSecs - lookbackSecs : 0

        do {
            let filter = Filter()
                .kind(kind: Kind(kind: MarmotKind.groupEvent))
                .since(timestamp: Timestamp.fromSecs(secs: sinceSecs))
            let events = try await relay.fetchEvents(filter: filter, timeout: 10)
            WhistleLogger.marmot.info("catchUpGroup(\(groupId)): re-processing \(events.count) group event(s)")
            for event in events {
                await handleIncomingEvent(event)
            }
        } catch {
            WhistleLogger.marmot.error("catchUpGroup(\(groupId)) fetch failed: \(error)")
        }

        let epochAfter = (try? await mls.getGroup(mlsGroupId: groupId))?.epoch ?? epochBefore
        let recovered = epochAfter > epochBefore
        if recovered {
            // A missed commit was applied — we're back on the shared epoch.
            // Clear any residual failure count that other events re-processed in
            // the window may have recorded during the pass.
            healthTracker.recordSuccess(groupId: groupId)
        }
        WhistleLogger.marmot.info("catchUpGroup(\(groupId)): epoch \(epochBefore) → \(epochAfter), recovered=\(recovered)")
        return recovered
    }

    // MARK: - Invite Flow

    /// Generate a shareable invite code for a group.
    func generateInviteCode(for groupId: String, relay relayURL: String) throws -> String {
        let npub = try keys.publicKey().toBech32()
        let invite = InviteCode(relay: relayURL, inviterNpub: npub, groupId: groupId)
        return invite.encode()
    }

    /// Accept an invite: connect to the invite's relay, publish our key package,
    /// and send the inviter a join-request so they can batch-add us.
    func acceptInvite(_ encoded: String) async throws {
        let invite = try InviteCode.decode(from: encoded)

        // The relay in the invite is the guaranteed common ground with the admin.
        // Connect to it (Nostr has no global discovery) so our key package AND the
        // join-request below actually land where the admin reads — not just on
        // whichever relays we happened to already be connected to.
        await relay.ensureRelay(invite.relay)

        // Publish our key package to ALL connected relays so the admin can find it
        // regardless of which relay they query.
        let allRelays = relay.connectedRelayURLs
        let keyPackageJson = try await publishKeyPackage(relays: allRelays)

        // Tell the inviter directly that we're ready to join, carrying our key
        // package inline so they can batch-add us with no separate relay fetch.
        // Private: it rides inside a NIP-59 gift-wrap to the inviter — nothing on
        // a public event reveals our intent to join. Non-fatal on failure: the
        // admin can still add us by npub the old way.
        do {
            let inviterPK = try PublicKey.parse(publicKey: invite.inviterNpub)
            let joinRequest = JoinRequest(
                groupId: invite.groupId,
                pubkey: publicKeyHex,
                keyPackage: keyPackageJson,
                name: nicknameStore?.displayName(for: publicKeyHex)
            )
            let rumor = EventBuilder(
                kind: Kind(kind: MarmotKind.joinRequest),
                content: try joinRequest.jsonString()
            ).build(publicKey: keys.publicKey())
            try await relay.giftWrap(receiver: inviterPK, rumor: rumor, extraTags: [])
            WhistleLogger.marmot.info("Sent join-request to inviter for group \(invite.groupId)")
        } catch {
            WhistleLogger.marmot.warning("Failed to send join-request (admin can still add by npub): \(error)")
        }

        WhistleLogger.marmot.info("Accepted invite for group \(invite.groupId) from \(invite.inviterNpub) — key package published to \(allRelays.count) relay(s)")
    }

    // MARK: - Helpers

    /// Refresh the local groups list from MLS.
    func refreshGroups() async {
        do {
            let loaded = try await mls.getGroups()
            groups = loaded
            WhistleLogger.marmot.info("refreshGroups: \(loaded.count) group(s) loaded from MDK — active: \(loaded.filter(\.isActive).count)")
        } catch {
            WhistleLogger.marmot.error("refreshGroups FAILED: \(error)")
        }
    }

    // MARK: - Errors

    enum MarmotError: LocalizedError {
        case noKeyPackageFound(String)
        case timeout
        case commitVerificationFailed
        case alreadyMember
        case noRelaysConnected
        case reAddFailed(String)

        var errorDescription: String? {
            switch self {
            case .noKeyPackageFound:
                return "No key package found for this member. Make sure they have the app open and are connected to the same relay."
            case .timeout:
                return "Operation timed out — could not find key package for this member. Ask them to re-open the app and try again."
            case .commitVerificationFailed:
                return "Could not verify commit on relay — Welcome not sent to avoid state fork"
            case .alreadyMember:
                return "This person is already a member of the group"
            case .noRelaysConnected:
                return "Not connected to any relay — check your connection"
            case .reAddFailed:
                return "Removed the member, but re-adding them failed. Tap Resync again to retry."
            }
        }
    }
}
