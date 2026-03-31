package org.findmyfam.ui.groups

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.GroupAdd
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.ExperimentalMaterialApi
import androidx.compose.material.pullrefresh.PullRefreshIndicator
import androidx.compose.material.pullrefresh.pullRefresh
import androidx.compose.material.pullrefresh.rememberPullRefreshState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.findmyfam.viewmodels.GroupListViewModel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterialApi::class)
@Composable
fun GroupListScreen(
    viewModel: GroupListViewModel,
    onGroupClick: (String) -> Unit,
    onScanQr: () -> Unit = {},
    modifier: Modifier = Modifier
) {
    val groups by viewModel.groups.collectAsState()
    val pendingInvites by viewModel.pendingInvites.collectAsState()
    val pendingLeaves by viewModel.pendingLeaves.collectAsState()
    val unhealthyGroupIds by viewModel.unhealthyGroupIds.collectAsState()
    val error by viewModel.error.collectAsState()

    var showCreateSheet by remember { mutableStateOf(false) }
    var showJoinSheet by remember { mutableStateOf(false) }
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
                            showJoinSheet = true
                        },
                        containerColor = MaterialTheme.colorScheme.secondaryContainer,
                        modifier = Modifier.padding(bottom = 8.dp)
                    ) {
                        Icon(Icons.Default.GroupAdd, contentDescription = "Join Group")
                    }
                    SmallFloatingActionButton(
                        onClick = {
                            showFabMenu = false
                            showCreateSheet = true
                        },
                        containerColor = MaterialTheme.colorScheme.secondaryContainer,
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
        LazyColumn(
            modifier = Modifier.fillMaxSize()
        ) {
                // Pending invites section
                if (pendingInvites.isNotEmpty()) {
                    item {
                        Text(
                            text = "Pending Invites",
                            style = MaterialTheme.typography.titleSmall,
                            color = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.padding(16.dp, 12.dp, 16.dp, 4.dp)
                        )
                    }
                    items(pendingInvites, key = { "pending_${it.groupHint}_${it.inviterNpub}" }) { invite ->
                        ListItem(
                            headlineContent = {
                                Text("Waiting for invite...")
                            },
                            supportingContent = {
                                Text(
                                    "From ${invite.inviterNpub.take(16)}...",
                                    fontSize = 12.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            },
                            trailingContent = {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(20.dp),
                                    strokeWidth = 2.dp
                                )
                            }
                        )
                        HorizontalDivider()
                    }
                }

                // Groups section
                if (groups.isEmpty() && pendingInvites.isEmpty()) {
                    item {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(48.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                Text(
                                    text = "No groups yet",
                                    fontSize = 18.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                                Spacer(modifier = Modifier.height(8.dp))
                                Text(
                                    text = "Create a group or join one with an invite code",
                                    fontSize = 14.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
                                )
                            }
                        }
                    }
                }

                items(groups.filter { it.isActive }, key = { it.id }) { group ->
                    val isUnhealthy = group.id in unhealthyGroupIds

                    ListItem(
                        headlineContent = {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    text = group.name,
                                    fontWeight = if (group.hasUnread) FontWeight.Bold else FontWeight.Normal,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f, fill = false)
                                )
                                if (group.hasUnread) {
                                    Spacer(modifier = Modifier.width(8.dp))
                                    Box(
                                        modifier = Modifier
                                            .size(10.dp)
                                            .background(
                                                color = MaterialTheme.colorScheme.primary,
                                                shape = androidx.compose.foundation.shape.CircleShape
                                            )
                                    )
                                }
                            }
                        },
                        supportingContent = {
                            Text(
                                text = "${group.memberCount} member${if (group.memberCount != 1) "s" else ""}",
                                fontSize = 13.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        },
                        trailingContent = {
                            Column(horizontalAlignment = Alignment.End) {
                                if (group.lastActivity != null) {
                                    Text(
                                        text = formatRelativeTime(group.lastActivity),
                                        fontSize = 12.sp,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                                if (isUnhealthy) {
                                    Text(
                                        text = "Epoch mismatch",
                                        fontSize = 11.sp,
                                        color = MaterialTheme.colorScheme.error
                                    )
                                }
                            }
                        },
                        modifier = Modifier.clickable {
                            viewModel.markAsRead(group.id)
                            onGroupClick(group.id)
                        }
                    )
                    HorizontalDivider()
                }
            }

            PullRefreshIndicator(
                refreshing = isRefreshing,
                state = pullRefreshState,
                modifier = Modifier.align(Alignment.TopCenter)
            )
        }

        // Error display
        if (error != null) {
            LaunchedEffect(error) {
                kotlinx.coroutines.delay(3000)
            }
        }
    }

    // Bottom sheets
    if (showCreateSheet) {
        CreateGroupSheet(
            onDismiss = { showCreateSheet = false },
            onCreate = { name ->
                showCreateSheet = false
                viewModel.createGroup(name)
            }
        )
    }

    if (showJoinSheet) {
        JoinGroupSheet(
            onDismiss = { showJoinSheet = false },
            onJoin = { code ->
                showJoinSheet = false
                viewModel.joinGroup(code)
            },
            onScanQr = {
                showJoinSheet = false
                onScanQr()
            }
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
            sdf.format(Date(epochSeconds * 1000))
        }
    }
}
