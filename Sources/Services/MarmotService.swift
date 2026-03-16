import Foundation
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

    // MARK: - Published state

    /// Active MLS groups, refreshed after mutations.
    @Published private(set) var groups: [Group] = []

    /// Last error for UI display (non-fatal).
    @Published private(set) var lastError: String?

    /// Bumped when a chat message is received — ChatViewModel observes this.
    @Published private(set) var lastChatMessageGroupId: String?

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
        try await relay.sendEvent(event)

        FMFLogger.marmot.debug("Published group event (kind 445)")
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
    func addMember(publicKeyHex memberHex: String, toGroup groupId: String) async throws {
        // 1. Fetch the member's key package
        let kpEvents = try await fetchKeyPackage(for: memberHex)
        guard let kpEvent = kpEvents.first else {
            throw MarmotError.noKeyPackageFound(memberHex)
        }
        let kpJson = try kpEvent.asJson()

        // 2. MLS addMembers
        let result = try await mls.addMembers(groupId: groupId, keyPackageEventsJson: [kpJson])
        try await mls.mergePendingCommit(groupId: groupId)

        // 3. Publish the evolution event (kind 445)
        let payload = result.publishPayload(relayURLs: relay.connectedRelayURLs)
        for eventJson in payload.events {
            try await publishGroupEvent(eventJson: eventJson)
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

    // MARK: - Incoming Event Handling

    /// Process an incoming event from a relay subscription.
    func handleIncomingEvent(_ event: Event) async {
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
        } catch {
            lastError = error.localizedDescription
            FMFLogger.marmot.error("Error handling event kind \(kind): \(error)")
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

        // Auto-accept the welcome
        try await mls.acceptWelcome(welcome)
        await refreshGroups()

        FMFLogger.marmot.info("Accepted welcome for group \(welcome.mlsGroupId)")
    }

    /// Process an incoming kind-445 group event through MLS.
    private func handleGroupEvent(_ event: Event) async throws {
        let eventJson = try event.asJson()
        let result = try await mls.processIncomingEvent(eventJson: eventJson)

        switch result {
        case .applicationMessage(let message):
            FMFLogger.marmot.debug("Received application message in group \(message.mlsGroupId)")
            routeApplicationMessage(message)

        case .commit(let groupId):
            FMFLogger.marmot.debug("Processed commit — epoch advanced for \(groupId)")

        case .proposal(let updateResult):
            // Auto-committed proposal — publish the evolution event
            let payload = updateResult.publishPayload(relayURLs: relay.connectedRelayURLs)
            for json in payload.events {
                try await publishGroupEvent(eventJson: json)
            }
            FMFLogger.marmot.debug("Processed and published auto-committed proposal")

        case .pendingProposal(let groupId):
            FMFLogger.marmot.debug("Stored pending proposal for group \(groupId)")

        case .externalJoinProposal(let groupId):
            FMFLogger.marmot.debug("External join proposal for group \(groupId)")

        case .unprocessable(let groupId):
            FMFLogger.marmot.warning("Unprocessable group event for \(groupId) — epoch mismatch?")

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

        default:
            FMFLogger.marmot.debug("Unknown application message kind \(message.kind) in group \(message.mlsGroupId)")
        }
    }

    // MARK: - Subscriptions

    /// Open subscriptions for group events (kind 445) and gift-wraps (kind 1059).
    func startSubscriptions() async {
        do {
            let myPK = try PublicKey.parse(publicKey: publicKeyHex)

            // Subscribe to kind-445 group events for all our active groups
            let groupFilter = Filter()
                .kind(kind: Kind(kind: MarmotKind.groupEvent))
            groupEventSubId = try await relay.subscribe(filter: groupFilter)

            // Subscribe to kind-1059 gift-wraps addressed to us
            let giftFilter = Filter()
                .kind(kind: Kind(kind: MarmotKind.giftWrap))
                .pubkeys(pubkeys: [myPK])
            giftWrapSubId = try await relay.subscribe(filter: giftFilter)

            // Register notification handler
            let handler = NotificationHandler { [weak self] subId, event in
                Task { @MainActor [weak self] in
                    await self?.handleIncomingEvent(event)
                }
            }
            try await relay.handleNotifications(handler: handler)

            FMFLogger.marmot.info("Subscriptions started (group=\(self.groupEventSubId ?? "?"), gift=\(self.giftWrapSubId ?? "?"))")
        } catch {
            lastError = error.localizedDescription
            FMFLogger.marmot.error("Failed to start subscriptions: \(error)")
        }
    }

    /// Stop subscriptions (currently a no-op — subscriptions end with disconnect).
    func stopSubscriptions() {
        groupEventSubId = nil
        giftWrapSubId = nil
        FMFLogger.marmot.info("Subscriptions stopped")
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

        // Publish our key package so the inviter can add us
        try await publishKeyPackage(relays: [invite.relay])

        FMFLogger.marmot.info("Accepted invite for group \(invite.groupId) from \(invite.inviterNpub)")
    }

    // MARK: - Helpers

    /// Refresh the local groups list from MLS.
    func refreshGroups() async {
        do {
            groups = try await mls.getGroups()
        } catch {
            FMFLogger.marmot.error("Failed to refresh groups: \(error)")
        }
    }

    // MARK: - Errors

    enum MarmotError: LocalizedError {
        case noKeyPackageFound(String)

        var errorDescription: String? {
            switch self {
            case .noKeyPackageFound(let hex):
                return "No key package found for \(hex)"
            }
        }
    }
}
