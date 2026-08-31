package org.findmyfam.services

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import rust.nostr.sdk.*
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Manages connections to Nostr relays.
 * Mirrors iOS RelayService.
 */
@Singleton
class RelayService @Inject constructor() {

    enum class ConnectionState {
        DISCONNECTED, CONNECTING, CONNECTED, FAILED
    }

    private val _connectionState = MutableStateFlow(ConnectionState.DISCONNECTED)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    /**
     * Relays with a live socket right now, as the original URL strings from
     * settings. Derived from the SDK's per-relay status — never from the fact
     * that a relay was successfully *added*, which says nothing about reachability.
     */
    private val _connectedRelayUrls = MutableStateFlow<List<String>>(emptyList())
    val connectedRelayUrls: StateFlow<List<String>> = _connectedRelayUrls.asStateFlow()

    var client: Client? = null
        private set

    /**
     * Registered relays, mapping the SDK's normalised [RelayUrl] back to the exact
     * string held in settings. RelayUrl.parse normalises (it can append a trailing
     * slash), so status lookups must be translated back through this map or callers
     * comparing against their own settings strings never match.
     */
    private var registeredRelays: MutableMap<RelayUrl, String> = mutableMapOf()

    /**
     * Connect to the given relays using the provided signing keys.
     */
    suspend fun connect(keys: Keys, relays: List<String>) {
        if (relays.isEmpty()) {
            Timber.w("No relays configured — skipping connect")
            return
        }

        _connectionState.value = ConnectionState.CONNECTING

        val signer = NostrSigner.keys(keys = keys)
        val newClient = Client(signer = signer)
        val registered = mutableMapOf<RelayUrl, String>()

        for (url in relays) {
            try {
                val relayUrl = RelayUrl.parse(url)
                newClient.addRelay(url = relayUrl)
                registered[relayUrl] = url
                Timber.d("Added relay: $url")
            } catch (e: Exception) {
                Timber.w("Skipping relay $url: ${e.message}")
            }
        }

        client = newClient
        registeredRelays = registered

        if (registered.isEmpty()) {
            _connectedRelayUrls.value = emptyList()
            _connectionState.value = ConnectionState.FAILED
            Timber.w("No relays could be registered")
            return
        }

        // connect() spawns a retrying background task per relay and returns
        // immediately. We deliberately do not use tryConnect, which reports
        // failures synchronously but schedules no retries — bad for a phone that
        // moves between networks.
        newClient.connect()
        newClient.waitForConnection(CONNECTION_WAIT_TIMEOUT)
        refreshConnectedRelays()
    }

    /**
     * Re-read live socket status from the SDK and republish [connectedRelayUrls].
     *
     * Relays drop and reconnect in the background long after [connect] returns, so
     * anything showing connection state to the user (settings, diagnostics) should
     * call this rather than trusting a value cached at connect time.
     */
    suspend fun refreshConnectedRelays() {
        val c = client
        if (c == null) {
            _connectedRelayUrls.value = emptyList()
            _connectionState.value = ConnectionState.DISCONNECTED
            return
        }

        val relays = c.relays()
        val connected = relays
            .filter { it.value.isConnected() }
            .map { registeredRelays[it.key] ?: it.key.toString() }
            .sorted()

        _connectedRelayUrls.value = connected
        _connectionState.value =
            if (connected.isEmpty()) ConnectionState.FAILED else ConnectionState.CONNECTED

        Timber.i("Connected to ${connected.size}/${relays.size} relay(s)")
    }

    /**
     * Whether any relay currently has a live socket.
     *
     * Callers gating network work should use this rather than reading
     * connectedRelayUrls.value.isEmpty() directly: that list is a snapshot from
     * the last refresh, and relays reconnect in the background between refreshes.
     * A stale-empty snapshot would otherwise fail an operation that could in fact
     * have succeeded.
     */
    suspend fun hasConnectedRelays(): Boolean {
        if (_connectedRelayUrls.value.isNotEmpty()) return true
        refreshConnectedRelays()
        return _connectedRelayUrls.value.isNotEmpty()
    }

