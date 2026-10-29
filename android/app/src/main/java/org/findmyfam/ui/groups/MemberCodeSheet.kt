package org.findmyfam.ui.groups

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import org.findmyfam.services.MarmotKitService
import org.findmyfam.ui.common.QrCodeImage

/**
 * The code a prospective member shows so an admin can add them.
 *
 * Counterpart to iOS `MemberCodeView`. Replaces the v1 invite flow. Protocol
 * v2 has no out-of-group messaging, so a non-member cannot act on anything
 * they scan — which makes the old admin-shows-a-group-QR direction useless.
 * Only this direction survives: the member displays, the admin scans.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MemberCodeSheet(
    marmot: MarmotKitService,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    var isReady by remember { mutableStateOf(marmot.isReadyToBeInvited()) }
    var code by remember { mutableStateOf(marmot.myMemberCode()) }
    var copied by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        while (true) {
            code = marmot.myMemberCode()
            if (marmot.isReadyToBeInvited()) {
                isReady = true
                code = marmot.myMemberCode()
                break
            }
            delay(500)
        }
    }

    LaunchedEffect(copied) {
        if (copied) {
            delay(2000)
            copied = false
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        modifier = modifier
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp, vertical = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text(
                text = "My Code",
                style = MaterialTheme.typography.titleLarge
            )

            Text(
                text = "Show this to a group admin. They'll scan it to add you.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )

            if (isReady && code != null) {
                // White card background for high contrast in dark mode
                Box(
                    modifier = Modifier
                        .padding(vertical = 8.dp)
                        .background(Color.White, RoundedCornerShape(16.dp))
                        .padding(16.dp),
                    contentAlignment = Alignment.Center
                ) {
                    QrCodeImage(
                        content = code!!,
                        size = 200.dp
                    )
                }

                FilledTonalButton(
                    onClick = {
                        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        clipboard.setPrimaryClip(ClipData.newPlainText("Whistle Member Code", code))
                        copied = true
                    }
                ) {
                    Icon(
                        imageVector = if (copied) Icons.Default.Check else Icons.Default.ContentCopy,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(if (copied) "Copied to clipboard" else "Copy code")
                }

                Text(
                    text = code!!,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(horizontal = 16.dp)
                )
            } else {
                Column(
                    modifier = Modifier.padding(vertical = 32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    CircularProgressIndicator()
                    Text(
                        text = "Publishing your key…",
                        style = MaterialTheme.typography.titleMedium
                    )
                    Text(
                        text = "Your code isn't ready to scan yet. This usually takes a moment.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center
                    )
                }
            }

            Spacer(modifier = Modifier.height(16.dp))
        }
    }
}
