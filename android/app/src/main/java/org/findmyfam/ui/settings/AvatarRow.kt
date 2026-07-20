package org.findmyfam.ui.settings

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.findmyfam.services.MemberAvatarStore
import org.findmyfam.shared.models.MemberAvatarFallback

/** Palette mirroring the iOS MemberAvatarView colours, in the same order. */
private val INITIALS_PALETTE = listOf(
    Color(0xFF007AFF), Color(0xFFAF52DE), Color(0xFFFF2D55), Color(0xFFFF9500),
    Color(0xFF30B0C7), Color(0xFF5856D6), Color(0xFF34C759), Color(0xFFA2845E)
)

private val AVATAR_SIZE = 36.dp

/**
 * Picker for the user's own avatar, shown to every member of every group.
 *
 * Uses the photo picker rather than a storage permission — it hands back a
 * single image without the app ever gaining access to the whole gallery.
 */
@Composable
fun AvatarRow(
    store: MemberAvatarStore,
    pubkeyHex: String?,
    displayName: String,
    onPicked: (Uri) -> Unit,
    onRemoved: () -> Unit
) {
    // Read through the revision flow so the row recomposes when the stored
    // image changes — the store hands out plain Bitmaps, not state.
    val revision by store.revision.collectAsState()
    val bitmap = pubkeyHex?.let {
        @Suppress("UNUSED_EXPRESSION") revision
        store.image(it)
    }

    var showOptions by remember { mutableStateOf(false) }

    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri -> uri?.let(onPicked) }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            // Tapping opens a menu rather than jumping straight into the
            // gallery, and removal lives there instead of as a cramped inline
            // link next to the thumbnail. Mirrors the iOS confirmation dialog.
            .clickable { showOptions = true }
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = Icons.Default.Person,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary
        )
        Spacer(modifier = Modifier.width(16.dp))
        Text("Photo", style = MaterialTheme.typography.bodyLarge)

        Spacer(modifier = Modifier.weight(1f))

        if (bitmap != null) {
            Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = "Your avatar",
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(AVATAR_SIZE)
                    .clip(CircleShape)
            )
        } else if (pubkeyHex != null) {
            // Initials fallback — the normal state for a member with no photo,
            // not an error state.
            Box(
                modifier = Modifier
                    .size(AVATAR_SIZE)
                    .clip(CircleShape)
                    .background(INITIALS_PALETTE[MemberAvatarFallback.colorIndex(pubkeyHex)]),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = MemberAvatarFallback.initials(displayName),
                    color = Color.White,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold
                )
            }
        }
    }

    if (showOptions) {
        AlertDialog(
            onDismissRequest = { showOptions = false },
            title = { Text("Your Photo") },
            text = { Text("Shared with everyone in your groups.") },
            confirmButton = {
                TextButton(onClick = {
                    showOptions = false
                    launcher.launch(
                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                    )
                }) {
                    Text(if (bitmap == null) "Choose Photo" else "Change Photo")
                }
            },
            dismissButton = {
                if (bitmap != null) {
                    TextButton(onClick = {
                        showOptions = false
                        onRemoved()
                    }) {
                        Text("Remove Photo")
                    }
                }
            }
        )
    }
}
