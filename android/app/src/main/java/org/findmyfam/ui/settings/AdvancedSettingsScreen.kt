package org.findmyfam.ui.settings

import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
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
import kotlinx.coroutines.launch
import org.findmyfam.models.AppSettings
import org.findmyfam.models.BurnPlan
import org.findmyfam.services.IdentityService
import org.findmyfam.services.RelayService
import org.findmyfam.shared.models.RelayConfig

/** How often the relay status dots re-read live socket state, in milliseconds. */
private const val RELAY_STATUS_REFRESH_MS = 5_000L

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AdvancedSettingsScreen(
    settings: AppSettings,
    identity: IdentityService,
    relayService: RelayService,
    mlsReady: Boolean = false,
    mlsError: String? = null,
    onReconnectRelays: () -> Unit = {},
    onFuzzSettingChanged: () -> Unit = {},
    onExportKey: () -> Unit = {},
    onImportKey: () -> Unit = {},
    onPrepareBurnPlan: suspend () -> BurnPlan = { BurnPlan(emptyList(), emptyList(), emptyList()) },
    onExecuteBurnPlan: suspend (BurnPlan, Map<String, String>) -> Unit = { _, _ -> },
    onDiagnostics: () -> Unit = {},
    onBack: () -> Unit = {},
    modifier: Modifier = Modifier
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    var appLockEnabled by remember { mutableStateOf(settings.isAppLockEnabled) }
    var rotationDays by remember { mutableIntStateOf(settings.keyRotationIntervalDays) }
    var showBurnConfirm by remember { mutableStateOf(false) }
    var showBurnPlanReview by remember { mutableStateOf(false) }
    var burnPlan by remember { mutableStateOf<BurnPlan?>(null) }
    var burnPromotions by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var isPreparingBurnPlan by remember { mutableStateOf(false) }
    val coroutineScope = rememberCoroutineScope()
    var relays by remember { mutableStateOf(settings.relays) }
    var showAddRelay by remember { mutableStateOf(false) }
    var newRelayURL by remember { mutableStateOf("wss://") }
    var relayError by remember { mutableStateOf<String?>(null) }
    val relayConnectionState by relayService.connectionState.collectAsState()
    val connectedRelayUrls by relayService.connectedRelayUrls.collectAsState()

    // Relay sockets drop and reconnect in the background, so the status dots go
    // stale unless we re-read live status while this screen is open.
    // Mirrors the .task refresh loop in iOS AdvancedSettingsView.
    LaunchedEffect(Unit) {
        while (true) {
            relayService.refreshConnectedRelays()
            kotlinx.coroutines.delay(RELAY_STATUS_REFRESH_MS)
        }
    }

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

            if (appLockEnabled) {
                SettingsRow(
                    label = "Biometric Settings",
                    icon = Icons.Default.Fingerprint,
                    trailing = {
                        TextButton(onClick = {
                            context.startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
                        }) { Text("Open") }
                    }
                )
            }

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
                                    onFuzzSettingChanged()
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

            // Diagnostics — placed just above the danger zone: it is the thing
            // to reach for when something is wrong, and to try before anything
            // destructive.
            SectionHeader("Diagnostics")

            OutlinedButton(
                onClick = onDiagnostics,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp)
            ) {
                Icon(Icons.Default.Info, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(modifier = Modifier.width(8.dp))
                Text("Share Diagnostics")
            }

            // Danger zone
            SectionHeader("Danger Zone")

            Button(
                onClick = {
                    isPreparingBurnPlan = true
                    coroutineScope.launch {
                        // Every active group needs its own MLS round-trip
                        // (serialized behind MLSService's mutex) to re-sync
                        // admin state before this can be decided -- with
                        // several groups this is genuinely a few seconds,
                        // not free. The spinner exists so that reads as
                        // "working", not "frozen".
                        val plan = onPrepareBurnPlan()
                        isPreparingBurnPlan = false
                        burnPlan = plan
                        burnPromotions = emptyMap()
                        if (plan.needsReview) {
                            showBurnPlanReview = true
                        } else {
                            showBurnConfirm = true
                        }
                    }
                },
                enabled = !isPreparingBurnPlan,
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.error
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp)
            ) {
                if (isPreparingBurnPlan) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.onError
                    )
                } else {
                    Icon(Icons.Default.LocalFireDepartment, contentDescription = null, modifier = Modifier.size(18.dp))
                }
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

    if (showBurnPlanReview) {
        burnPlan?.let { plan ->
            AlertDialog(
                onDismissRequest = {
                    showBurnPlanReview = false
                    burnPlan = null
                    burnPromotions = emptyMap()
                },
                title = { Text("Review Before Burning") },
                text = {
                    Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                        if (plan.leaving.isNotEmpty()) {
                            Text(
                                "Leaving",
                                style = MaterialTheme.typography.titleSmall,
                                color = MaterialTheme.colorScheme.primary
                            )
                            plan.leaving.forEach { group ->
                                Text(group.groupName, modifier = Modifier.padding(vertical = 2.dp))
                            }
                            Text(
                                "Another admin remains — these groups continue without you.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(top = 4.dp, bottom = 16.dp)
                            )
                        }

                        if (plan.promoteOrEnd.isNotEmpty()) {
                            Text(
                                "Choose a new admin",
                                style = MaterialTheme.typography.titleSmall,
                                color = MaterialTheme.colorScheme.primary
                            )
                            Text(
                                "You're the only admin in these groups. Promote someone to keep it going, or let it end.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(bottom = 4.dp)
                            )
                            plan.promoteOrEnd.forEach { group ->
                                Text(
                                    group.groupName,
                                    style = MaterialTheme.typography.bodyLarge,
                                    modifier = Modifier.padding(top = 8.dp)
                                )
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable { burnPromotions = burnPromotions - group.groupId }
                                ) {
                                    RadioButton(
                                        selected = burnPromotions[group.groupId] == null,
                                        onClick = { burnPromotions = burnPromotions - group.groupId }
                                    )
                                    Text("End this group")
                                }
                                group.candidates.forEach { candidate ->
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .clickable {
                                                burnPromotions = burnPromotions + (group.groupId to candidate.pubkeyHex)
                                            }
                                    ) {
                                        RadioButton(
                                            selected = burnPromotions[group.groupId] == candidate.pubkeyHex,
                                            onClick = {
                                                burnPromotions = burnPromotions + (group.groupId to candidate.pubkeyHex)
                                            }
                                        )
                                        Text(candidate.displayName)
                                    }
                                }
                            }
                            Spacer(modifier = Modifier.height(16.dp))
                        }

                        if (plan.ending.isNotEmpty()) {
                            Text(
                                "Will end",
                                style = MaterialTheme.typography.titleSmall,
                                color = MaterialTheme.colorScheme.primary
                            )
                            plan.ending.forEach { group ->
                                Text(group.groupName, modifier = Modifier.padding(vertical = 2.dp))
                            }
                            Text(
                                "No other members — burning ends these groups.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(top = 4.dp)
                            )
                        }
                    }
                },
                confirmButton = {
                    TextButton(
                        onClick = {
                            showBurnPlanReview = false
                            showBurnConfirm = true
                        }
                    ) {
                        Text("Continue")
                    }
                },
                dismissButton = {
                    TextButton(
                        onClick = {
                            showBurnPlanReview = false
                            burnPlan = null
                            burnPromotions = emptyMap()
                        }
                    ) {
                        Text("Cancel")
                    }
                }
            )
        }
    }

    if (showBurnConfirm) {
        AlertDialog(
            onDismissRequest = { showBurnConfirm = false },
            title = { Text("Burn Identity?") },
            text = {
                Text("This will remove you from every group where you're not the only admin, then permanently destroy your identity and erase everything on this device. This cannot be undone.")
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        showBurnConfirm = false
                        val plan = burnPlan ?: BurnPlan(emptyList(), emptyList(), emptyList())
                        val promotions = burnPromotions
                        coroutineScope.launch { onExecuteBurnPlan(plan, promotions) }
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