    /**
     * Disconnect from all relays.
     */
    suspend fun disconnect() {
        client?.disconnect()
        client = null
        registeredRelays = mutableMapOf()
        _connectedRelayUrls.value = emptyList()
        _connectionState.value = ConnectionState.DISCONNECTED
        Timber.i("Disconnected from all relays")
    }

    /**
     * Add and connect a single relay (e.g. an invite's relay hint) to the
     * existing client so subsequent publishes/gift-wraps reach it. No-op if
     * already connected or if there's no client yet. addRelay is idempotent.
     */
    suspend fun ensureRelay(url: String) {
        val c = client ?: run {
            Timber.w("ensureRelay($url) skipped — not connected")
            return
        }
        try {
            val relayUrl = RelayUrl.parse(url)
            // Guard on registration, not on connection: a relay that is added but
            // currently unreachable must not be re-added on every call.
            if (registeredRelays.containsKey(relayUrl)) return

            c.addRelay(url = relayUrl)
            registeredRelays[relayUrl] = url
            c.connectRelay(url = relayUrl)
            // connectRelay also returns before the socket is up.
            c.waitForConnection(CONNECTION_WAIT_TIMEOUT)
            refreshConnectedRelays()
            Timber.i("Ensured relay registered: $url")
        } catch (e: Exception) {
            Timber.w("ensureRelay($url) failed: ${e.message}")
        }
    }

    /**
     * Publish a pre-built event to all connected relays.
     */
    suspend fun publish(builder: EventBuilder): String {
        val c = client ?: throw IllegalStateException("Not connected to any relay")
        val output = c.sendEventBuilder(builder = builder)
        return output.id.toBech32()
    }

    /**
     * Publish a pre-signed Event object to all connected relays.
     */
    suspend fun sendEvent(event: Event): String {
        val c = client ?: throw IllegalStateException("Not connected to any relay")
        val output = c.sendEvent(event = event)
        return output.id.toHex()
    }

    /**
     * One-shot fetch of events matching the filter.
     */
    suspend fun fetchEvents(filter: Filter, timeout: java.time.Duration): List<Event> {
        val c = client ?: throw IllegalStateException("Not connected to any relay")
        return c.fetchEvents(filter = filter, timeout = timeout).toVec()
    }

    /**
     * Open a persistent subscription, returns the subscription ID.
     */
    suspend fun subscribe(filter: Filter): String {
        val c = client ?: throw IllegalStateException("Not connected to any relay")
        val output = c.subscribe(filter = filter, opts = null)
        return output.id
    }

    /**
     * Register a handler for incoming events from active subscriptions.
     */
    suspend fun handleNotifications(handler: HandleNotification) {
        val c = client ?: throw IllegalStateException("Not connected to any relay")
        c.handleNotifications(handler = handler)
    }

    /**
     * Gift-wrap an unsigned rumor event and publish to the receiver.
     */
    suspend fun giftWrap(receiver: PublicKey, rumor: UnsignedEvent, extraTags: List<Tag>) {
        val c = client ?: throw IllegalStateException("Not connected to any relay")
        c.giftWrap(receiver = receiver, rumor = rumor, extraTags = extraTags)
    }

    /**
     * Unwrap a received NIP-59 gift-wrap event.
     */
    suspend fun unwrapGiftWrap(event: Event): UnwrappedGift {
        val c = client ?: throw IllegalStateException("Not connected to any relay")
        return c.unwrapGiftWrap(giftWrap = event)
    }

    companion object {
        /**
         * How long [connect] waits for sockets to open before reporting status.
         * Client.connect() returns as soon as the background connection tasks are
         * spawned, so without this wait every relay would still be CONNECTING.
         * Mirrors iOS RelayService.connectionWaitTimeout.
         */
        private val CONNECTION_WAIT_TIMEOUT: java.time.Duration = java.time.Duration.ofSeconds(5)
    }
}
