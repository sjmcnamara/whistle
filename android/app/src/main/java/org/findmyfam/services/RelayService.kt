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

    private val _connectedRelayUrls = MutableStateFlow<List<String>>(emptyList())
    val connectedRelayUrls: StateFlow<List<String>> = _connectedRelayUrls.asStateFlow()

    var client: Client? = null
        private set

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
        val added = mutableListOf<String>()

        for (url in relays) {
            try {
                val relayUrl = RelayUrl.parse(url)
                newClient.addRelay(url = relayUrl)
                added.add(url)
                Timber.d("Added relay: $url")
            } catch (e: Exception) {
                Timber.w("Skipping relay $url: ${e.message}")
            }
        }

        newClient.connect()

        client = newClient
        _connectedRelayUrls.value = added
        _connectionState.value = if (added.isEmpty()) ConnectionState.FAILED else ConnectionState.CONNECTED

        Timber.i("Connected to ${added.size} relay(s)")
    }

    /**
     * Disconnect from all relays.
     */
    suspend fun disconnect() {
        client?.disconnect()
        client = null
        _connectedRelayUrls.value = emptyList()
        _connectionState.value = ConnectionState.DISCONNECTED
        Timber.i("Disconnected from all relays")
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
}
