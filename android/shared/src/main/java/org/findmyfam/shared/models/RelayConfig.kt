package org.findmyfam.shared.models

import java.util.UUID

/**
 * Configuration for a single Nostr relay.
 */
data class RelayConfig(
    val id: String = UUID.randomUUID().toString(),
    var url: String,
    var isEnabled: Boolean = true
)
