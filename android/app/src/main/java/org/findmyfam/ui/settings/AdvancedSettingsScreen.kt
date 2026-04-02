package org.findmyfam.ui.settings

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
import androidx.compose.ui.unit.dp
import org.findmyfam.models.AppSettings
import org.findmyfam.services.IdentityService

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AdvancedSettingsScreen(
    settings: AppSettings,
    identity: IdentityService,
    onExportKey: () -> Unit = {},
    onImportKey: () -> Unit = {},
    onBurnIdentity: () -> Unit = {},
    onBack: () -> Unit = {},
    modifier: Modifier = Modifier
) {
    var appLockEnabled by remember { mutableStateOf(settings.isAppLockEnabled) }
    var rotationDays by remember { mutableIntStateOf(settings.keyRotationIntervalDays) }
    var showBurnConfirm by remember { mutableStateOf(false) }

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

            // Relays
            SectionHeader("Relays")

            for (relay in settings.relays) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        Icons.Default.Cloud,
                        contentDescription = null,
                        modifier = Modifier.size(20.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.width(12.dp))
                    Text(
                        text = relay.url,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                }
            }

            Divider(modifier = Modifier.padding(vertical = 8.dp))

            // Connection
            SectionHeader("Connection")

            SettingsRow(
                label = "Relay",
                icon = Icons.Default.Wifi,
                trailing = {
                    Text(
                        text = "Connected",
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            )

            SettingsRow(
                label = "MLS Crypto",
                icon = Icons.Default.Shield,
                trailing = {
                    Text(
                        text = "Ready",
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
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
