package org.findmyfam.ui.settings

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import org.findmyfam.models.AppSettings
import org.findmyfam.services.IdentityService
import org.findmyfam.services.RelayService
import org.findmyfam.shared.models.RelayConfig

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AdvancedSettingsScreen(
    settings: AppSettings,
    identity: IdentityService,
    relayService: RelayService,
    mlsReady: Boolean = false,
    mlsError: String? = null,
    onReconnectRelays: () -> Unit = {},
    onExportKey: () -> Unit = {},
    onImportKey: () -> Unit = {},
    onBurnIdentity: () -> Unit = {},
    onBack: () -> Unit = {},
    modifier: Modifier = Modifier
) {
    var appLockEnabled by remember { mutableStateOf(settings.isAppLockEnabled) }
    var rotationDays by remember { mutableIntStateOf(settings.keyRotationIntervalDays) }
    var showBurnConfirm by remember { mutableStateOf(false) }
    var relays by remember { mutableStateOf(settings.relays) }
    var showAddRelay by remember { mutableStateOf(false) }
    var newRelayURL by remember { mutableStateOf("wss://") }
    var relayError by remember { mutableStateOf<String?>(null) }
    val relayConnectionState by relayService.connectionState.collectAsState()
    val connectedRelayUrls by relayService.connectedRelayUrls.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Advanced") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        },
        modifier = modifier
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
        ) {
            // Identity — Import / Export
            SectionHeader("Identity")

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                OutlinedButton(
                    onClick = onExportKey,
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(Icons.Default.Upload, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text("Export Key")
                }
                OutlinedButton(
                    onClick = onImportKey,
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(Icons.Default.Download, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text("Import Key")
                }
            }

            Divider(modifier = Modifier.padding(vertical = 8.dp))

            // Security
            SectionHeader("Security")

            SettingsToggle(
                label = "App Lock",
                icon = Icons.Default.Lock,
                checked = appLockEnabled,
                onCheckedChange = { appLockEnabled = it; settings.isAppLockEnabled = it }
            )

            var rotationExpanded by remember { mutableStateOf(false) }
            SettingsRow(
                label = "Key Rotation",
                icon = Icons.Default.Refresh,
                trailing = {
                    TextButton(onClick = { rotationExpanded = true }) {
                        Text("$rotationDays days")
                    }
                    DropdownMenu(
                        expanded = rotationExpanded,
                        onDismissRequest = { rotationExpanded = false }
                    ) {
                        listOf(1, 3, 7, 14, 30).forEach { days ->
                            DropdownMenuItem(
                                text = { Text("$days day${if (days > 1) "s" else ""}") },
                                onClick = {
                                    rotationDays = days; settings.keyRotationIntervalDays = days
                                    rotationExpanded = false
                                }
                            )
                        }
                    }
                }
            )

            Divider(modifier = Modifier.padding(vertical = 8.dp))

            // Location Privacy
            SectionHeader("Location Privacy")

            var fuzzExpanded by remember { mutableStateOf(false) }
            var fuzzMeters by remember { mutableIntStateOf(settings.locationFuzzMeters) }

            SettingsRow(
                label = "Location Fuzzing",
                icon = Icons.Default.LocationOff,
                trailing = {
                    TextButton(onClick = { fuzzExpanded = true }) {
                        Text(
                            when (fuzzMeters) {
                                0 -> "Off"
                                else -> "$fuzzMeters m"
                            }
                        )
                    }
                    DropdownMenu(
                        expanded = fuzzExpanded,
                        onDismissRequest = { fuzzExpanded = false }
                    ) {
                        listOf(0 to "Off — exact location", 10 to "10 m", 50 to "50 m", 200 to "200 m").forEach { (meters, label) ->
                            DropdownMenuItem(
                                text = { Text(label) },
                                onClick = {
                                    fuzzMeters = meters
                                    settings.locationFuzzMeters = meters
                                    fuzzExpanded = false
                                }
                            )
                        }
                    }
                }
            )

            Text(
                text = "Randomly adjusts your shared location by up to this distance. Others see an approximate position instead of your exact coordinates.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)
            )

            Divider(modifier = Modifier.padding(vertical = 8.dp))

            // Relays
            SectionHeader("Relays")

            val defaultRelayUrls = AppSettings.defaultRelays.map { it.url }.toSet()

            for (relay in relays) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    // Connection status dot
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .padding(end = 0.dp)
                    ) {
                        val dotColor = if (relay.isEnabled && relay.url in connectedRelayUrls)
                            Color(0xFF4CAF50) // green
                        else
                            MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
                        Canvas(modifier = Modifier.fillMaxSize()) {
                            drawCircle(color = dotColor)
                        }
                    }
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = relay.url.replace("wss://", ""),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.weight(1f)
                    )
                    // Remove button for custom (non-default) relays
                    if (relay.url !in defaultRelayUrls) {
                        IconButton(
                            onClick = {
                                val updated = relays.filter { it.id != relay.id }
                                relays = updated
                                settings.relays = updated
                                onReconnectRelays()
                            },
                            modifier = Modifier.size(32.dp)
                        ) {
                            Icon(
                                Icons.Default.Close,
                                contentDescription = "Remove",
                                modifier = Modifier.size(16.dp),
                                tint = MaterialTheme.colorScheme.error
                            )
                        }
                    }
                    Switch(
                        checked = relay.isEnabled,
                        onCheckedChange = { enabled ->
                            val updated = relays.map {
                                if (it.id == relay.id) it.copy(isEnabled = enabled) else it
                            }
                            relays = updated
                            settings.relays = updated
                            onReconnectRelays()
                        }
                    )
                }
            }

            // Add Relay button
            TextButton(
                onClick = {
                    newRelayURL = "wss://"
                    relayError = null
                    showAddRelay = true
                },
                modifier = Modifier.padding(horizontal = 8.dp)
            ) {
                Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(modifier = Modifier.width(4.dp))
                Text("Add Relay")
            }

            Text(
                text = "Toggle relays on/off. Default relays cannot be removed.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)
            )

            Divider(modifier = Modifier.padding(vertical = 8.dp))

            // Connection
            SectionHeader("Connection")

            SettingsRow(
                label = "Relay",
                icon = Icons.Default.Wifi,
                trailing = {
                    val (statusText, statusColor) = when (relayConnectionState) {
                        RelayService.ConnectionState.DISCONNECTED -> "Disconnected" to MaterialTheme.colorScheme.onSurfaceVariant
                        RelayService.ConnectionState.CONNECTING -> "Connecting…" to Color(0xFFFF9800)
                        RelayService.ConnectionState.CONNECTED -> "Connected" to Color(0xFF4CAF50)
                        RelayService.ConnectionState.FAILED -> "Failed" to MaterialTheme.colorScheme.error
                    }
                    Text(text = statusText, color = statusColor)
                }
            )

            SettingsRow(
                label = "MLS Crypto",
                icon = Icons.Default.Shield,
                trailing = {
                    if (mlsError != null) {
                        Text(text = "Failed", color = MaterialTheme.colorScheme.error)
                    } else if (mlsReady) {
                        Text(text = "Ready", color = Color(0xFF4CAF50))
                    } else {
                        Text(text = "Starting…", color = Color(0xFFFF9800))
                    }
                }
            )

            Divider(modifier = Modifier.padding(vertical = 8.dp))

            // Danger zone
            SectionHeader("Danger Zone")

            Button(
                onClick = { showBurnConfirm = true },
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.error
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp)
            ) {
                Icon(Icons.Default.LocalFireDepartment, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(modifier = Modifier.width(6.dp))
                Text("Burn Identity")
            }

            Text(
                text = "Generate a fresh identity. All groups, messages, and cryptographic state will be permanently erased.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)
            )

            Spacer(modifier = Modifier.height(32.dp))
        }
    }

    if (showAddRelay) {
        AlertDialog(
            onDismissRequest = { showAddRelay = false },
            title = { Text("Add Relay") },
            text = {
                Column {
                    if (relayError != null) {
                        Text(
                            text = relayError!!,
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier.padding(bottom = 8.dp)
                        )
                    } else {
                        Text(
                            text = "Enter the WebSocket URL of the relay.",
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier.padding(bottom = 8.dp)
                        )
                    }
                    OutlinedTextField(
                        value = newRelayURL,
                        onValueChange = { newRelayURL = it },
                        label = { Text("wss://relay.example.com") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val url = newRelayURL.trim().lowercase()
                        when {
                            !url.startsWith("wss://") && !url.startsWith("ws://") -> {
                                relayError = "URL must start with wss:// or ws://"
                            }
                            url.length <= 6 -> {
                                relayError = "Invalid URL format"
                            }
                            relays.any { it.url == url } -> {
                                relayError = "Relay already exists"
                            }
                            else -> {
                                val updated = relays + RelayConfig(url = url)
                                relays = updated
                                settings.relays = updated
                                showAddRelay = false
                                onReconnectRelays()
                            }
                        }
                    }
                ) {
                    Text("Add")
                }
            },
            dismissButton = {
                TextButton(onClick = { showAddRelay = false }) {
                    Text("Cancel")
                }
            }
        )
    }

    if (showBurnConfirm) {
        AlertDialog(
            onDismissRequest = { showBurnConfirm = false },
            title = { Text("Burn Identity?") },
            text = {
                Text("This will permanently destroy your current identity, leave all groups, and erase all messages. A new identity will be generated. This cannot be undone.")
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        showBurnConfirm = false
                        onBurnIdentity()
                    }
                ) {
                    Text("Burn Everything", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { showBurnConfirm = false }) {
                    Text("Cancel")
                }
            }
        )
    }
}
