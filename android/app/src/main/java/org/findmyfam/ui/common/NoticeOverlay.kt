package org.findmyfam.ui.common

import androidx.compose.animation.*
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.findmyfam.services.NoticeCenter

/**
 * Renders [NoticeCenter]'s two tiers over whatever tab or screen is showing.
 *
 * Attached once in [RootScreen] rather than per screen, mirroring iOS's
 * `NoticeOverlay`. That is the point: a failure raised by the background
 * receive loop has nowhere to go on a per-screen model, and a stalled account
 * stops location sharing, so its banner must be visible on the Map tab as well
 * as in Groups.
 */
@Composable
fun NoticeOverlay(
    notices: NoticeCenter,
    modifier: Modifier = Modifier,
) {
    val banners by notices.banners.collectAsState()
    val toasts by notices.toasts.collectAsState()
    val coroutineScope = rememberCoroutineScope()

    Box(
        modifier = modifier
            .fillMaxSize()
            .statusBarsPadding()
    ) {
        // Banners (top, persistent, dismissible)
        Column(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .fillMaxWidth()
                .padding(top = 8.dp, start = 12.dp, end = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            banners.forEach { banner ->
                key(banner.cause) {
                    NoticeCard(
                        accent = Color(0xFFFF9800), // Orange
                        icon = Icons.Default.Warning,
                        message = banner.message,
                        actionTitle = banner.actionTitle,
                        onAction = banner.action?.let { action ->
                            { coroutineScope.launch { action() } }
                        },
                        onDismiss = { notices.dismissBanner(banner.cause) }
                    )
                }
            }
        }

        // Toasts (bottom, transient, tap to dismiss)
        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(bottom = 80.dp, start = 12.dp, end = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            toasts.forEach { toast ->
                key(toast.id) {
                    NoticeCard(
                        accent = MaterialTheme.colorScheme.error,
                        icon = Icons.Default.Error,
                        message = toast.message,
                        actionTitle = if (toast.retry != null) "Retry" else null,
                        onAction = toast.retry?.let { retry ->
                            {
                                notices.dismissToast(toast.id)
                                coroutineScope.launch { retry() }
                            }
                        },
                        onCardClick = { notices.dismissToast(toast.id) },
                        onDismiss = null
                    )
                }
            }
        }
    }
}

@Composable
private fun NoticeCard(
    accent: Color,
    icon: ImageVector,
    message: String,
    actionTitle: String?,
    onAction: (() -> Unit)?,
    modifier: Modifier = Modifier,
    onCardClick: (() -> Unit)? = null,
    onDismiss: (() -> Unit)? = null,
) {
    Card(
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.95f)
        ),
        elevation = CardDefaults.cardElevation(defaultElevation = 6.dp),
        modifier = modifier
            .fillMaxWidth()
            .then(if (onCardClick != null) Modifier.clickable { onCardClick() } else Modifier)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            // Accent bar
            Box(
                modifier = Modifier
                    .width(4.dp)
                    .height(28.dp)
                    .clip(CircleShape)
                    .background(accent)
            )

            // Icon
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(20.dp)
            )

            // Message and action
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Text(
                    text = message,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                if (actionTitle != null && onAction != null) {
                    TextButton(
                        onClick = onAction,
                        contentPadding = PaddingValues(0.dp),
                        modifier = Modifier.height(28.dp)
                    ) {
                        Text(
                            text = actionTitle,
                            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                            color = MaterialTheme.colorScheme.primary
                        )
                    }
                }
            }

            // Dismiss button
            if (onDismiss != null) {
                IconButton(
                    onClick = onDismiss,
                    modifier = Modifier.size(24.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.Close,
                        contentDescription = "Dismiss",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                        modifier = Modifier.size(18.dp)
                    )
                }
            }
        }
    }
}
