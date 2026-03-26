package org.findmyfam.ui.groups

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ExitToApp
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.findmyfam.viewmodels.GroupDetailViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GroupDetailScreen(
    viewModel: GroupDetailViewModel,
    onBack: () -> Unit,
    onLeaveComplete: () -> Unit,
    modifier: Modifier = Modifier
) {
    val groupName by viewModel.groupName.collectAsState()
    val members by viewModel.members.collectAsState()
    val inviteCode by viewModel.inviteCode.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val isAddingMember by viewModel.isAddingMember.collectAsState()
    val error by viewModel.error.collectAsState()
    val addMemberNpub by viewModel.addMemberNpub.collectAsState()
    val isLeaving by viewModel.isLeaving.collectAsState()
    val didRequestLeave by viewModel.didRequestLeave.collectAsState()
    val isRenaming by viewModel.isRenaming.collectAsState()

    var showRenameDialog by remember { mutableStateOf(false) }
    var showLeaveConfirm by remember { mutableStateOf(false) }
    var showInviteSheet by remember { mutableStateOf(false) }
    var renameText by remember { mutableStateOf("") }

    // Initial load
    LaunchedEffect(Unit) {
        viewModel.load()
    }

    // Navigate back after leave request
    LaunchedEffect(didRequestLeave) {
        if (didRequestLeave) {
            onLeaveComplete()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Group Details") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        },
        modifier = modifier
    ) { padding ->
        if (isLoading) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentAlignment = Alignment.Center
            ) {
                CircularProgressIndicator()
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentPadding = PaddingValues(bottom = 32.dp)
            ) {
                // Group name section
                item {
                    ListItem(
                        headlineContent = {
                            Text(
                                text = groupName,
                                fontSize = 20.sp,
                                fontWeight = FontWeight.Bold
                            )
                        },
                        trailingContent = {
                            if (viewModel.isAdmin) {
                                IconButton(onClick = {
                                    renameText = groupName
                                    showRenameDialog = true
                                }) {
                                    Icon(Icons.Default.Edit, contentDescription = "Rename")
                                }
                            }
                        }
                    )
                    HorizontalDivider()
                }

                // Actions section
                item {
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "Actions",
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                    )
                }

                // Generate invite
                item {
                    ListItem(
                        headlineContent = { Text("Generate Invite Code") },
                        leadingContent = {
                            Icon(Icons.Default.Share, contentDescription = null)
                        },
                        modifier = Modifier.clickable {
                            viewModel.generateInvite()
                            showInviteSheet = true
                        }
                    )
                }

                // Leave group
                item {
                    ListItem(
                        headlineContent = {
                            Text(
                                "Leave Group",
                                color = MaterialTheme.colorScheme.error
                            )
                        },
                        leadingContent = {
                            Icon(
                                Icons.AutoMirrored.Filled.ExitToApp,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.error
                            )
                        },
                        modifier = Modifier.clickable { showLeaveConfirm = true }
                    )
                    HorizontalDivider()
                }

                // Members section
                item {
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "Members (${members.size})",
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                    )
                }

                itemsIndexed(members, key = { index, member -> "${member.id}_$index" }) { _, member ->
                    ListItem(
                        headlineContent = {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(member.displayName)
                                if (member.isMe) {
                                    Text(
                                        " (You)",
                                        fontSize = 12.sp,
                                        color = MaterialTheme.colorScheme.primary
                                    )
                                }
                            }
                        },
                        supportingContent = {
                            if (member.isAdmin) {
                                Text(
                                    "Admin",
                                    fontSize = 12.sp,
                                    color = MaterialTheme.colorScheme.primary
                                )
                            }
                        },
                        trailingContent = {
                            if (viewModel.isAdmin && !member.isMe) {
                                IconButton(onClick = {
                                    viewModel.removeMember(member.pubkeyHex)
                                }) {
                                    Icon(
                                        Icons.Default.PersonRemove,
                                        contentDescription = "Remove",
                                        tint = MaterialTheme.colorScheme.error
                                    )
                                }
                            }
                        }
                    )
                    HorizontalDivider()
                }

                // Add member section (admin only)
                if (viewModel.isAdmin) {
                    item {
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = "Add Member",
                            style = MaterialTheme.typography.titleSmall,
                            color = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                        )
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            OutlinedTextField(
                                value = addMemberNpub,
                                onValueChange = { viewModel.updateAddMemberNpub(it) },
                                placeholder = { Text("npub or hex pubkey") },
                                modifier = Modifier.weight(1f),
                                singleLine = true
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                            Button(
                                onClick = { viewModel.addMember() },
                                enabled = addMemberNpub.isNotBlank() && !isAddingMember
                            ) {
                                if (isAddingMember) {
                                    CircularProgressIndicator(
                                        modifier = Modifier.size(16.dp),
                                        strokeWidth = 2.dp
                                    )
                                } else {
                                    Text("Add")
                                }
                            }
                        }
                    }
                }

                // Error display
                if (error != null) {
                    item {
                        Text(
                            text = error ?: "",
                            color = MaterialTheme.colorScheme.error,
                            fontSize = 12.sp,
                            modifier = Modifier.padding(16.dp)
                        )
                    }
                }
            }
        }
    }

    // Rename dialog
    if (showRenameDialog) {
        AlertDialog(
            onDismissRequest = { showRenameDialog = false },
            title = { Text("Rename Group") },
            text = {
                OutlinedTextField(
                    value = renameText,
                    onValueChange = { renameText = it },
                    label = { Text("Group Name") },
                    singleLine = true
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        showRenameDialog = false
                        viewModel.renameGroup(renameText)
                    },
                    enabled = renameText.isNotBlank() && !isRenaming
                ) {
                    Text("Rename")
                }
            },
            dismissButton = {
                TextButton(onClick = { showRenameDialog = false }) {
                    Text("Cancel")
                }
            }
        )
    }

    // Leave confirmation dialog
    if (showLeaveConfirm) {
        AlertDialog(
            onDismissRequest = { showLeaveConfirm = false },
            title = { Text("Leave Group") },
            text = { Text("Are you sure you want to leave this group? The admin will need to process your removal.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        showLeaveConfirm = false
                        viewModel.requestLeave()
                    },
                    enabled = !isLeaving
                ) {
                    Text("Leave", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { showLeaveConfirm = false }) {
                    Text("Cancel")
                }
            }
        )
    }

    // Invite share sheet
    if (showInviteSheet && inviteCode != null) {
        InviteShareSheet(
            inviteCode = inviteCode ?: "",
            onDismiss = { showInviteSheet = false }
        )
    }
}

// Using androidx.compose.foundation.clickable directly via import
