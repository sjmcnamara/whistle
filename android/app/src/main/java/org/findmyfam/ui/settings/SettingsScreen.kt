package org.findmyfam.ui.settings

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.findmyfam.models.AppSettings
import org.findmyfam.services.IdentityService
import org.findmyfam.services.NicknameStore
import org.findmyfam.ui.common.QrCodeImage

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    settings: AppSettings,
    identity: IdentityService,
    nicknameStore: NicknameStore,
    onDisplayNameChanged: (String) -> Unit = {},
    onExportKey: () -> Unit = {},
    onImportKey: () -> Unit = {},
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    var displayName by remember { mutableStateOf(settings.displayName) }
    var showCopied by remember { mutableStateOf(false) }
    var appLockEnabled by remember { mutableStateOf(settings.isAppLockEnabled) }
    var locationPaused by remember { mutableStateOf(settings.isLocationPaused) }
    var rotationDays by remember { mutableIntStateOf(settings.keyRotationIntervalDays) }
    var locationInterval by remember { mutableIntStateOf(settings.locationIntervalSeconds) }

    Scaffold(
        topBar = {
            TopAppBar(title = { Text("Settings") })
        },
        modifier = modifier
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
        ) {
            // Identity section
            SectionHeader("Identity")

            // npub card with QR
            Card(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant
                )
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    identity.npub?.let { npub ->
                        QrCodeImage(content = npub, size = 160.dp)
                        Spacer(modifier = Modifier.height(12.dp))
                        Text(
                            text = npub,
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 2,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth()
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        TextButton(onClick = {
                            val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            clipboard.setPrimaryClip(ClipData.newPlainText("npub", npub))
                            showCopied = true
                        }) {
                            Icon(Icons.Default.ContentCopy, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(modifier = Modifier.width(4.dp))
                            Text(if (showCopied) "Copied!" else "Copy npub")
                        }
                    }
                }
            }

            // Display name
            SettingsTextField(
                value = displayName,
                onValueChange = { displayName = it },
                label = "Display Name",
                icon = Icons.Default.Person,
                onDone = {
                    settings.displayName = displayName
                    identity.publicKeyHex?.let { pubkey ->
                        nicknameStore.set(displayName, pubkey)
                    }
                    onDisplayNameChanged(displayName)
                }
            )

            // Key management
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

            // Security section
            SectionHeader("Security")

            SettingsToggle(
                label = "App Lock",
                icon = Icons.Default.Lock,
                checked = appLockEnabled,
                onCheckedChange = { appLockEnabled = it; settings.isAppLockEnabled = it }
            )

            // Key rotation interval
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

            // Location section
            SectionHeader("Location")

            SettingsToggle(
                label = "Pause Location Sharing",
                icon = Icons.Default.LocationOff,
                checked = locationPaused,
                onCheckedChange = { locationPaused = it; settings.isLocationPaused = it }
            )

            var intervalExpanded by remember { mutableStateOf(false) }
            SettingsRow(
                label = "Update Interval",
                icon = Icons.Default.Timer,
                trailing = {
                    TextButton(onClick = { intervalExpanded = true }) {
                        Text(formatInterval(locationInterval))
                    }
                    DropdownMenu(
                        expanded = intervalExpanded,
                        onDismissRequest = { intervalExpanded = false }
                    ) {
                        listOf(10 to "10 sec", 300 to "5 min", 900 to "15 min", 1800 to "30 min", 3600 to "1 hour").forEach { (secs, label) ->
                            DropdownMenuItem(
                                text = { Text(label) },
                                onClick = {
                                    locationInterval = secs; settings.locationIntervalSeconds = secs
                                    intervalExpanded = false
                                }
                            )
                        }
                    }
                }
            )

            Divider(modifier = Modifier.padding(vertical = 8.dp))

            // Relays section (read-only for now)
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

            // About section
            SectionHeader("About")

            SettingsRow(
                label = "Version",
                icon = Icons.Default.Info,
                trailing = {
                    Text(
                        text = "${LocalContext.current.packageManager.getPackageInfo(LocalContext.current.packageName, 0).versionName} (Android)",
                        fontSize = 14.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            )

            Spacer(modifier = Modifier.height(32.dp))
        }
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
    )
}

@Composable
private fun SettingsToggle(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(24.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(modifier = Modifier.width(16.dp))
        Text(label, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

@Composable
private fun SettingsRow(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    trailing: @Composable () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(24.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(modifier = Modifier.width(16.dp))
        Text(label, modifier = Modifier.weight(1f))
        trailing()
    }
}

@Composable
private fun SettingsTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    onDone: () -> Unit
) {
    val focusManager = LocalFocusManager.current

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(24.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(modifier = Modifier.width(16.dp))
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            label = { Text(label) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(
                onDone = {
                    onDone()
                    focusManager.clearFocus()
                }
            ),
            modifier = Modifier.weight(1f)
        )
    }
}

private fun formatInterval(seconds: Int): String = when {
    seconds < 60 -> "${seconds}s"
    seconds < 3600 -> "${seconds / 60} min"
    else -> "${seconds / 3600} hour${if (seconds >= 7200) "s" else ""}"
}
