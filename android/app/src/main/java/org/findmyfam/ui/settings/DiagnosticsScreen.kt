package org.findmyfam.ui.settings

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import org.findmyfam.services.DiagnosticsCollector
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Shows the diagnostics report and offers to copy or share it.
 *
 * The report is displayed in full rather than hidden behind a share button.
 * It is meant to be pasteable into a public issue, so the user should be able
 * to read exactly what they are about to send — a diagnostics blob you cannot
 * inspect is one you should not trust.
 */
@Composable
fun DiagnosticsScreen(
    collector: DiagnosticsCollector,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    var json by remember { mutableStateOf<String?>(null) }
    var copied by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        json = runCatching { collector.collect().toJson() }.getOrNull()
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp)
    ) {
        Text(
            "A snapshot of this device's app and group state. It contains no messages, " +
                "no locations, and no names — public keys and group IDs are shortened. " +
                "Safe to share.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        val report = json
        if (report == null) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                horizontalArrangement = Arrangement.Center
            ) {
                CircularProgressIndicator()
            }
            return@Column
        }

        Row(
            modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Button(onClick = {
                copyToClipboard(context, report)
                copied = true
            }) {
                Icon(Icons.Default.ContentCopy, contentDescription = null)
                Text(if (copied) "  Copied" else "  Copy")
            }
            OutlinedButton(onClick = { shareAsFile(context, report) }) {
                Icon(Icons.Default.Share, contentDescription = null)
                Text("  Share File")
            }
        }

        // Horizontally scrollable: JSON lines are long and wrapping monospace
        // text destroys the alignment that makes two reports diffable by eye.
        Text(
            report,
            fontFamily = FontFamily.Monospace,
            fontSize = 11.sp,
            modifier = Modifier.horizontalScroll(rememberScrollState())
        )
    }
}

private fun copyToClipboard(context: Context, text: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newPlainText("Whistle diagnostics", text))
}

/**
 * Write to cache and share via FileProvider. Named with the date so two
 * reports from the same device do not overwrite each other for the recipient.
 */
private fun shareAsFile(context: Context, text: String) {
    val stamp = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }.format(Date())
    val dir = File(context.cacheDir, "diagnostics").also { it.mkdirs() }
    val file = File(dir, "whistle-diagnostics-$stamp.json")
    file.writeText(text)

    val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
    val intent = Intent(Intent.ACTION_SEND).apply {
        type = "application/json"
        putExtra(Intent.EXTRA_STREAM, uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    context.startActivity(Intent.createChooser(intent, "Share diagnostics"))
}
