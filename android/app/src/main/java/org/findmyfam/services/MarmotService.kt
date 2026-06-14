package org.findmyfam.services

import build.marmot.mdk.Group
import build.marmot.mdk.GroupDataUpdate
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
import org.findmyfam.shared.models.JoinRequest
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
 * - Kind 30443 -- Key Package publishing & fetching
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
    private val pendingWelcomeStore: PendingWelcomeStore,
    val joinRequestStore: JoinRequestStore,
    private val locationCache: LocationCache,
    val healthTracker: GroupHealthTracker,
    private val batteryAlertService: BatteryAlertService
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

    // --- Kind 30443: Key Packages ---

    /**
     * Create and publish a new MLS key package as a kind-30443 event.
     */
    suspend fun publishKeyPackage(relays: List<String>): String {
        val kp = mls.createKeyPackageForEvent(publicKeyHex, relays)

        val builder = EventBuilder(kind = Kind(kind = MarmotKind.KEY_PACKAGE), content = kp.keyPackage)
        val tags = mutableListOf<Tag>()
        for (tag in kp.tags) {
            if (tag.size >= 2) {
                tags.add(Tag.custom(kind = TagKind.Unknown(tag[0]), values = tag.drop(1)))
            }
        }
        // Sign locally so we can both publish AND embed the signed event inline
        // in a join-request (no separate relay fetch for the admin).
        val keys = identity.keys.value ?: throw IllegalStateException("No identity — cannot publish key package")
        val signed = builder.tags(tags = tags).signWithKeys(keys = keys)
        relay.sendEvent(signed)
        Timber.i("Published key package (kind 30443)")
        return signed.asJson()
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
     * Verify that an event is retrievable from the relay after publishing.
     * Retries with short backoff to allow relay indexing.
     * Required by MIP-02: Commit must be queryable before Welcome is sent.
     */
    private suspend fun verifyEventOnRelay(eventId: String, maxAttempts: Int = 3) {
        val parsedId = rust.nostr.sdk.EventId.parse(eventId)
        val filter = Filter().ids(ids = listOf(parsedId))

        for (attempt in 1..maxAttempts) {
            val events = relay.fetchEvents(filter = filter, timeout = java.time.Duration.ofSeconds(5))
            if (events.isNotEmpty()) return
            if (attempt < maxAttempts) {
                val backoff = (0.5 * 2.0.pow((attempt - 1).toDouble()) * 1000).toLong()
                Timber.i("Commit ${eventId.take(8)}… not yet on relay (attempt $attempt/$maxAttempts) — retrying")
                delay(backoff)
            }
        }
        throw MarmotException("Could not verify commit on relay — Welcome not sent to avoid state fork")
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
        // Pre-flight: don't add yourself
        if (pubkeyHex == publicKeyHex) {
            throw MarmotException("Cannot add yourself to a group")
        }

        // Pre-flight: check if member is already in the group
        try {
            val existingMembers = mls.getMembers(groupId)
            if (pubkeyHex in existingMembers) {
                throw MarmotException("Member is already in this group")
            }
        } catch (e: MarmotException) {
            throw e // re-throw our own exceptions
        } catch (e: Exception) {
            Timber.w("Could not check existing members (non-fatal): ${e.message}")
        }

        // Pre-flight: verify relay connectivity
        if (relay.connectedRelayUrls.value.isEmpty()) {
            throw MarmotException("Not connected to any relay — check your connection")
        }

        val startTime = System.currentTimeMillis()
        val globalTimeout = 60_000L

        // 1. Fetch the member's key package with retry.
        //    The invitee's key package may not have propagated yet (especially
        //    after scanning an invite code where the publish is deferred).
        Timber.i("Fetching key package for ${pubkeyHex.take(8)}… from ${relay.connectedRelayUrls.value.size} relay(s)")
        var kpEvents: List<Event> = emptyList()
        for (attempt in 1..maxRetries) {
            if (System.currentTimeMillis() - startTime > globalTimeout) {
                throw MarmotException("Operation timed out — could not find key package for this member. Ask them to re-open the app and try again.")
            }
            try {
                kpEvents = fetchKeyPackage(pubkeyHex)
            } catch (e: Exception) {
                Timber.w("fetchKeyPackage attempt $attempt failed: ${e.message}")
                // Continue retrying — relay may be temporarily unavailable
            }
            if (kpEvents.isNotEmpty()) {
                Timber.i("Found key package for ${pubkeyHex.take(8)}… on attempt $attempt")
                break
            }
            if (attempt < maxRetries) {
                val backoff = min(0.5 * 2.0.pow((attempt - 1).toDouble()), 30.0)
                Timber.i("Key package not found for ${pubkeyHex.take(8)}… (attempt $attempt/$maxRetries) -- retrying in $backoff s")
                delay((backoff * 1000).toLong())
            }
        }
        val kpEvent = kpEvents.firstOrNull()
            ?: throw MarmotException("No key package found for this member. Make sure they have the app open and are connected to the same relay.")
        val kpJson = kpEvent.asJson()

        // 2. MLS addMembers
        val result = mls.addMembers(mlsGroupId = groupId, keyPackageEventsJson = listOf(kpJson))
        mls.mergePendingCommit(mlsGroupId = groupId)

        // 3. Publish the evolution event (kind 445)
        val evolutionEventJson = result.evolutionEventJson
        publishGroupEvent(evolutionEventJson)

        // 3b. Verify the commit is retrievable from the relay before
        //     sending the Welcome — prevents state forks (MIP-02).
        val commitEvent = Event.fromJson(json = evolutionEventJson)
        verifyEventOnRelay(commitEvent.id().toHex())

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

    // --- Batch add (join-requests) ---

    /** Outcome of a batch add: pubkeys now in the group (added, or already members). */
    data class BatchAddResult(val added: List<String>)

    /**
     * Add several joiners from their gift-wrapped join-requests in a SINGLE MLS
     * commit — one epoch bump for the whole batch instead of one per person. Each
     * request carries the member's signed key package inline, so there's no relay
     * fetch. Atomic: either the whole commit lands (published, verified, welcomes
     * routed) or the group is left unchanged (a bad key package fails the batch and
     * is rolled back; the admin can dismiss it and retry). Mirrors iOS.
     */
    suspend fun addMembers(requests: List<JoinRequest>, groupId: String): BatchAddResult {
        if (requests.isEmpty()) return BatchAddResult(emptyList())
        if (relay.connectedRelayUrls.value.isEmpty()) {
            throw MarmotException("Not connected to any relay")
        }

        val existing = runCatching { mls.getMembers(groupId).toSet() }.getOrDefault(emptySet())
        val alreadyIn = requests.filter { it.pubkey in existing }.map { it.pubkey }
        val toAdd = requests.filter { it.pubkey !in existing }
        if (toAdd.isEmpty()) return BatchAddResult(alreadyIn)

        try {
            // 1. One commit for all the inline key packages.
            val result = mls.addMembers(mlsGroupId = groupId, keyPackageEventsJson = toAdd.map { it.keyPackage })
            mls.mergePendingCommit(mlsGroupId = groupId)

            // 2. Publish + 3. verify the evolution event (MIP-02 anti-fork).
            val evolutionEventJson = result.evolutionEventJson
            publishGroupEvent(evolutionEventJson)
            verifyEventOnRelay(Event.fromJson(json = evolutionEventJson).id().toHex())

            // 4. Route each Welcome to its member by the rumor's `e` tag.
            routeWelcomes(result.welcomeRumorsJson ?: emptyList(), toAdd)

            refreshGroups()
            Timber.i("Batch-added ${toAdd.size} member(s) to group $groupId in one commit")
            return BatchAddResult(alreadyIn + toAdd.map { it.pubkey })
        } catch (e: Exception) {
            // Roll back any unmerged pending commit so the group is left unchanged.
            runCatching { mls.clearPendingCommit(mlsGroupId = groupId) }
            Timber.e("Batch add to group $groupId failed — rolled back: ${e.message}")
            throw e
        }
    }

    /**
     * Gift-wrap each Welcome rumor to its intended member. MDK returns one rumor
     * per added member, tagged with `e` = the key package event id used to add
     * them; map that id back to the member's pubkey. Falls back to positional
     * order if a tag is missing.
     */
    private suspend fun routeWelcomes(welcomeRumors: List<String>, requests: List<JoinRequest>) {
        val kpIdToPubkey = HashMap<String, String>()
        for (req in requests) {
            runCatching { Event.fromJson(json = req.keyPackage).id().toHex() }.getOrNull()?.let {
                kpIdToPubkey[it] = req.pubkey
            }
        }
        welcomeRumors.forEachIndexed { index, rumorJson ->
            val receiverHex = firstETag(rumorJson)?.let { kpIdToPubkey[it] }
                ?: requests.getOrNull(index)?.pubkey?.also {
                    Timber.w("Welcome rumor $index: no e-tag match — using positional recipient")
                }
            if (receiverHex == null) {
                Timber.e("Welcome rumor $index: cannot route — skipping")
                return@forEachIndexed
            }
            val rumor = UnsignedEvent.fromJson(json = rumorJson)
            relay.giftWrap(receiver = PublicKey.parse(publicKey = receiverHex), rumor = rumor, extraTags = emptyList())
        }
    }

    /** First `e` tag value (the key package event id) in a rumor's JSON. */
    internal fun firstETag(rumorJson: String): String? {
        return try {
            val tags = JSONObject(rumorJson).optJSONArray("tags") ?: return null
            for (i in 0 until tags.length()) {
                val tag = tags.optJSONArray(i) ?: continue
                if (tag.length() >= 2 && tag.optString(0) == "e") return tag.optString(1)
            }
            null
        } catch (e: Exception) {
            null
        }
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
     * Rename a group: update MLS group metadata, merge, publish the evolution event.
     */
    suspend fun renameGroup(groupId: String, newName: String) {
        val update = GroupDataUpdate(
            name = newName,
            description = null,
            imageHash = null,
            imageKey = null,
            imageNonce = null,
            relays = null,
            admins = null
        )
        val result = mls.updateGroupData(mlsGroupId = groupId, update = update)
        mls.mergePendingCommit(mlsGroupId = groupId)

        val evolutionEventJson = result.evolutionEventJson
        publishGroupEvent(evolutionEventJson)

        refreshGroups()
        Timber.i("Renamed group $groupId to '$newName'")
    }

    /**
     * Promote a member to admin: appends their pubkey to the group's admin list.
     * No-op if they are already an admin.
     */
    suspend fun promoteToAdmin(pubkeyHex: String, groupId: String) {
        val group = mls.getGroup(groupId) ?: throw IllegalStateException("Group not found: $groupId")
        val currentAdmins = group.adminPubkeys ?: emptyList()
        if (pubkeyHex in currentAdmins) return
        val update = GroupDataUpdate(
            name = null,
            description = null,
            imageHash = null,
            imageKey = null,
            imageNonce = null,
            relays = null,
            admins = currentAdmins + pubkeyHex
        )
        val result = mls.updateGroupData(mlsGroupId = groupId, update = update)
        mls.mergePendingCommit(mlsGroupId = groupId)
        publishGroupEvent(result.evolutionEventJson)
        refreshGroups()
        Timber.i("Promoted ${pubkeyHex.take(8)} to admin in group $groupId")
    }

    // --- Incoming Event Handling ---

    /**
     * Process an incoming event from a relay subscription.
     */
    suspend fun handleIncomingEvent(event: Event) {
        val eventId = event.id().toHex()

        // Skip already-processed events
        if (settings.isEventProcessed(eventId)) {
            Timber.d("Skipping duplicate event ${eventId.take(8)} (kind ${event.kind().asU16()})")
            return
        }

        val kind = event.kind().asU16()

        try {
            when (kind) {
                MarmotKind.GIFT_WRAP -> handleGiftWrap(event)
                MarmotKind.GROUP_EVENT -> handleGroupEvent(event)
                MarmotKind.KEY_PACKAGE -> {
                    Timber.d("Received key package update (kind 30443)")
                }
                else -> Timber.d("Ignoring event kind $kind")
            }

            // If this gift-wrap was previously failed, clear it on success
            if (kind == MarmotKind.GIFT_WRAP) {
                settings.removePendingGiftWrapEventId(eventId)
            }

            // Mark as processed
            settings.addProcessedEventId(eventId)
            Timber.d("Processed event ${eventId.take(8)} (kind $kind)")

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
     * If a matching pending invite exists, auto-accept. Otherwise queue for user approval.
     */
    private suspend fun handleGiftWrap(event: Event) {
        val gift = relay.unwrapGiftWrap(event = event)
        val rumor = gift.rumor()
        val rumorKind = rumor.kind().asU16()

        // Join-request from an invitee who accepted our invite — queue it for the
        // admin to batch-add. (Their KeyPackage rides inline in the payload.)
        if (rumorKind == MarmotKind.JOIN_REQUEST) {
            try {
                val request = JoinRequest.fromJson(rumor.content())
                joinRequestStore.add(request)
                Timber.i("Received join-request from ${request.pubkey.take(8)}… for group ${request.groupId}")
            } catch (e: Exception) {
                Timber.w("Failed to decode join-request rumor — ignoring: ${e.message}")
            }
            return
        }

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

        // Check if user consented via an invite code
        val hasPendingInvite = pendingInviteStore.pendingInvites.value.any {
            it.groupHint == welcome.mlsGroupId
        }

        if (hasPendingInvite) {
            // User explicitly accepted an invite -- auto-join
            acceptWelcomeAndJoin(welcome)
        } else {
            // Unsolicited -- queue for user approval
            val senderHex = event.author().toHex()
            val pending = PendingWelcomeItem(
                mlsGroupId = welcome.mlsGroupId,
                senderPubkeyHex = senderHex,
                wrapperEventId = wrapperEventId,
                receivedAt = System.currentTimeMillis() / 1000
            )
            pendingWelcomeStore.add(pending)
            Timber.i("Queued unsolicited welcome for group ${welcome.mlsGroupId} from ${senderHex.take(8)} -- awaiting user approval")
        }
    }

    /**
     * Accept a processed Welcome and complete the join flow.
     */
    private suspend fun acceptWelcomeAndJoin(welcome: build.marmot.mdk.Welcome) {
        try {
            mls.acceptWelcome(welcome)
        } catch (e: Exception) {
            // If already accepted, check if group exists
            mls.getGroup(welcome.mlsGroupId) ?: throw e
            Timber.i("Welcome already accepted for group ${welcome.mlsGroupId}")
        }
        refreshGroups()

        // Post-join self-update: immediately rotate key material so we
        // are not relying on the Welcome's initial key package (MIP-02).
        try {
            val updateResult = mls.selfUpdate(mlsGroupId = welcome.mlsGroupId)
            mls.mergePendingCommit(mlsGroupId = welcome.mlsGroupId)
            publishGroupEvent(updateResult.evolutionEventJson)
            Timber.i("Post-join self-update completed for group ${welcome.mlsGroupId}")
        } catch (e: Exception) {
            // Non-fatal: the join succeeded. rotateStaleGroups() will retry later.
            Timber.w("Post-join self-update failed: ${e.message}")
        }

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
     * Accept a pending welcome that the user approved from the UI.
     */
    suspend fun approvePendingWelcome(mlsGroupId: String) {
        val welcomes = mls.getPendingWelcomes()
        val welcome = welcomes.firstOrNull { it.mlsGroupId == mlsGroupId }
        if (welcome == null) {
            Timber.w("No pending MLS welcome found for group $mlsGroupId")
            return
        }
        acceptWelcomeAndJoin(welcome)
        pendingWelcomeStore.remove(mlsGroupId)
    }

    /**
     * Decline a pending welcome -- discard it without joining.
     */
    suspend fun declinePendingWelcome(mlsGroupId: String) {
        val welcomes = mls.getPendingWelcomes()
        val welcome = welcomes.firstOrNull { it.mlsGroupId == mlsGroupId }
        if (welcome != null) {
            mls.declineWelcome(welcome)
        }
        pendingWelcomeStore.remove(mlsGroupId)
        Timber.i("Declined welcome for group $mlsGroupId")
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
                    batteryAlertService.check(pubkeyHex = message.senderPubkey, battery = payload.batt)
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
                            refreshGroups()
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
                    refreshGroups()
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
            val pendingIds = settings.pendingGiftWrapEventIds.toSet()
            if (pendingIds.isNotEmpty()) {
                val pendingEventIds = pendingIds.mapNotNull { pendingId ->
                    try {
                        rust.nostr.sdk.EventId.parse(pendingId)
                    } catch (e: Exception) {
                        Timber.w("fetchMissedGiftWraps: invalid pending event id '$pendingId', removing")
                        settings.removePendingGiftWrapEventId(pendingId)
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

                    // Any IDs still pending after retry are permanently
                    // unrecoverable (key package gone from a previous DB).
                    // Mark as processed so we stop refetching every launch.
                    val stillPending = settings.pendingGiftWrapEventIds.intersect(pendingIds)
                    if (stillPending.isNotEmpty()) {
                        Timber.i("fetchMissedGiftWraps: expiring ${stillPending.size} unrecoverable gift-wrap(s)")
                        for (id in stillPending) {
                            settings.removePendingGiftWrapEventId(id)
                            settings.addProcessedEventId(id)
                        }
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

        // The relay in the invite is the guaranteed common ground with the admin.
        // Connect to it (Nostr has no global discovery) so our key package AND the
        // join-request below land where the admin reads — not just on whichever
        // relays we happened to already be connected to.
        relay.ensureRelay(invite.relay)

        val allRelays = activeRelayUrls
        val keyPackageJson = publishKeyPackage(relays = allRelays)

        // Tell the inviter directly that we're ready to join, carrying our key
        // package inline so they can batch-add us with no separate relay fetch.
        // Private: it rides inside a NIP-59 gift-wrap to the inviter. Non-fatal on
        // failure — the admin can still add us by npub the old way.
        try {
            val inviterPK = PublicKey.parse(publicKey = invite.inviterNpub)
            val joinRequest = JoinRequest(
                groupId = invite.groupId,
                pubkey = publicKeyHex,
                keyPackage = keyPackageJson,
                name = nicknameStore.displayName(publicKeyHex)
            )
            val rumor = EventBuilder(
                kind = Kind(kind = MarmotKind.JOIN_REQUEST),
                content = joinRequest.toJson()
            ).build(publicKey = PublicKey.parse(publicKey = publicKeyHex))
            relay.giftWrap(receiver = inviterPK, rumor = rumor, extraTags = emptyList())
            Timber.i("Sent join-request to inviter for group ${invite.groupId}")
        } catch (e: Exception) {
            Timber.w("Failed to send join-request (admin can still add by npub): ${e.message}")
        }

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
