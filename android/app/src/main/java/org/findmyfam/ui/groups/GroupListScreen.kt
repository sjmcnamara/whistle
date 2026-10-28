package org.findmyfam.ui.groups

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.ExperimentalMaterialApi
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.QrCode
import androidx.compose.material.pullrefresh.PullRefreshIndicator
import androidx.compose.material.pullrefresh.pullRefresh
import androidx.compose.material.pullrefresh.rememberPullRefreshState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.findmyfam.services.LocalGroupAvatarStore
import org.findmyfam.viewmodels.AppViewModel
import org.findmyfam.viewmodels.GroupListViewModel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterialApi::class)
@Composable
fun GroupListScreen(
    viewModel: GroupListViewModel,
    appViewModel: AppViewModel,
    onGroupClick: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    val groups by viewModel.groups.collectAsState()
    val isAccountReady by viewModel.isAccountReady.collectAsState()
    val avatarRevision by LocalGroupAvatarStore.revision.collectAsState()
    val sharedAvatarRevision by appViewModel.sharedGroupAvatarStore.revision.collectAsState()

    var showCreateSheet by remember { mutableStateOf(false) }
    var showMyCodeSheet by remember { mutableStateOf(false) }
    var showFabMenu by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Groups") }
            )
        },
        floatingActionButton = {
            Column(horizontalAlignment = Alignment.End) {
                if (showFabMenu) {
                    SmallFloatingActionButton(
                        onClick = {
                            showFabMenu = false
                            showMyCodeSheet = true
                        },
                        containerColor = MaterialTheme.colorScheme.secondaryContainer,
                        modifier = Modifier.padding(bottom = 8.dp)
                    ) {
                        Icon(Icons.Default.QrCode, contentDescription = "Show My Code")
                    }
                    SmallFloatingActionButton(
                        onClick = {
                            showFabMenu = false
                            if (isAccountReady) {
                                showCreateSheet = true
                            }
                        },
                        containerColor = if (isAccountReady) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceVariant,
                        modifier = Modifier.padding(bottom = 8.dp)
                    ) {
                        Icon(Icons.Default.Groups, contentDescription = "Create Group")
                    }
                }
                FloatingActionButton(
                    onClick = { showFabMenu = !showFabMenu }
                ) {
                    Icon(Icons.Default.Add, contentDescription = "New")
                }
            }
        },
        modifier = modifier
    ) { padding ->
        val isRefreshing by viewModel.isRefreshing.collectAsState()
        val pullRefreshState = rememberPullRefreshState(
            refreshing = isRefreshing,
            onRefresh = { viewModel.refresh() }
        )

        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .pullRefresh(pullRefreshState)
        ) {
            if (groups.isEmpty()) {
                // Empty state matching iOS GroupListView
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center
                ) {
                    Icon(
                        imageVector = Icons.Default.Groups,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                        modifier = Modifier.size(56.dp)
                    )
                    Spacer(modifier = Modifier.height(16.dp))
                    Text(
                        text = "No groups yet",
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "Create a group, or show your code from the menu so an admin can add you to theirs.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center
                    )
                    Spacer(modifier = Modifier.height(24.dp))
                    Button(
                        onClick = { showCreateSheet = true },
                        enabled = isAccountReady
                    ) {
                        Text("Create Group")
                    }
                    if (!isAccountReady) {
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = "Publishing your account…",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            } else {
                LazyColumn(modifier = Modifier.fillMaxSize()) {
                    items(groups.filter { it.isActive }, key = { it.id }) { group ->
                        val avatarBitmap = remember(avatarRevision, sharedAvatarRevision, group.id) {
                            appViewModel.sharedGroupAvatarStore.resolvedImage(group.id)
                        }

                        ListItem(
                            leadingContent = {
                                if (avatarBitmap != null) {
                                    Image(
                                        bitmap = avatarBitmap.asImageBitmap(),
                                        contentDescription = null,
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier.size(40.dp).clip(CircleShape)
                                    )
                                } else {
                                    Box(
                                        modifier = Modifier
                                            .size(40.dp)
                                            .clip(CircleShape)
                                            .background(MaterialTheme.colorScheme.primaryContainer),
                                        contentAlignment = Alignment.Center
                                    ) {
                                        Icon(
                                            Icons.Default.Groups,
                                            contentDescription = null,
                                            tint = MaterialTheme.colorScheme.onPrimaryContainer,
                                            modifier = Modifier.size(24.dp)
                                        )
                                    }
                                }
                            },
                            headlineContent = {
                                Text(
                                    text = group.name,
                                    fontWeight = if (group.hasUnread) FontWeight.Bold else FontWeight.Normal,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            },
                            supportingContent = {
                                Row(
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Text(
                                        text = "${group.memberCount} member${if (group.memberCount == 1) "" else "s"}",
                                        fontSize = 12.sp,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                    if (group.isSharingPaused) {
                                        Text(
                                            text = "• Sharing paused",
                                            fontSize = 12.sp,
                                            color = MaterialTheme.colorScheme.error
                                        )
                                    }
                                }
                            },
                            trailingContent = {
                                if (group.lastActivity != null && group.lastActivity > 0) {
                                    Text(
                                        text = formatRelativeTime(group.lastActivity),
                                        fontSize = 11.sp,
                                        color = if (group.hasUnread) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            },
                            modifier = Modifier
                                .clickable {
                                    viewModel.markAsRead(group.id)
                                    onGroupClick(group.id)
                                }
                        )
                        HorizontalDivider()
                    }
                }
            }

            PullRefreshIndicator(
                refreshing = isRefreshing,
                state = pullRefreshState,
                modifier = Modifier.align(Alignment.TopCenter)
            )
        }
    }

    if (showCreateSheet) {
        CreateGroupSheet(
            onDismiss = { showCreateSheet = false },
            onCreate = { name ->
                showCreateSheet = false
                viewModel.createGroup(name)
            }
        )
    }

    if (showMyCodeSheet) {
        MemberCodeSheet(
            marmot = viewModel.marmot,
            onDismiss = { showMyCodeSheet = false }
        )
    }
}

private fun formatRelativeTime(epochSeconds: Long): String {
    val now = System.currentTimeMillis() / 1000
    val diff = now - epochSeconds
    return when {
        diff < 60 -> "now"
        diff < 3600 -> "${diff / 60}m ago"
        diff < 86400 -> "${diff / 3600}h ago"
        diff < 604800 -> "${diff / 86400}d ago"
        else -> {
            val sdf = SimpleDateFormat("MMM d", Locale.getDefault())
            val date = Date(epochSeconds * 1000)
            sdf.format(date)
        }
    }
}
