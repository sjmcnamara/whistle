package org.findmyfam.ui.groups

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ExitToApp
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.findmyfam.services.LocalGroupAvatarStore
import org.findmyfam.ui.common.QrScannerScreen
import org.findmyfam.viewmodels.GroupDetailViewModel

/**
 * Group management — a WhatsApp-style hero header (icon + name + rename) over
 * grouped sections: pending joiners, invite actions, members (preview + "See
 * all" for large groups), and leave. Members and Add-by-npub are full-screen
 * sub-views swapped in via local state.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
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
    val leaveRequestMembers by viewModel.leaveRequestMembers.collectAsState()
    val pendingJoiners by viewModel.pendingJoiners.collectAsState()

    var showRenameDialog by remember { mutableStateOf(false) }
    var showLeaveConfirm by remember { mutableStateOf(false) }
    var showInviteSheet by remember { mutableStateOf(false) }
    var renameText by remember { mutableStateOf("") }
    var subScreen by remember { mutableStateOf("main") } // main | members | addNpub
    var submittingAdd by remember { mutableStateOf(false) }

    val context = LocalContext.current
    val avatarRevision by LocalGroupAvatarStore.revision.collectAsState()
    val avatarBitmap = remember(avatarRevision) { LocalGroupAvatarStore.image(viewModel.groupId) }
    var showAvatarMenu by remember { mutableStateOf(false) }
    val avatarPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri?.let { LocalGroupAvatarStore.setImage(context, viewModel.groupId, it) }
    }

    LaunchedEffect(Unit) { viewModel.load() }
    LaunchedEffect(didRequestLeave) { if (didRequestLeave) onLeaveComplete() }

    val memberPreviewCap = 6

    // --- Sub-screens (full-screen swaps) ---

    if (subScreen == "members") {
        MembersSubScreen(
            members = members,
            leaveRequestMembers = leaveRequestMembers,
            isAdmin = viewModel.isAdmin,
            onPromote = { viewModel.promoteToAdmin(it) },
            onRemove = { viewModel.removeMember(it) },
            onBack = { subScreen = "main" }
        )
        return
    }

    if (subScreen == "addNpub") {
        // Pop back to the main screen once an add completes without error.
        LaunchedEffect(isAddingMember, error) {
            if (submittingAdd && !isAddingMember) {
                submittingAdd = false
                if (error == null) subScreen = "main"
            }
        }
        AddByNpubSubScreen(
            npub = addMemberNpub,
            isAdding = isAddingMember,
            error = error,
            onNpubChange = { viewModel.updateAddMemberNpub(it) },
            onAdd = { submittingAdd = true; viewModel.addMember() },
            onBack = { subScreen = "main" }
        )
        return
    }

    // --- Main screen ---

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Group") },
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
                modifier = Modifier.fillMaxSize().padding(padding),
                contentAlignment = Alignment.Center
            ) { CircularProgressIndicator() }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(bottom = 32.dp)
            ) {
                // Hero header
                item {
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Box(contentAlignment = Alignment.BottomEnd) {
                            Box(
                                modifier = Modifier
                                    .size(80.dp)
                                    .clip(CircleShape)
                                    .background(MaterialTheme.colorScheme.primaryContainer)
                                    .combinedClickable(
                                        onClick = {
                                            avatarPicker.launch(
                                                PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                                            )
                                        },
                                        onLongClick = {
                                            if (LocalGroupAvatarStore.hasImage(viewModel.groupId))
                                                showAvatarMenu = true
                                        }
                                    ),
                                contentAlignment = Alignment.Center
                            ) {
                                if (avatarBitmap != null) {
                                    androidx.compose.foundation.Image(
                                        bitmap = avatarBitmap.asImageBitmap(),
                                        contentDescription = null,
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier.fillMaxSize()
                                    )
                                } else {
                                    Icon(
                                        Icons.Default.Groups, contentDescription = null,
                                        tint = MaterialTheme.colorScheme.primary,
                                        modifier = Modifier.size(40.dp)
                                    )
                                }
                            }
                            Icon(
                                Icons.Default.AddAPhoto,
                                contentDescription = "Set group photo",
                                modifier = Modifier
                                    .size(24.dp)
                                    .clip(CircleShape)
                                    .background(MaterialTheme.colorScheme.primary)
                                    .padding(4.dp),
                                tint = MaterialTheme.colorScheme.onPrimary
                            )
                        }
                        if (LocalGroupAvatarStore.hasImage(viewModel.groupId)) {
                            DropdownMenu(
                                expanded = showAvatarMenu,
                                onDismissRequest = { showAvatarMenu = false }
                            ) {
                                DropdownMenuItem(
                                    text = { Text("Remove Photo") },
                                    leadingIcon = { Icon(Icons.Default.Delete, contentDescription = null) },
                                    onClick = {
                                        LocalGroupAvatarStore.removeImage(viewModel.groupId)
                                        showAvatarMenu = false
                                    }
                                )
                            }
                        }
                        Spacer(modifier = Modifier.height(8.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                groupName.ifEmpty { "Unnamed Group" },
                                fontSize = 20.sp, fontWeight = FontWeight.Bold
                            )
                            if (viewModel.isAdmin) {
                                IconButton(onClick = { renameText = groupName; showRenameDialog = true }) {
                                    Icon(
                                        Icons.Default.Edit, contentDescription = "Rename",
                                        modifier = Modifier.size(18.dp),
                                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }
                        }
                        Text(
                            "${members.size} member" + if (members.size == 1) "" else "s",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    HorizontalDivider()
                }

                // Ready to Join (pending joiners) — admin only
                if (viewModel.isAdmin && pendingJoiners.isNotEmpty()) {
                    item {
                        Spacer(modifier = Modifier.height(8.dp))
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = "Ready to Join (${pendingJoiners.size})",
                                style = MaterialTheme.typography.titleSmall,
                                color = MaterialTheme.colorScheme.primary
                            )
                            if (pendingJoiners.size > 1) {
                                Spacer(modifier = Modifier.weight(1f))
                                TextButton(
                                    onClick = { viewModel.addAllPendingJoiners() },
                                    enabled = !isAddingMember
                                ) { Text("Add all") }
                            }
                        }
                    }
                    itemsIndexed(pendingJoiners, key = { _, j -> j.pubkey }) { _, joiner ->
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(joiner.name?.takeIf { it.isNotEmpty() } ?: "Anonymous",
                                    style = MaterialTheme.typography.bodyMedium)
                                Text(joiner.pubkey.take(16) + "…",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            IconButton(onClick = { viewModel.addPendingJoiner(joiner) }, enabled = !isAddingMember) {
                                Icon(Icons.Default.PersonAdd, contentDescription = "Add ${joiner.pubkey.take(8)}")
                            }
                            IconButton(onClick = { viewModel.dismissPendingJoiner(joiner) }) {
                                Icon(Icons.Default.Close, contentDescription = "Dismiss")
                            }
                        }
                    }
                    item { HorizontalDivider() }
                }

                // Invite People — admin only
                if (viewModel.isAdmin) {
                    item {
                        SectionHeader("Invite People")
                        ListItem(
                            headlineContent = { Text("Invite via QR / Code") },
                            leadingContent = { Icon(Icons.Default.Share, contentDescription = null) },
                            modifier = Modifier.clickable { viewModel.generateInvite(); showInviteSheet = true }
                        )
                        ListItem(
                            headlineContent = { Text("Add by npub") },
                            leadingContent = { Icon(Icons.Default.PersonAdd, contentDescription = null) },
                            trailingContent = { Icon(Icons.Default.ChevronRight, contentDescription = null) },
                            modifier = Modifier.clickable { subScreen = "addNpub" }
                        )
                        HorizontalDivider()
                    }
                }

                // Members (preview + See all)
                item { SectionHeader("Members (${members.size})") }
                val isLarge = members.size > memberPreviewCap
                val shown = if (isLarge) members.take(memberPreviewCap) else members
                itemsIndexed(shown, key = { i, m -> "${m.id}_$i" }) { _, member ->
                    MemberListItem(
                        member = member,
                        wantsToLeave = member.pubkeyHex in leaveRequestMembers,
                        canManage = viewModel.isAdmin && !isLarge,
                        onPromote = { viewModel.promoteToAdmin(it) },
                        onRemove = { viewModel.removeMember(it) }
                    )
                }
                if (isLarge) {
                    item {
                        ListItem(
                            headlineContent = {
                                Text("See all ${members.size} members", color = MaterialTheme.colorScheme.primary)
                            },
                            trailingContent = { Icon(Icons.Default.ChevronRight, contentDescription = null) },
                            modifier = Modifier.clickable { subScreen = "members" }
                        )
                    }
                }

                // Leave (bottom)
                item {
                    Spacer(modifier = Modifier.height(8.dp))
                    HorizontalDivider()
                    ListItem(
                        headlineContent = { Text("Leave Group", color = MaterialTheme.colorScheme.error) },
                        leadingContent = {
                            Icon(Icons.AutoMirrored.Filled.ExitToApp, contentDescription = null,
                                tint = MaterialTheme.colorScheme.error)
                        },
                        modifier = Modifier.clickable { showLeaveConfirm = true }
                    )
                }

                if (error != null) {
                    item {
                        Text(error ?: "", color = MaterialTheme.colorScheme.error,
                            fontSize = 12.sp, modifier = Modifier.padding(16.dp))
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
                    value = renameText, onValueChange = { renameText = it },
                    label = { Text("Group Name") }, singleLine = true
                )
            },
            confirmButton = {
                TextButton(
                    onClick = { showRenameDialog = false; viewModel.renameGroup(renameText) },
                    enabled = renameText.isNotBlank() && !isRenaming
                ) { Text("Rename") }
            },
            dismissButton = { TextButton(onClick = { showRenameDialog = false }) { Text("Cancel") } }
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
                    onClick = { showLeaveConfirm = false; viewModel.requestLeave() },
                    enabled = !isLeaving
                ) { Text("Leave", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { showLeaveConfirm = false }) { Text("Cancel") } }
        )
    }

    // Invite share sheet
    if (showInviteSheet && inviteCode != null) {
        InviteShareSheet(inviteCode = inviteCode ?: "", onDismiss = { showInviteSheet = false })
    }
}

@Composable
private fun SectionHeader(text: String) {
    Spacer(modifier = Modifier.height(8.dp))
    Text(
        text = text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
    )
}

@Composable
private fun MemberListItem(
    member: GroupDetailViewModel.MemberItem,
    wantsToLeave: Boolean,
    canManage: Boolean,
    onPromote: (String) -> Unit,
    onRemove: (String) -> Unit
) {
    ListItem(
        headlineContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(member.displayName)
                if (member.isMe) {
                    Text(" (You)", fontSize = 12.sp, color = MaterialTheme.colorScheme.primary)
                }
            }
        },
        supportingContent = {
            Column {
                if (member.isAdmin) {
                    Text("Admin", fontSize = 12.sp, color = MaterialTheme.colorScheme.primary)
                }
                if (wantsToLeave) {
                    Text("Wants to leave", fontSize = 12.sp, color = MaterialTheme.colorScheme.tertiary)
                }
            }
        },
        trailingContent = {
            if (canManage && !member.isMe) {
                if (wantsToLeave) {
                    TextButton(onClick = { onRemove(member.pubkeyHex) }) {
                        Icon(Icons.Default.CheckCircle, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(modifier = Modifier.width(4.dp))
                        Text("Approve")
                    }
                } else {
                    Row {
                        if (!member.isAdmin) {
                            IconButton(onClick = { onPromote(member.pubkeyHex) }) {
                                Icon(Icons.Default.Shield, contentDescription = "Make admin",
                                    tint = MaterialTheme.colorScheme.primary)
                            }
                        }
                        IconButton(onClick = { onRemove(member.pubkeyHex) }) {
                            Icon(Icons.Default.PersonRemove, contentDescription = "Remove",
                                tint = MaterialTheme.colorScheme.error)
                        }
                    }
                }
            }
        }
    )
    HorizontalDivider()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MembersSubScreen(
    members: List<GroupDetailViewModel.MemberItem>,
    leaveRequestMembers: Set<String>,
    isAdmin: Boolean,
    onPromote: (String) -> Unit,
    onRemove: (String) -> Unit,
    onBack: () -> Unit
) {
    var query by remember { mutableStateOf("") }
    val filtered = remember(query, members) {
        val q = query.trim().lowercase()
        if (q.isEmpty()) members
        else members.filter {
            it.displayName.lowercase().contains(q) || it.pubkeyHex.lowercase().contains(q)
        }
    }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Members (${members.size})") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            OutlinedTextField(
                value = query, onValueChange = { query = it },
                placeholder = { Text("Search members") },
                leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)
            )
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                itemsIndexed(filtered, key = { i, m -> "${m.id}_$i" }) { _, member ->
                    MemberListItem(
                        member = member,
                        wantsToLeave = member.pubkeyHex in leaveRequestMembers,
                        canManage = isAdmin,
                        onPromote = onPromote,
                        onRemove = onRemove
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddByNpubSubScreen(
    npub: String,
    isAdding: Boolean,
    error: String?,
    onNpubChange: (String) -> Unit,
    onAdd: () -> Unit,
    onBack: () -> Unit
) {
    var showScanner by remember { mutableStateOf(false) }
    if (showScanner) {
        QrScannerScreen(
            onScanned = { scanned ->
                showScanner = false
                val n = when {
                    scanned.startsWith("npub") -> scanned
                    scanned.contains("addmember/") -> scanned.substringAfter("addmember/").substringBefore("/")
                    else -> scanned
                }
                onNpubChange(n)
            },
            onBack = { showScanner = false }
        )
        return
    }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Add by npub") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            OutlinedTextField(
                value = npub, onValueChange = onNpubChange,
                placeholder = { Text("npub or hex pubkey") },
                singleLine = true,
                trailingIcon = {
                    IconButton(onClick = { showScanner = true }) {
                        Icon(Icons.Default.QrCodeScanner, contentDescription = "Scan QR")
                    }
                },
                modifier = Modifier.fillMaxWidth()
            )
            Text(
                "Ask the person for their npub or scan their QR. They must have opened Whistle at least once so their key package is published.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Button(
                onClick = onAdd,
                enabled = npub.isNotBlank() && !isAdding,
                modifier = Modifier.fillMaxWidth()
            ) {
                if (isAdding) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                } else {
                    Text("Add Member")
                }
            }
            if (error != null) {
                Text(error, color = MaterialTheme.colorScheme.error, fontSize = 12.sp)
            }
        }
    }
}
