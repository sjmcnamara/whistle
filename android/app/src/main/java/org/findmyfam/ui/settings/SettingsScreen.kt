package org.findmyfam.ui.settings

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
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
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.findmyfam.models.AppSettings
import org.findmyfam.services.IdentityService
import org.findmyfam.services.NicknameStore

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    settings: AppSettings,
    identity: IdentityService,
    nicknameStore: NicknameStore,
    onDisplayNameChanged: (String) -> Unit = {},
    onExportKey: () -> Unit = {},
    onImportKey: () -> Unit = {},
    onAdvanced: () -> Unit = {},
    onIdentityCard: () -> Unit = {},
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    var displayName by remember { mutableStateOf(settings.displayName) }
    var locationPaused by remember { mutableStateOf(settings.isLocationPaused) }
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

            // Nostr key — tap to see full QR card (mirrors iOS IdentityCardView)
            identity.npub?.let { npub ->
                Card(
                    onClick = onIdentityCard,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant
                    )
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            Icons.Default.Person,
                            contentDescription = null,
                            modifier = Modifier.size(28.dp),
                            tint = MaterialTheme.colorScheme.primary
                        )
                        Spacer(modifier = Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = "Your Nostr Key",
                                style = MaterialTheme.typography.bodyLarge
                            )
                            Text(
                                text = npub.take(20) + "…" + npub.takeLast(8),
                                fontSize = 12.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Icon(
                            Icons.Default.ChevronRight,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
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

            Divider(modifier = Modifier.padding(vertical = 8.dp))

            // Location section
            SectionHeader("Location")

            val hasLocationPermission = androidx.core.content.ContextCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
            if (!hasLocationPermission) {
                SettingsRow(
                    label = "Location Denied — Open Settings",
                    icon = Icons.Default.LocationOff,
                    trailing = {
                        TextButton(onClick = {
                            context.startActivity(
                                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                    data = Uri.fromParts("package", context.packageName, null)
                                }
                            )
                        }) { Text("Open") }
                    }
                )
            }

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

            // Appearance section
            SectionHeader("Appearance")

            var appearanceExpanded by remember { mutableStateOf(false) }
            SettingsRow(
                label = "Theme",
                icon = Icons.Default.DarkMode,
                trailing = {
                    TextButton(onClick = { appearanceExpanded = true }) {
                        Text(
                            when (settings.appearance) {
                                "light" -> "Light"
                                "dark" -> "Dark"
                                else -> "System"
                            }
                        )
                    }
                    DropdownMenu(
                        expanded = appearanceExpanded,
                        onDismissRequest = { appearanceExpanded = false }
                    ) {
                        listOf("system" to "System", "light" to "Light", "dark" to "Dark").forEach { (value, label) ->
                            DropdownMenuItem(
                                text = { Text(label) },
                                onClick = {
                                    settings.appearance = value
                                    appearanceExpanded = false
                                }
                            )
                        }
                    }
                }
            )

            Divider(modifier = Modifier.padding(vertical = 8.dp))

            // About section
            SectionHeader("About")

            SettingsRow(
                label = "Version",
                icon = Icons.Default.Info,
                trailing = {
                    Text(
                        text = "${context.packageManager.getPackageInfo(context.packageName, 0).versionName} (Android)",
                        fontSize = 14.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            )

            SettingsRow(
                label = "Protocol",
                icon = Icons.Default.Security,
                trailing = {
                    Text(
                        text = "Nostr & MLS & Marmot",
                        fontSize = 14.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            )

            SettingsRow(
                label = "Source",
                icon = Icons.Default.Code,
                trailing = {
                    TextButton(onClick = {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/sjmcnamara/whistle")))
                    }) {
                        Text("GitHub")
                    }
                }
            )

            Divider(modifier = Modifier.padding(vertical = 8.dp))

            // Advanced link
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    Icons.Default.Settings,
                    contentDescription = null,
                    modifier = Modifier.size(24.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(modifier = Modifier.width(16.dp))
                TextButton(onClick = onAdvanced) {
                    Text("Advanced Settings")
                }
            }

            Spacer(modifier = Modifier.height(32.dp))
        }
    }
}

@Composable
internal fun SectionHeader(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
    )
}

@Composable
internal fun SettingsToggle(
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
internal fun SettingsRow(
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
