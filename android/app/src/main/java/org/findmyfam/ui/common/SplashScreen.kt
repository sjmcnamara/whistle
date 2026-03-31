package org.findmyfam.ui.common

import androidx.compose.animation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.findmyfam.viewmodels.AppViewModel.StartupPhase

@Composable
fun SplashScreen(phase: StartupPhase) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Text(
                text = "whistle",
                fontSize = 36.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.primary
            )

            Spacer(modifier = Modifier.height(8.dp))

            Text(
                text = "family, anywhere",
                fontSize = 14.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(modifier = Modifier.height(32.dp))

            CircularProgressIndicator(
                modifier = Modifier.size(24.dp),
                strokeWidth = 2.dp
            )

            Spacer(modifier = Modifier.height(12.dp))

            val statusText = when (phase) {
                StartupPhase.SPLASH -> "Starting…"
                StartupPhase.CONNECTING -> "Connecting to relays…"
                StartupPhase.INITIALISING_ENCRYPTION -> "Initialising encryption…"
                StartupPhase.LOADING_GROUPS -> "Loading groups…"
                StartupPhase.READY -> "Ready"
            }

            Text(
                text = statusText,
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
