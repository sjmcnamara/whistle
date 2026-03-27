package org.findmyfam.services

import build.marmot.mdk.Group
import build.marmot.mdk.Message
import build.marmot.mdk.ProcessMessageResult
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import org.findmyfam.models.*
import org.findmyfam.shared.MarmotKind
import org.findmyfam.shared.models.ChatPayload
import org.findmyfam.shared.models.InviteCode
import org.findmyfam.shared.models.LocationPayload
import org.findmyfam.shared.models.NicknamePayload
import org.json.JSONObject
import rust.nostr.sdk.Event
import rust.nostr.sdk.EventBuilder
import rust.nostr.sdk.Filter
import rust.nostr.sdk.HandleNotification
import rust.nostr.sdk.Kind
import rust.nostr.sdk.PublicKey
import rust.nostr.sdk.RelayMessage
import rust.nostr.sdk.RelayUrl
import rust.nostr.sdk.Tag
import rust.nostr.sdk.TagKind
import rust.nostr.sdk.Timestamp
import rust.nostr.sdk.UnsignedEvent
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.min
import kotlin.math.pow

/**
 * Orchestration layer connecting MLSService (MLS state machine) with
 * RelayService (Nostr relay I/O) via the Marmot event kinds.
 *
 * MarmotService is the single entry point for all Marmot protocol operations:
 * - Kind 443 -- Key Package publishing & fetching
 * - Kind 10051 -- Key Package Relay List
 * - Kind 444 -- Welcome (NIP-59 gift-wrapped)
 * - Kind 445 -- Group events (commits, proposals, application messages)
 */
