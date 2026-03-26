package org.findmyfam.ui.identity

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import rust.nostr.sdk.EncryptedSecretKey
import rust.nostr.sdk.Keys
import rust.nostr.sdk.SecretKey

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ImportKeyScreen(
    currentPubkeyHex: String?,
    onImport: (String) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier
) {
    val focusManager = LocalFocusManager.current
    val scope = rememberCoroutineScope()

    var keyInput by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var showPassword by remember { mutableStateOf(false) }
    var isValidating by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var showConfirmDialog by remember { mutableStateOf(false) }
    var resolvedNsec by remember { mutableStateOf<String?>(null) }

    val isNcryptsec = keyInput.trimStart().startsWith("ncryptsec1")
    val isNsec = keyInput.trimStart().startsWith("nsec1")
    val hasValidPrefix = isNcryptsec || isNsec

    fun validateAndConfirm() {
        focusManager.clearFocus()
        isValidating = true
        error = null

        scope.launch {
            try {
                val nsec = withContext(Dispatchers.Default) {
                    val trimmed = keyInput.trim()
                    if (trimmed.startsWith("ncryptsec1")) {
                        val encrypted = EncryptedSecretKey.fromBech32(trimmed)
                        try {
                            val sk = encrypted.decrypt(password)
                            sk.toBech32()
                        } catch (_: Exception) {
                            throw Exception("Wrong password. Please try again.")
                        }
                    } else if (trimmed.startsWith("nsec1")) {
                        // Validate it parses
                        try {
                            SecretKey.parse(trimmed)
                            trimmed
                        } catch (_: Exception) {
                            throw Exception("Invalid nsec key format.")
                        }
                    } else {
                        throw Exception("Invalid key format. Expected nsec1... or ncryptsec1...")
                    }
                }

                // Check if it's the same key
                val importedKeys = Keys(secretKey = SecretKey.parse(nsec))
                if (importedKeys.publicKey().toHex() == currentPubkeyHex) {
                    error = "This is already your current identity."
                    isValidating = false
                    return@launch
                }

                resolvedNsec = nsec
                showConfirmDialog = true
            } catch (e: Exception) {
                error = e.message ?: "Import failed"
            } finally {
                isValidating = false
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Import Key") },
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
                .padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Spacer(modifier = Modifier.height(16.dp))

            Text(
                text = "Import an existing Nostr identity. This will replace your current keypair and clear all group data.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )

            Spacer(modifier = Modifier.height(24.dp))

            OutlinedTextField(
                value = keyInput,
                onValueChange = { keyInput = it; error = null },
                label = { Text("nsec or ncryptsec") },
                placeholder = { Text("nsec1... or ncryptsec1...") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            if (isNcryptsec) {
                Spacer(modifier = Modifier.height(12.dp))

                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it; error = null },
                    label = { Text("Decryption Password") },
                    singleLine = true,
                    visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
                    trailingIcon = {
                        IconButton(onClick = { showPassword = !showPassword }) {
                            Icon(
                                if (showPassword) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                contentDescription = "Toggle password visibility"
                            )
                        }
                    },
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                    modifier = Modifier.fillMaxWidth()
                )
            }

            Spacer(modifier = Modifier.height(24.dp))

            Button(
                onClick = { validateAndConfirm() },
                enabled = hasValidPrefix && !isValidating && (!isNcryptsec || password.isNotEmpty()),
                modifier = Modifier.fillMaxWidth()
            ) {
                if (isValidating) {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text("Validating…")
                } else {
                    Text("Import Key")
                }
            }

            error?.let {
                Spacer(modifier = Modifier.height(12.dp))
                Text(it, color = MaterialTheme.colorScheme.error, fontSize = 13.sp)
            }
        }
    }

    // Destructive confirmation dialog
    if (showConfirmDialog) {
        AlertDialog(
            onDismissRequest = { showConfirmDialog = false },
            icon = { Icon(Icons.Default.Warning, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
            title = { Text("Replace Identity?") },
            text = {
                Text("This will permanently replace your current identity and remove all group data. This cannot be undone.")
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        showConfirmDialog = false
                        resolvedNsec?.let { onImport(it) }
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
                ) {
                    Text("Replace Identity")
                }
            },
            dismissButton = {
                TextButton(onClick = { showConfirmDialog = false }) {
                    Text("Cancel")
                }
            }
        )
    }
}
