package org.findmyfam.ui.map

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccessTime
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.findmyfam.shared.models.MemberAvatarFallback
import org.findmyfam.viewmodels.MemberAnnotation
import java.util.concurrent.TimeUnit
import kotlin.math.max

/**
 * Bottom sheet shown when tapping a member pin on the map.
 *
 * Surfaces the publisher's update cadence (carried in `LocationPayload.interval`
 * since v1.2.1) and a local-clock "last seen" so users can answer
 * "why is mom's pin always grey?" without crowding the map.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MemberDetailSheet(
    annotation: MemberAnnotation,
    avatarBitmap: Bitmap? = null,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState()
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 8.dp)
                .padding(bottom = 24.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                MemberAvatarHeader(
                    pubkeyHex = annotation.memberPubkeyHex,
                    displayName = annotation.displayName,
                    bitmap = avatarBitmap,
                    isStale = annotation.isStale
                )
                Spacer(modifier = Modifier.width(12.dp))
                Column {
                    Text(
                        text = annotation.displayName,
                        fontSize = 20.sp,
                        fontWeight = FontWeight.SemiBold
                    )
                    if (annotation.isMe) {
                        Text(
                            text = "You",
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.size(14.dp))
            HorizontalDivider()
            Spacer(modifier = Modifier.size(14.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = Icons.Default.AccessTime,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(18.dp)
                )
                Spacer(modifier = Modifier.width(10.dp))
                Text(
                    text = "Last seen",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 14.sp
                )
                Spacer(modifier = Modifier.weight(1f))
                Text(
                    text = formatRelativeAge(annotation.timestampMs),
                    fontSize = 14.sp
                )
            }

            Spacer(modifier = Modifier.size(10.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = Icons.Default.Refresh,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(18.dp)
                )
                Spacer(modifier = Modifier.width(10.dp))
                Text(
                    text = "Publishes",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 14.sp
                )
                Spacer(modifier = Modifier.weight(1f))
                Text(
                    text = annotation.intervalSeconds?.let { "every ${formatCadence(it)}" } ?: "Unknown",
                    fontSize = 14.sp
                )
            }

            if (annotation.isStationary == true) {
                Spacer(modifier = Modifier.size(10.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "🧍",
                        fontSize = 16.sp
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "Motion",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 14.sp
                    )
                    Spacer(modifier = Modifier.weight(1f))
                    Text(
                        text = "Currently stationary",
                        fontSize = 14.sp
                    )
                }
            }
        }
    }
}

private fun formatRelativeAge(timestampMs: Long): String {
    val deltaSeconds = max(0L, (System.currentTimeMillis() - timestampMs) / 1000)
    return when {
        deltaSeconds < 60 -> "${deltaSeconds}s ago"
        deltaSeconds < 3600 -> "${TimeUnit.SECONDS.toMinutes(deltaSeconds)} min ago"
        deltaSeconds < 86_400 -> "${TimeUnit.SECONDS.toHours(deltaSeconds)} hr ago"
        else -> "${TimeUnit.SECONDS.toDays(deltaSeconds)} d ago"
    }
}

/**
 * Renders a seconds count as a short human-readable cadence
 * (e.g. `10` → "10 sec", `3600` → "1 hour", `5400` → "1 hr 30 min").
 */
internal fun formatCadence(seconds: Int): String {
    if (seconds < 60) return "$seconds sec"
    if (seconds < 3600) return "${seconds / 60} min"
    val hours = seconds / 3600
    val remMinutes = (seconds % 3600) / 60
    if (remMinutes == 0) return if (hours == 1) "1 hour" else "$hours hours"
    return "$hours hr $remMinutes min"
}

/**
 * The member's avatar for the detail-sheet header: their shared photo if we
 * have one, otherwise the same initials-in-a-coloured-circle fallback the map
 * pin uses ([INITIALS_PALETTE] + [MemberAvatarFallback]). Dimmed when stale,
 * mirroring the pin's grey treatment.
 */
@Composable
private fun MemberAvatarHeader(
    pubkeyHex: String,
    displayName: String,
    bitmap: Bitmap?,
    isStale: Boolean
) {
    val diameter = 44.dp
    val staleAlpha = if (isStale) 0.5f else 1f
    if (bitmap != null) {
        Image(
            bitmap = bitmap.asImageBitmap(),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(diameter)
                .clip(CircleShape)
                .alpha(staleAlpha)
        )
    } else {
        val color = if (isStale) {
            Color.Gray
        } else {
            Color(INITIALS_PALETTE[MemberAvatarFallback.colorIndex(pubkeyHex)])
        }
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(diameter)
                .clip(CircleShape)
                .background(color)
        ) {
            Text(
                text = MemberAvatarFallback.initials(displayName),
                color = Color.White,
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold
            )
        }
    }
}