@Singleton
class MarmotService @Inject constructor(
    private val relay: RelayService,
    private val mls: MLSService,
    private val identity: IdentityService,
    private val settings: AppSettings,
    private val nicknameStore: NicknameStore,
    private val pendingInviteStore: PendingInviteStore,
    private val pendingLeaveStore: PendingLeaveStore,
    private val locationCache: LocationCache,
    val healthTracker: GroupHealthTracker
) {
    // --- Published State ---

    private val _groups = MutableStateFlow<List<Group>>(emptyList())
    val groups: StateFlow<List<Group>> = _groups.asStateFlow()

    private val _lastChatMessageGroupId = MutableStateFlow<String?>(null)
    val lastChatMessageGroupId: StateFlow<String?> = _lastChatMessageGroupId.asStateFlow()

    private val _lastJoinedGroupId = MutableStateFlow<String?>(null)
    val lastJoinedGroupId: StateFlow<String?> = _lastJoinedGroupId.asStateFlow()

    private val _lastGroupMembershipChangeId = MutableStateFlow<Pair<String, Long>?>(null)
    val lastGroupMembershipChangeId: StateFlow<Pair<String, Long>?> = _lastGroupMembershipChangeId.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    /** One-shot error events for Snackbar display. */
    private val _errorEvents = MutableSharedFlow<String>(extraBufferCapacity = 1)
    val errorEvents: SharedFlow<String> = _errorEvents.asSharedFlow()

    // --- Internal ---

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var subscriptionJob: Job? = null
    private var groupEventSubId: String? = null
    private var giftWrapSubId: String? = null

    private val publicKeyHex: String
        get() = identity.publicKeyHex ?: ""

    /** Connected relay URLs -- used for invite generation. */
    val activeRelayUrls: List<String>
        get() = relay.connectedRelayUrls.value

    // --- Kind 443: Key Packages ---

    /**
     * Create and publish a new MLS key package as a kind-443 event.
     */
    suspend fun publishKeyPackage(relays: List<String>) {
        val kp = mls.createKeyPackageForEvent(publicKeyHex, relays)

        val builder = EventBuilder(kind = Kind(kind = MarmotKind.KEY_PACKAGE), content = kp.keyPackage)
        val tags = mutableListOf<Tag>()
        for (tag in kp.tags) {
            if (tag.size >= 2) {
                tags.add(Tag.custom(kind = TagKind.Unknown(tag[0]), values = tag.drop(1)))
            }
        }
        val taggedBuilder = builder.tags(tags = tags)
        relay.publish(taggedBuilder)
        Timber.i("Published key package (kind 443)")
    }

    /**
     * Fetch the latest key package for a given public key.
     */
    suspend fun fetchKeyPackage(pubkeyHex: String): List<Event> {
        val pk = PublicKey.parse(publicKey = pubkeyHex)
        val filter = Filter()
            .kind(kind = Kind(kind = MarmotKind.KEY_PACKAGE))
            .authors(authors = listOf(pk))
            .limit(limit = 1uL)
        return relay.fetchEvents(filter = filter, timeout = java.time.Duration.ofSeconds(10))
    }

    // --- Kind 445: Group Events ---

    /**
     * Publish a pre-built group event (kind 445) JSON string from MLS.
     */
    suspend fun publishGroupEvent(eventJson: String) {
        val event = Event.fromJson(json = eventJson)
        var attempts = 0
        val maxRetries = 3
        while (attempts < maxRetries) {
            try {
                relay.sendEvent(event = event)
                Timber.d("Published group event (kind 445)")
                return
            } catch (e: Exception) {
                attempts++
                if (attempts >= maxRetries) throw e
                val delay = min(0.5 * 2.0.pow((attempts - 1).toDouble()), 10.0)
                Timber.w("Failed to publish group event (attempt $attempts) -- retrying in $delay s: ${e.message}")
                delay((delay * 1000).toLong())
            }
        }
    }

    /**
     * Encrypt and send a message to a group.
     */
    suspend fun sendMessage(content: String, groupId: String, kind: UShort = MarmotKind.CHAT) {
        val eventJson = mls.createMessage(
            mlsGroupId = groupId,
            senderPublicKey = publicKeyHex,
            content = content,
            kind = kind,
            tags = null
        )
        publishGroupEvent(eventJson)
        Timber.i("Sent message (kind $kind) to group $groupId")
    }

    /**
     * Encode a location payload and send as kind-1 application message to a group.
     */
    suspend fun sendLocationUpdate(payload: LocationPayload, groupId: String) {
        val json = payload.toJson()
        sendMessage(content = json, groupId = groupId, kind = MarmotKind.LOCATION)
    }

    /**
     * Broadcast a nickname update to a group.
     */
    suspend fun sendNicknameUpdate(name: String, groupId: String) {
        val payload = NicknamePayload(name = name)
        val json = payload.toJson()
        sendMessage(content = json, groupId = groupId, kind = MarmotKind.CHAT)
    }

    // --- Kind 444: Welcome (NIP-59 gift-wrap) ---

    /**
     * Add a member to a group: fetch their key package, run MLS addMembers,
     * gift-wrap the welcome, and publish group evolution events.
     */
    suspend fun addMember(pubkeyHex: String, groupId: String, maxRetries: Int = 10) {
        val startTime = System.currentTimeMillis()
        val globalTimeout = 60_000L

        // 1. Fetch the member's key package with retry
        var kpEvents: List<Event> = emptyList()
        for (attempt in 1..maxRetries) {
            if (System.currentTimeMillis() - startTime > globalTimeout) {
                throw MarmotException("Operation timed out")
            }
            kpEvents = fetchKeyPackage(pubkeyHex)
            if (kpEvents.isNotEmpty()) break
            if (attempt < maxRetries) {
                val backoff = min(0.5 * 2.0.pow((attempt - 1).toDouble()), 30.0)
                Timber.i("Key package not found for $pubkeyHex (attempt $attempt/$maxRetries) -- retrying in $backoff s")
                delay((backoff * 1000).toLong())
            }
        }
        val kpEvent = kpEvents.firstOrNull()
            ?: throw MarmotException("No key package found for $pubkeyHex")
        val kpJson = kpEvent.asJson()

        // 2. MLS addMembers
        val result = mls.addMembers(mlsGroupId = groupId, keyPackageEventsJson = listOf(kpJson))
        mls.mergePendingCommit(mlsGroupId = groupId)

        // 3. Publish the evolution event (kind 445)
        val evolutionEventJson = result.evolutionEventJson
        publishGroupEvent(evolutionEventJson)

        // 4. Gift-wrap and publish welcome rumors (kind 444 inside kind 1059)
        val welcomeRumors = result.welcomeRumorsJson ?: emptyList()
        giftWrapAndPublishWelcomes(welcomeRumors, pubkeyHex)

        refreshGroups()
        Timber.i("Added member $pubkeyHex to group $groupId")
    }

    /**
     * Gift-wrap each welcome rumor and send to the receiver via NIP-59.
     */
    suspend fun giftWrapAndPublishWelcomes(welcomeRumors: List<String>, receiverHex: String) {
        val receiverPK = PublicKey.parse(publicKey = receiverHex)

        for (rumorJson in welcomeRumors) {
            val rumor = UnsignedEvent.fromJson(json = rumorJson)
            relay.giftWrap(receiver = receiverPK, rumor = rumor, extraTags = emptyList())
        }

        Timber.d("Gift-wrapped ${welcomeRumors.size} welcome(s) for $receiverHex")
    }

    // --- Group Lifecycle ---

    /**
     * Create a new MLS group and publish welcome events for initial members.
     */
    suspend fun createGroup(name: String, description: String = "", relays: List<String>): String {
        val result = mls.createGroup(
            creatorPublicKey = publicKeyHex,
            memberKeyPackageEventsJson = emptyList(),
            name = name,
            description = description,
            relays = relays,
            admins = listOf(publicKeyHex)
        )
        val groupId = result.group.mlsGroupId
        mls.mergePendingCommit(mlsGroupId = groupId)

        // For creation with members, gift-wrap welcomes
        val welcomeRumors = result.welcomeRumorsJson
        if (welcomeRumors.isNotEmpty()) {
            Timber.d("Group created with ${welcomeRumors.size} welcome(s) to send")
        }

        refreshGroups()
        Timber.i("Created group '$name' id=$groupId")
        return groupId
    }

    /**
     * Send a leave-request message (kind 2) to the group so the admin can
     * process the removal and trigger MLS key rotation.
     */
    suspend fun sendLeaveRequest(groupId: String) {
        sendMessage(content = "", groupId = groupId, kind = MarmotKind.LEAVE_REQUEST)
        Timber.i("Sent leave request for group $groupId")
    }

    /**
     * Rename a group: update MLS metadata, merge, publish the evolution event.
     */
    suspend fun renameGroup(groupId: String, newName: String) {
        val result = mls.selfUpdate(mlsGroupId = groupId)
        mls.mergePendingCommit(mlsGroupId = groupId)

        val evolutionEventJson = result.evolutionEventJson
        publishGroupEvent(evolutionEventJson)

        refreshGroups()
        Timber.i("Renamed group $groupId to '$newName'")
    }

    // --- Incoming Event Handling ---

    /**
     * Process an incoming event from a relay subscription.
     */
    suspend fun handleIncomingEvent(event: Event) {
        val eventId = event.id().toHex()

        // Skip already-processed events
        if (settings.isEventProcessed(eventId)) return

        val kind = event.kind().asU16()

        try {
            when (kind) {
                MarmotKind.GIFT_WRAP -> handleGiftWrap(event)
                MarmotKind.GROUP_EVENT -> handleGroupEvent(event)
                MarmotKind.KEY_PACKAGE -> {
                    Timber.d("Received key package update (kind 443)")
                }
                else -> Timber.d("Ignoring event kind $kind")
            }

            // If this gift-wrap was previously failed, clear it on success
            if (kind == MarmotKind.GIFT_WRAP) {
                settings.removePendingGiftWrapEventId(eventId)
            }

            // Mark as processed
            settings.addProcessedEventId(eventId)

            // Update the high-water mark
            val eventTs = event.createdAt().asSecs()
            if (eventTs > settings.lastEventTimestamp) {
                settings.lastEventTimestamp = eventTs
            }
        } catch (e: Exception) {
            val msg = e.message ?: e.toString()

            if (kind == MarmotKind.GIFT_WRAP && msg.contains("No matching key package")) {
                settings.addPendingGiftWrapEventId(eventId)
                Timber.i("Queued gift-wrap $eventId for retry after key package refresh")
            }

            if (kind != MarmotKind.GIFT_WRAP) {
                settings.addProcessedEventId(eventId)
            }

            if (msg.contains("group not found") || msg.contains("not found")) {
                Timber.d("MDK skipped event kind $kind: $msg")
            } else {
                _lastError.value = msg
                Timber.e("Error handling event kind $kind: $e")
            }
        }
    }

    /**
     * Unwrap a NIP-59 gift-wrap and process the inner welcome (kind 444).
     */
    private suspend fun handleGiftWrap(event: Event) {
        val gift = relay.unwrapGiftWrap(event = event)
        val rumor = gift.rumor()
        val rumorKind = rumor.kind().asU16()

        if (rumorKind != MarmotKind.WELCOME) {
            Timber.d("Gift-wrap contained non-welcome kind $rumorKind, ignoring")
            return
        }

        val wrapperEventId = event.id().toHex()
        val rumorJson = rumor.asJson()

        val welcome = mls.processWelcome(
            wrapperEventId = wrapperEventId,
            rumorEventJson = rumorJson
        )

        // Auto-accept the welcome
        try {
            mls.acceptWelcome(welcome)
        } catch (e: Exception) {
            // If already accepted, check if group exists
            mls.getGroup(welcome.mlsGroupId) ?: throw e
            Timber.i("Welcome already accepted for group ${welcome.mlsGroupId}")
        }
        refreshGroups()

        // Clear matching pending invite now that we've joined
        pendingInviteStore.remove(groupHint = welcome.mlsGroupId)

        // If we had requested leave earlier, clear it now that we're rejoined
        pendingLeaveStore.remove(welcome.mlsGroupId)

        // Signal so AppViewModel can broadcast display name
        withContext(Dispatchers.Main) {
            _lastJoinedGroupId.value = welcome.mlsGroupId
        }

        Timber.i("Accepted welcome for group ${welcome.mlsGroupId}")
    }

    /**
     * Process an incoming kind-445 group event through MLS.
     */
    private suspend fun handleGroupEvent(event: Event) {
        val eventJson = event.asJson()
        val result = mls.processMessage(eventJson = eventJson)

        when (result) {
            is ProcessMessageResult.ApplicationMessage -> {
                val message = result.message
                Timber.d("Received application message in group ${message.mlsGroupId}")
                healthTracker.recordSuccess(groupId = message.mlsGroupId)
                routeApplicationMessage(message)
            }
            is ProcessMessageResult.Commit -> {
                val groupId = result.mlsGroupId
                val epoch = mls.getGroup(groupId)?.epoch ?: 0u
                Timber.i("Epoch advanced: group $groupId now at epoch $epoch")
                healthTracker.recordSuccess(groupId = groupId)
                refreshGroups()
                withContext(Dispatchers.Main) {
                    _lastGroupMembershipChangeId.value = groupId to System.currentTimeMillis()
                }
            }
            is ProcessMessageResult.Proposal -> {
                val updateResult = result.result
                val evolutionEventJson = updateResult.evolutionEventJson
                publishGroupEvent(evolutionEventJson)
                Timber.d("Processed and published auto-committed proposal")
                refreshGroups()
                withContext(Dispatchers.Main) {
                    _lastGroupMembershipChangeId.value = updateResult.mlsGroupId to System.currentTimeMillis()
                }
            }
            is ProcessMessageResult.PendingProposal -> {
                Timber.d("Stored pending proposal for group ${result.mlsGroupId}")
                refreshGroups()
                withContext(Dispatchers.Main) {
                    _lastGroupMembershipChangeId.value = result.mlsGroupId to System.currentTimeMillis()
                }
            }
            is ProcessMessageResult.ExternalJoinProposal -> {
                Timber.d("External join proposal for group ${result.mlsGroupId}")
            }
            is ProcessMessageResult.Unprocessable -> {
                healthTracker.recordFailure(groupId = result.mlsGroupId)
                val failCount = healthTracker.failureCount(result.mlsGroupId)
                Timber.w("Unprocessable event for group ${result.mlsGroupId} -- failures: $failCount")
            }
            is ProcessMessageResult.IgnoredProposal -> {
                Timber.d("Ignored proposal for ${result.mlsGroupId}: ${result.reason}")
            }
            is ProcessMessageResult.PreviouslyFailed -> {
                Timber.d("Skipping previously failed message")
            }
        }
    }

    // --- Application Message Routing ---

    /**
     * Route a decrypted application message to the appropriate handler.
     */
    private suspend fun routeApplicationMessage(message: Message) {
        val content = message.plaintextContent ?: run {
            Timber.w("Application message missing content in group ${message.mlsGroupId}")
            return
        }

        when (message.kind) {
            MarmotKind.LOCATION -> {
                try {
                    val payload = LocationPayload.fromJson(content)
                    locationCache.update(
                        groupId = message.mlsGroupId,
                        memberPubkeyHex = message.senderPubkey,
                        payload = payload
                    )
                    Timber.i("Updated location for ${message.senderPubkey.take(8)} in group ${message.mlsGroupId}")
                } catch (e: Exception) {
                    Timber.e("Failed to decode location payload: $e")
                }
            }
            MarmotKind.CHAT -> {
                // Determine sub-type from JSON "type" field
                try {
                    val json = JSONObject(content)
                    when (json.optString("type", "chat")) {
                        "chat" -> {
                            withContext(Dispatchers.Main) {
                                _lastChatMessageGroupId.value = message.mlsGroupId
                            }
                            Timber.d("Chat message in group ${message.mlsGroupId} from ${message.senderPubkey.take(8)}")
                        }
                        "nickname" -> {
                            val payload = NicknamePayload.fromJson(content)
                            nicknameStore.set(name = payload.name, pubkeyHex = message.senderPubkey)
                            Timber.i("Nickname update: ${message.senderPubkey.take(8)} -> ${payload.name}")
                        }
                        else -> {
                            Timber.d("Unknown chat sub-type in group ${message.mlsGroupId}")
                        }
                    }
                } catch (_: Exception) {
                    // Fallback: treat as plain chat text
                    withContext(Dispatchers.Main) {
                        _lastChatMessageGroupId.value = message.mlsGroupId
                    }
                    Timber.d("Plain chat message in group ${message.mlsGroupId}")
                }
            }
            MarmotKind.LEAVE_REQUEST -> {
                settings.addPendingLeaveRequest(message.mlsGroupId, message.senderPubkey)
                Timber.i("Leave request from ${message.senderPubkey.take(8)} in group ${message.mlsGroupId}")
            }
            else -> {
                Timber.d("Unknown application message kind ${message.kind} in group ${message.mlsGroupId}")
            }
        }
    }

    // --- Key Rotation (Forward Secrecy) ---

    /**
     * Check all groups for stale encryption keys and perform MLS self-update
     * on any that exceed the configured rotation interval.
     */
    suspend fun rotateStaleGroups() {
        val thresholdSecs = settings.keyRotationIntervalSecs

        val staleGroupIds: List<String>
        try {
            staleGroupIds = mls.groupsNeedingSelfUpdate(thresholdSecs = thresholdSecs)
        } catch (e: Exception) {
            Timber.e("Failed to query stale groups: $e")
            return
        }

        if (staleGroupIds.isEmpty()) {
            Timber.d("No groups need key rotation (threshold=${thresholdSecs}s)")
            return
        }

        Timber.i("Key rotation: ${staleGroupIds.size} group(s) need self-update")

        for (groupId in staleGroupIds) {
            try {
                val oldEpoch = mls.getGroup(groupId)?.epoch ?: 0u

                val result = mls.selfUpdate(mlsGroupId = groupId)
                mls.mergePendingCommit(mlsGroupId = groupId)

                val newEpoch = mls.getGroup(groupId)?.epoch ?: 0u
                Timber.i("Key rotation: group $groupId epoch $oldEpoch -> $newEpoch")

                val evolutionEventJson = result.evolutionEventJson
                publishGroupEvent(evolutionEventJson)

                Timber.i("Key rotation: published evolution event for group $groupId")
            } catch (e: Exception) {
                Timber.e("Key rotation failed for group $groupId: $e")
            }
        }

        refreshGroups()
    }

    // --- Subscriptions ---

    /**
     * Open subscriptions for group events (kind 445) and gift-wraps (kind 1059).
     */
    fun startSubscriptions() {
        subscriptionJob = scope.launch {
            while (isActive) {
                try {
                    openSubscriptionsAndListen()
                    break // Clean return
                } catch (e: Exception) {
                    if (!isActive) break
                    Timber.e("Notification loop exited: $e")
                    _lastError.value = e.message
                    delay(1000)
                    reconnectRelaysIfNeeded()
                }
            }
        }
    }

    /**
     * Inner subscription setup + notification loop.
     */
    private suspend fun openSubscriptionsAndListen() {
        val myPK = PublicKey.parse(publicKey = publicKeyHex)

        // Build filters
        var groupFilter = Filter()
            .kind(kind = Kind(kind = MarmotKind.GROUP_EVENT))
        val giftFilter = Filter()
            .kind(kind = Kind(kind = MarmotKind.GIFT_WRAP))
            .pubkeys(pubkeys = listOf(myPK))

        val ts = settings.lastEventTimestamp
        if (ts > 0u) {
            val since = Timestamp.fromSecs(secs = ts)
            groupFilter = groupFilter.since(timestamp = since)
            Timber.i("Applying since=$ts to group subscription (gift-wrap: no since)")
        }

        groupEventSubId = relay.subscribe(filter = groupFilter)
        giftWrapSubId = relay.subscribe(filter = giftFilter)

        Timber.i("Subscriptions started (group=$groupEventSubId, gift=$giftWrapSubId)")

        // Register notification handler -- runs until error or disconnect
        relay.handleNotifications(object : HandleNotification {
            override suspend fun handle(relayUrl: RelayUrl, subscriptionId: String, event: Event) {
                handleIncomingEvent(event)
            }

            override suspend fun handleMsg(relayUrl: RelayUrl, message: RelayMessage) {
                // No-op for relay messages
            }
        })
    }

    /**
     * Reconnect to relays if the connection has dropped.
     */
    private suspend fun reconnectRelaysIfNeeded() {
        if (relay.connectionState.value == RelayService.ConnectionState.CONNECTED) return
        Timber.i("Reconnecting to relays...")
        val keys = identity.keys.value ?: return
        val enabled = settings.relays.filter { it.isEnabled }.map { it.url }
        relay.connect(keys = keys, relays = enabled)
    }

    /**
     * Stop subscriptions and cancel the subscription task.
     */
    fun stopSubscriptions() {
        subscriptionJob?.cancel()
        subscriptionJob = null
        groupEventSubId = null
        giftWrapSubId = null
        Timber.i("Subscriptions stopped")
    }

    /**
     * One-shot fetch of gift-wrap events that may have been missed.
     */
    suspend fun fetchMissedGiftWraps() {
        reconnectRelaysIfNeeded()

        try {
            val myPK = PublicKey.parse(publicKey = publicKeyHex)
            val filter = Filter()
                .kind(kind = Kind(kind = MarmotKind.GIFT_WRAP))
                .pubkeys(pubkeys = listOf(myPK))

            val events = relay.fetchEvents(filter = filter, timeout = java.time.Duration.ofSeconds(10))
            Timber.i("fetchMissedGiftWraps: ${events.size} event(s)")

            for (event in events) {
                handleIncomingEvent(event)
            }

            // Retry any pending gift-wraps that previously failed (e.g. "No matching key package")
            val pendingIds = settings.pendingGiftWrapEventIds
            if (pendingIds.isNotEmpty()) {
                val pendingEventIds = pendingIds.mapNotNull { pendingId ->
                    try {
                        rust.nostr.sdk.EventId.parse(pendingId)
                    } catch (e: Exception) {
                        Timber.w("fetchMissedGiftWraps: invalid pending event id '$pendingId', skipping: $e")
                        null
                    }
                }
                if (pendingEventIds.isNotEmpty()) {
                    val pendingFilter = Filter().ids(ids = pendingEventIds)
                    val pendingEvents = relay.fetchEvents(filter = pendingFilter, timeout = java.time.Duration.ofSeconds(10))
                    Timber.i("fetchMissedGiftWraps: retrying pending gift-wraps (${pendingEvents.size})")
                    for (event in pendingEvents) {
                        handleIncomingEvent(event)
                    }
                }
            }
        } catch (e: Exception) {
            Timber.e("fetchMissedGiftWraps failed: $e")
        }
    }

    // --- Invite Flow ---

    /**
     * Generate a shareable invite code for a group.
     */
    fun generateInviteCode(groupId: String, relayUrl: String): String {
        val npub = identity.npub ?: throw MarmotException("No identity available")
        val invite = InviteCode(relay = relayUrl, inviterNpub = npub, groupId = groupId)
        return invite.encode()
    }

    /**
     * Accept an invite: decode, publish a key package so the inviter can add us.
     */
    suspend fun acceptInvite(encoded: String) {
        val invite = InviteCode.decode(encoded)

        // Publish our key package to ALL connected relays (not just the invite
        // relay) so the admin can find it regardless of which relay they query.
        val allRelays = activeRelayUrls.toMutableList()
        if (invite.relay !in allRelays) {
            allRelays.add(invite.relay)
        }
        publishKeyPackage(relays = allRelays)

        Timber.i("Accepted invite for group ${invite.groupId} from ${invite.inviterNpub} — key package published to ${allRelays.size} relay(s)")
    }

    // --- Helpers ---

    /**
     * Refresh the local groups list from MLS.
     */
    suspend fun refreshGroups() {
        try {
            val loaded = mls.getGroups()
            withContext(Dispatchers.Main) {
                _groups.value = loaded
            }
            val activeCount = loaded.count { it.state == "active" }
            Timber.i("refreshGroups: ${loaded.size} group(s) loaded from MDK -- active: $activeCount")
        } catch (e: Exception) {
            Timber.e("refreshGroups FAILED: $e")
        }
    }

    // --- Errors ---

    class MarmotException(message: String) : Exception(message)
}

// --- Message convenience extensions ---

/**
 * Extracts the plaintext content field from the inner decrypted event JSON.
 */
val Message.plaintextContent: String?
    get() {
        return try {
            val json = JSONObject(eventJson)
            if (json.has("content")) json.getString("content") else null
        } catch (_: Exception) { null }
    }

/**
 * Inner event kind.
 */
val Message.innerKind: Int?
    get() {
        return try {
            val json = JSONObject(eventJson)
            if (json.has("kind")) json.getInt("kind") else null
        } catch (_: Exception) { null }
    }

// --- Group convenience extensions ---

val Group.isActive: Boolean
    get() = state == "active"
