import Foundation
import WhistleCore
import NostrSDK
import MDKBindings

/// Orchestration layer connecting `MLSService` (MLS state machine) with
/// `RelayService` (Nostr relay I/O) via the four Marmot event kinds.
///
/// MarmotService is the single entry point for all Marmot protocol operations:
/// - **Kind 443** — Key Package publishing & fetching
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

    /// Called when an MLS-encrypted leave request (kind 2) arrives from a group member.
    /// Parameters: (groupId, memberPubkeyHex).
    var onLeaveRequestReceived: ((String, String) -> Void)?

    /// Tracks consecutive MLS failures per group — not persisted, resets on launch.
    let healthTracker = GroupHealthTracker()

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

    // MARK: - Kind 443 — Key Packages

    /// Create and publish a new MLS key package as a kind-443 event.
    func publishKeyPackage(relays: [String]) async throws {
        let kp = try await mls.createKeyPackage(publicKeyHex: publicKeyHex, relays: relays)

        let builder = EventBuilder(kind: Kind(kind: MarmotKind.keyPackage), content: kp.keyPackage)
        // Attach MLS tags from the key package result
        var tags: [Tag] = []
        for tag in kp.tags {
            guard tag.count >= 2 else { continue }
            tags.append(Tag.custom(kind: .unknown(unknown: tag[0]), values: Array(tag.dropFirst())))
        }
        let taggedBuilder = builder.tags(tags: tags)
        try await relay.publish(builder: taggedBuilder)

        FMFLogger.marmot.info("Published key package (kind 443)")
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

        FMFLogger.marmot.info("Published key package relay list (kind 10051)")
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
                FMFLogger.marmot.debug("Published group event (kind 445)")
                return
            } catch {
                attempts += 1
                if attempts >= maxRetries {
                    throw error
                }
                let delay = min(0.5 * pow(2.0, Double(attempts - 1)), 10.0)
                FMFLogger.marmot.warning("Failed to publish group event (attempt \(attempts)) — retrying in \(delay) s: \(error)")
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
                FMFLogger.marmot.info("Commit \(eventId.prefix(8))… not yet on relay (attempt \(attempt)/\(maxAttempts)) — retrying in \(delay)s")
                try await Task.sleep(for: .seconds(delay))
            }
        }
        throw MarmotError.commitVerificationFailed
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

        FMFLogger.marmot.info("Sent message (kind \(kind)) to group \(groupId)")
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
        let startTime = Date()
        let globalTimeout: TimeInterval = 60.0

        // 1. Fetch the member's key package.
        //    Retry with exponential backoff — the invitee's key package may not have
        //    propagated to the relay yet (especially via NearbyShare where
        //    the key package publish is deferred until after MPC tears down).
        var kpEvents: [Event] = []
        for attempt in 1...maxRetries {
            if Date().timeIntervalSince(startTime) > globalTimeout {
                throw MarmotError.timeout
            }
            kpEvents = try await fetchKeyPackage(for: memberHex)
            if !kpEvents.isEmpty { break }
            if attempt < maxRetries {
                let delay = min(0.5 * pow(2.0, Double(attempt - 1)), 30.0)
                FMFLogger.marmot.info("Key package not found for \(memberHex) (attempt \(attempt)/\(maxRetries)) — retrying in \(delay) s")
                try await Task.sleep(for: .seconds(delay))
            }
        }
        guard let kpEvent = kpEvents.first else {
            throw MarmotError.noKeyPackageFound(memberHex)
        }
        let kpJson = try kpEvent.asJson()

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
                FMFLogger.marmot.warning("Failed to publish group events (attempt \(publishAttempts)) — retrying in \(delay) s: \(error)")
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
        FMFLogger.marmot.info("Added member \(memberHex) to group \(groupId)")
    }

    /// Gift-wrap each welcome rumor and send to the receiver via NIP-59.
    func giftWrapAndPublishWelcomes(welcomeRumors: [String], receiverHex: String) async throws {
        let receiverPK = try PublicKey.parse(publicKey: receiverHex)

        for rumorJson in welcomeRumors {
            let rumor = try UnsignedEvent.fromJson(json: rumorJson)
            try await relay.giftWrap(receiver: receiverPK, rumor: rumor, extraTags: [])
        }

        FMFLogger.marmot.debug("Gift-wrapped \(welcomeRumors.count) welcome(s) for \(receiverHex)")
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
            FMFLogger.marmot.debug("Group created with \(payload.welcomeRumors.count) welcome(s) to send")
        }

        await refreshGroups()
        FMFLogger.marmot.info("Created group '\(name)' id=\(groupId)")
        return groupId
    }

    /// Send a leave-request message (kind 2) to the group so the admin can
    /// process the removal and trigger MLS key rotation.
    func sendLeaveRequest(groupId: String) async throws {
        try await sendMessage(content: "", toGroup: groupId, kind: MarmotKind.leaveRequest)
        FMFLogger.marmot.info("Sent leave request for group \(groupId)")
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

        let payload = result.publishPayload(relayURLs: relay.connectedRelayURLs)
        for eventJson in payload.events {
            try await publishGroupEvent(eventJson: eventJson)
        }

        await refreshGroups()
        FMFLogger.marmot.info("Renamed group \(groupId) to '\(newName)'")
    }

    // MARK: - Incoming Event Handling

    /// Process an incoming event from a relay subscription.
    func handleIncomingEvent(_ event: Event) async {
        let eventId = event.id().toHex()

        // Skip already-processed events — prevents expensive MLS re-work
        // during fetchMissedGiftWraps polling (which has no `since` filter).
        guard !(settings?.processedEventIds.contains(eventId) ?? false) else { return }

        let kind = event.kind().asU16()

        do {
            switch kind {
            case MarmotKind.giftWrap:
                try await handleGiftWrap(event)

            case MarmotKind.groupEvent:
                try await handleGroupEvent(event)

            case MarmotKind.keyPackage:
                // Key package rotation — log for now, fetch on demand.
                FMFLogger.marmot.debug("Received key package update (kind 443)")

            default:
                FMFLogger.marmot.debug("Ignoring event kind \(kind)")
            }

            // If this gift-wrap was previously failed, clear it on success.
            if kind == MarmotKind.giftWrap {
                settings?.pendingGiftWrapEventIds.remove(eventId)
            }

            // Mark as processed so fetchMissedGiftWraps polling skips it.
            settings?.processedEventIds.insert(eventId)

            // Update the high-water mark so the next subscription reconnect
            // uses a `since` filter and only fetches newer events.
            let eventTs = event.createdAt().asSecs()
            if let settings, eventTs > settings.lastEventTimestamp {
                settings.lastEventTimestamp = eventTs
            }
        } catch let error as MLSService.MLSError {
            // MLS errors (not initialised, epoch mismatch) are expected for
            // events from groups we don't belong to — log at warning so
            // Welcome-processing failures are visible in standard logs.
            //
            // Mark non-gift-wrap events as processed so we don't retry them.
            // Gift-wraps (Welcomes) should be retryable — a transient MLS
            // error shouldn't permanently prevent joining a group.
            if kind == MarmotKind.giftWrap,
               error.localizedDescription.contains("No matching key package") {
                settings?.pendingGiftWrapEventIds.insert(eventId)
                FMFLogger.marmot.info("Queued gift-wrap \(eventId) for retry after key package refresh")
            }

            if kind != MarmotKind.giftWrap {
                settings?.processedEventIds.insert(eventId)
            }
            FMFLogger.marmot.warning("MLS error processing event kind \(kind): \(error.localizedDescription)")
        } catch {
            // MDK errors like "group not found" are expected for events from
            // groups we don't belong to (kind-445 filter is relay-wide).
            if kind == MarmotKind.giftWrap,
               String(describing: error).contains("No matching key package") {
                settings?.pendingGiftWrapEventIds.insert(eventId)
                FMFLogger.marmot.info("Queued gift-wrap \(eventId) for retry after key package refresh")
            }

            if kind != MarmotKind.giftWrap {
                settings?.processedEventIds.insert(eventId)
            }
            let msg = String(describing: error)
            if msg.contains("group not found") || msg.contains("not found") {
                FMFLogger.marmot.debug("MDK skipped event kind \(kind): \(msg)")
            } else {
                lastError = error.localizedDescription
                FMFLogger.marmot.error("Error handling event kind \(kind): \(error)")
            }
        }
    }

    /// Unwrap a NIP-59 gift-wrap and process the inner welcome (kind 444).
    private func handleGiftWrap(_ event: Event) async throws {
        let gift = try await relay.unwrapGiftWrap(event: event)
        let rumor = gift.rumor()
        let rumorKind = rumor.kind().asU16()

        guard rumorKind == MarmotKind.welcome else {
            FMFLogger.marmot.debug("Gift-wrap contained non-welcome kind \(rumorKind), ignoring")
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
            FMFLogger.marmot.info("Queued unsolicited welcome for group \(welcome.mlsGroupId) from \(senderHex.prefix(8)) — awaiting user approval")
        }
    }

    /// Accept a processed Welcome and complete the join flow.
    func acceptWelcomeAndJoin(_ welcome: Welcome) async throws {
        do {
            try await mls.acceptWelcome(welcome)
        } catch {
            // If already accepted, check if group exists
            if (try? await mls.getGroup(mlsGroupId: welcome.mlsGroupId)) != nil {
                FMFLogger.marmot.info("Welcome already accepted for group \(welcome.mlsGroupId)")
            } else {
                throw error
            }
        }
        await refreshGroups()

        // Post-join self-update: immediately rotate key material so we
        // are not relying on the Welcome's initial key package (MIP-02).
        do {
            let updateResult = try await mls.selfUpdate(groupId: welcome.mlsGroupId)
            try await mls.mergePendingCommit(groupId: welcome.mlsGroupId)
            let updatePayload = updateResult.publishPayload(relayURLs: relay.connectedRelayURLs)
            for eventJson in updatePayload.events {
                try await publishGroupEvent(eventJson: eventJson)
            }
            FMFLogger.marmot.info("Post-join self-update completed for group \(welcome.mlsGroupId)")
        } catch {
            // Non-fatal: the join succeeded. rotateStaleGroups() will retry later.
            FMFLogger.marmot.warning("Post-join self-update failed: \(error)")
        }

        // Clear matching pending invite now that we've joined
        pendingInviteStore?.remove(groupHint: welcome.mlsGroupId)

        // If we had requested leave earlier, clear it now that we're rejoined.
        pendingLeaveStore?.remove(welcome.mlsGroupId)

        // Signal to AppViewModel so it can broadcast our display name
        lastJoinedGroupId = welcome.mlsGroupId

        FMFLogger.marmot.info("Accepted welcome for group \(welcome.mlsGroupId)")
    }

    /// Accept a pending welcome that the user approved from the UI.
    func approvePendingWelcome(mlsGroupId: String) async throws {
        let welcomes = try await mls.getPendingWelcomes()
        guard let welcome = welcomes.first(where: { $0.mlsGroupId == mlsGroupId }) else {
            FMFLogger.marmot.warning("No pending MLS welcome found for group \(mlsGroupId)")
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
        FMFLogger.marmot.info("Declined welcome for group \(mlsGroupId)")
    }

    /// Process an incoming kind-445 group event through MLS.
    private func handleGroupEvent(_ event: Event) async throws {
        let eventJson = try event.asJson()
        let result = try await mls.processIncomingEvent(eventJson: eventJson)

        switch result {
        case .applicationMessage(let message):
            FMFLogger.marmot.debug("Received application message in group \(message.mlsGroupId)")
            healthTracker.recordSuccess(groupId: message.mlsGroupId)
            routeApplicationMessage(message)

        case .commit(let groupId):
            let epoch = (try? await mls.getGroup(mlsGroupId: groupId))?.epoch ?? 0
            FMFLogger.mls.info("Epoch advanced: group \(groupId) now at epoch \(epoch)")
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
            FMFLogger.marmot.debug("Processed and published auto-committed proposal")
            // Refresh groups to reflect any membership or metadata changes
            await refreshGroups()
            // Notify subscribers that membership/metadata may have changed
            lastGroupMembershipChangeId = (updateResult.mlsGroupId, Date())

        case .pendingProposal(let groupId):
            FMFLogger.marmot.debug("Stored pending proposal for group \(groupId)")
            // Refresh groups to reflect any membership changes
            await refreshGroups()
            // Notify subscribers that membership may have changed
            lastGroupMembershipChangeId = (groupId, Date())

        case .externalJoinProposal(let groupId):
            FMFLogger.marmot.debug("External join proposal for group \(groupId)")

        case .unprocessable(let groupId):
            self.healthTracker.recordFailure(groupId: groupId)
            let failCount = self.healthTracker.failureCount(for: groupId)
            FMFLogger.mls.warning("Unprocessable event for group \(groupId) — old epoch key likely deleted (forward secrecy). Failures: \(failCount)")

        case .ignoredProposal(let groupId, let reason):
            FMFLogger.marmot.debug("Ignored proposal for \(groupId): \(reason)")

        case .previouslyFailed:
            FMFLogger.marmot.debug("Skipping previously failed message")
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
                FMFLogger.marmot.warning("Location message missing content in group \(message.mlsGroupId)")
                return
            }
            do {
                let payload = try LocationPayload.from(jsonString: content)
                locationCache?.update(
                    groupId: message.mlsGroupId,
                    memberPubkeyHex: message.senderPubkey,
                    payload: payload
                )
                FMFLogger.marmot.info("Updated location for \(message.senderPubkey.prefix(8)) in group \(message.mlsGroupId)")
            } catch {
                FMFLogger.marmot.error("Failed to decode location payload: \(error)")
            }

        case MarmotKind.chat:
            guard let content = message.plaintextContent else {
                FMFLogger.chat.warning("Chat message missing content in group \(message.mlsGroupId)")
                return
            }
            // Determine sub-type from JSON "type" field
            if let data = content.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type = json["type"] as? String {
                switch type {
                case "chat":
                    lastChatMessageGroupId = message.mlsGroupId
                    FMFLogger.chat.debug("Chat message in group \(message.mlsGroupId) from \(message.senderPubkey.prefix(8))")
                case "nickname":
                    if let payload = try? NicknamePayload.from(jsonString: content) {
                        nicknameStore?.set(name: payload.name, for: message.senderPubkey)
                        FMFLogger.chat.info("Nickname update: \(message.senderPubkey.prefix(8)) → \(payload.name)")
                    }
                default:
                    FMFLogger.chat.debug("Unknown chat sub-type '\(type)' in group \(message.mlsGroupId)")
                }
            } else {
                // Fallback: treat as plain chat text
                lastChatMessageGroupId = message.mlsGroupId
                FMFLogger.chat.debug("Plain chat message in group \(message.mlsGroupId)")
            }

        case MarmotKind.leaveRequest:
            // A member is requesting to leave. Surface to the admin so they
            // can process the removal (which triggers key rotation).
            settings?.pendingLeaveRequests[message.mlsGroupId, default: Set()].insert(message.senderPubkey)
            onLeaveRequestReceived?(message.mlsGroupId, message.senderPubkey)
            FMFLogger.marmot.info("Leave request from \(message.senderPubkey.prefix(8)) in group \(message.mlsGroupId)")

        default:
            FMFLogger.marmot.debug("Unknown application message kind \(message.kind) in group \(message.mlsGroupId)")
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
            FMFLogger.mls.error("Failed to query stale groups: \(error)")
            return
        }

        guard !staleGroupIds.isEmpty else {
            FMFLogger.mls.debug("No groups need key rotation (threshold=\(thresholdSecs)s)")
            return
        }

        FMFLogger.mls.info("Key rotation: \(staleGroupIds.count) group(s) need self-update")

        for groupId in staleGroupIds {
            do {
                // Snapshot epoch before rotation for audit logging
                let oldEpoch = try await mls.getGroup(mlsGroupId: groupId)?.epoch ?? 0

                let result = try await mls.selfUpdate(groupId: groupId)
                try await mls.mergePendingCommit(groupId: groupId)

                let newEpoch = try await mls.getGroup(mlsGroupId: groupId)?.epoch ?? 0
                FMFLogger.mls.info("Key rotation: group \(groupId) epoch \(oldEpoch) → \(newEpoch)")

                // Publish the evolution event so other members advance their epoch
                let payload = result.publishPayload(relayURLs: relay.connectedRelayURLs)
                for eventJson in payload.events {
                    try await publishGroupEvent(eventJson: eventJson)
                }

                FMFLogger.mls.info("Key rotation: published evolution event for group \(groupId)")
            } catch {
                // Per-group error handling — don't let one failure block others
                FMFLogger.mls.error("Key rotation failed for group \(groupId): \(error)")
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
                    FMFLogger.marmot.error("Notification loop exited: \(error)")
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
            FMFLogger.marmot.info("Applying since=\(ts) to group subscription (gift-wrap: no since)")
        }

        groupEventSubId = try await relay.subscribe(filter: groupFilter)
        giftWrapSubId = try await relay.subscribe(filter: giftFilter)

        FMFLogger.marmot.info("Subscriptions started (group=\(self.groupEventSubId ?? "?"), gift=\(self.giftWrapSubId ?? "?"))")

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
        FMFLogger.marmot.info("Reconnecting to relays…")
        if let settings {
            let enabled = settings.relays.filter(\.isEnabled)
            await relay.connect(keys: keys, relays: enabled)
        }
    }

    /// Force a full relay disconnect + reconnect regardless of current state.
    /// Call after MPC / NearbyShare — the WebSocket may appear connected but
    /// be in a degraded state where it silently drops incoming events.
    func forceReconnectRelays() async {
        FMFLogger.marmot.info("Force-reconnecting relays (post-MPC)")
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
        FMFLogger.marmot.info("Subscriptions stopped")
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
            FMFLogger.marmot.info("fetchMissedGiftWraps: \(events.count) event(s)")

            for event in events {
                await handleIncomingEvent(event)
            }

            if let pendingIds = settings?.pendingGiftWrapEventIds, !pendingIds.isEmpty {
                let pendingEventIds: [EventId] = pendingIds.compactMap { pendingId in
                    do {
                        return try EventId.parse(id: pendingId)
                    } catch {
                        FMFLogger.marmot.warning("fetchMissedGiftWraps: invalid pending event id '\(pendingId)', removing")
                        settings?.pendingGiftWrapEventIds.remove(pendingId)
                        return nil
                    }
                }

                if !pendingEventIds.isEmpty {
                    // Snapshot the IDs before retry so we can detect which ones still fail.
                    let idsBeforeRetry = pendingIds

                    let pendingFilter = Filter().ids(ids: pendingEventIds)
                    let pendingEvents = try await relay.fetchEvents(filter: pendingFilter, timeout: 10)
                    FMFLogger.marmot.info("fetchMissedGiftWraps: retrying pending gift-wraps (\(pendingEvents.count))")
                    for event in pendingEvents {
                        await handleIncomingEvent(event)
                    }

                    // Any IDs that are still pending after retry are permanently
                    // unrecoverable (key package gone from a previous DB). Mark
                    // them as processed so we stop refetching every launch.
                    let stillPending = settings?.pendingGiftWrapEventIds.intersection(idsBeforeRetry) ?? []
                    if !stillPending.isEmpty {
                        FMFLogger.marmot.info("fetchMissedGiftWraps: expiring \(stillPending.count) unrecoverable gift-wrap(s)")
                        for id in stillPending {
                            settings?.pendingGiftWrapEventIds.remove(id)
                            settings?.processedEventIds.insert(id)
                        }
                    }
                }
            }
        } catch {
            FMFLogger.marmot.error("fetchMissedGiftWraps failed: \(error)")
        }
    }

    // MARK: - Invite Flow

    /// Generate a shareable invite code for a group.
    func generateInviteCode(for groupId: String, relay relayURL: String) throws -> String {
        let npub = try keys.publicKey().toBech32()
        let invite = InviteCode(relay: relayURL, inviterNpub: npub, groupId: groupId)
        return invite.encode()
    }

    /// Accept an invite: decode, connect if needed, and publish a key package
    /// so the inviter can add us to the group.
    func acceptInvite(_ encoded: String) async throws {
        let invite = try InviteCode.decode(from: encoded)

        // Publish our key package to ALL connected relays (not just the invite
        // relay) so the admin can find it regardless of which relay they query.
        var allRelays = relay.connectedRelayURLs
        if !allRelays.contains(invite.relay) {
            allRelays.append(invite.relay)
        }
        try await publishKeyPackage(relays: allRelays)

        FMFLogger.marmot.info("Accepted invite for group \(invite.groupId) from \(invite.inviterNpub) — key package published to \(allRelays.count) relay(s)")
    }

    // MARK: - Helpers

    /// Refresh the local groups list from MLS.
    func refreshGroups() async {
        do {
            let loaded = try await mls.getGroups()
            groups = loaded
            FMFLogger.marmot.info("refreshGroups: \(loaded.count) group(s) loaded from MDK — active: \(loaded.filter(\.isActive).count)")
        } catch {
            FMFLogger.marmot.error("refreshGroups FAILED: \(error)")
        }
    }

    // MARK: - Errors

    enum MarmotError: LocalizedError {
        case noKeyPackageFound(String)
        case timeout
        case commitVerificationFailed

        var errorDescription: String? {
            switch self {
            case .noKeyPackageFound(let hex):
                return "No key package found for \(hex)"
            case .timeout:
                return "Operation timed out"
            case .commitVerificationFailed:
                return "Could not verify commit on relay — Welcome not sent to avoid state fork"
            }
        }
    }
}
