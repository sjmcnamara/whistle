package org.findmyfam.models

import java.util.UUID

data class RelayConfig(
    val id: String = UUID.randomUUID().toString(),
    var url: String,
    var isEnabled: Boolean = true
)
