package org.findmyfam.ui.groups

import android.Manifest
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.accompanist.permissions.ExperimentalPermissionsApi
import com.google.accompanist.permissions.isGranted
import com.google.accompanist.permissions.rememberPermissionState
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import kotlinx.coroutines.launch
import org.findmyfam.services.MarmotKitService

/**
 * Admin side of the v2 join flow: scan a member's code and invite them.
 *
 * Counterpart to iOS `ScanMemberCodeView`. Replaces the v1 admin-invites flow.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalPermissionsApi::class)
@Composable
fun ScanMemberCodeSheet(
    groupId: String,
    groupName: String,
    marmot: MarmotKitService,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier
) {
    val coroutineScope = rememberCoroutineScope()
    val cameraPermission = rememberPermissionState(Manifest.permission.CAMERA)

    var scanState by remember { mutableStateOf<ScanState>(ScanState.Scanning) }

    fun invite(code: String) {
        if (scanState !is ScanState.Scanning) return
        scanState = ScanState.Inviting
        coroutineScope.launch {
            try {
                marmot.inviteScanned(code, groupId)
                scanState = ScanState.Invited
            } catch (e: MarmotKitService.ServiceError.UnrecognisedMemberCode) {
                scanState = ScanState.NotAMemberCode
            } catch (e: Exception) {
                scanState = ScanState.Failed(e.message ?: "Failed to add member")
            }
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
            val displayName = groupName.ifEmpty { "the group" }

            Text(
                text = "Add Member",
                style = MaterialTheme.typography.titleLarge
            )

            when (val state = scanState) {
                is ScanState.Scanning -> {
                    if (cameraPermission.status.isGranted) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(280.dp)
                                .clip(RoundedCornerShape(16.dp)),
                            contentAlignment = Alignment.Center
                        ) {
                            ScannerPreview(onBarcodeDetected = { invite(it) })
                        }
                    } else {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(200.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center
                        ) {
                            Icon(Icons.Default.QrCodeScanner, contentDescription = null, modifier = Modifier.size(48.dp))
                            Spacer(modifier = Modifier.height(12.dp))
                            Text(
                                text = "Camera access is needed to scan member codes.",
                                style = MaterialTheme.typography.bodyMedium,
                                textAlign = TextAlign.Center
                            )
                            Spacer(modifier = Modifier.height(12.dp))
                            Button(onClick = { cameraPermission.launchPermissionRequest() }) {
                                Text("Grant Camera Access")
                            }
                        }
                    }

                    Text(
                        text = "Scan the code from their Whistle app.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                is ScanState.Inviting -> {
                    Column(
                        modifier = Modifier.padding(vertical = 32.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(16.dp)
                    ) {
                        CircularProgressIndicator()
                        Text(
                            text = "Adding to $displayName…",
                            style = MaterialTheme.typography.titleMedium
                        )
                    }
                }

                is ScanState.Invited -> {
                    Column(
                        modifier = Modifier.padding(vertical = 32.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Icon(
                            Icons.Default.CheckCircle,
                            contentDescription = null,
                            tint = Color(0xFF4CAF50),
                            modifier = Modifier.size(48.dp)
                        )
                        Text(
                            text = "Added to $displayName",
                            style = MaterialTheme.typography.titleMedium
                        )
                        Text(
                            text = "They'll see the group once their device catches up.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        Button(onClick = onDismiss) {
                            Text("Done")
                        }
                    }
                }

                is ScanState.NotAMemberCode -> {
                    Column(
                        modifier = Modifier.padding(vertical = 32.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Icon(
                            Icons.Default.Warning,
                            contentDescription = null,
                            tint = Color(0xFFFF9800),
                            modifier = Modifier.size(48.dp)
                        )
                        Text(
                            text = "That's not a member code",
                            style = MaterialTheme.typography.titleMedium
                        )
                        Text(
                            text = "Ask them to open Whistle and show their own code, then scan again.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        OutlinedButton(onClick = { scanState = ScanState.Scanning }) {
                            Text("Scan again")
                        }
                    }
                }

                is ScanState.Failed -> {
                    Column(
                        modifier = Modifier.padding(vertical = 32.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Icon(
                            Icons.Default.Error,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.error,
                            modifier = Modifier.size(48.dp)
                        )
                        Text(
                            text = "Couldn't add them",
                            style = MaterialTheme.typography.titleMedium
                        )
                        Text(
                            text = state.message,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        OutlinedButton(onClick = { scanState = ScanState.Scanning }) {
                            Text("Scan again")
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(16.dp))
        }
    }
}

private sealed class ScanState {
    object Scanning : ScanState()
    object Inviting : ScanState()
    object Invited : ScanState()
    object NotAMemberCode : ScanState()
    data class Failed(val message: String) : ScanState()
}

@Composable
private fun ScannerPreview(
    onBarcodeDetected: (String) -> Unit
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var hasDetected by remember { mutableStateOf(false) }

    AndroidView(
        factory = { ctx ->
            val previewView = PreviewView(ctx)
            val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)

            cameraProviderFuture.addListener({
                val cameraProvider = cameraProviderFuture.get()
                val preview = Preview.Builder().build().also {
                    it.surfaceProvider = previewView.surfaceProvider
                }

                val scanner = BarcodeScanning.getClient()

                @androidx.camera.core.ExperimentalGetImage
                val analysis = ImageAnalysis.Builder()
                    .setTargetResolution(Size(1280, 720))
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                    .also { imageAnalysis ->
                        imageAnalysis.setAnalyzer(ContextCompat.getMainExecutor(ctx)) { imageProxy ->
                            val mediaImage = imageProxy.image
                            if (mediaImage != null && !hasDetected) {
                                val inputImage = InputImage.fromMediaImage(
                                    mediaImage,
                                    imageProxy.imageInfo.rotationDegrees
                                )
                                scanner.process(inputImage)
                                    .addOnSuccessListener { barcodes ->
                                        for (barcode in barcodes) {
                                            if (barcode.format == Barcode.FORMAT_QR_CODE) {
                                                barcode.rawValue?.let { value ->
                                                    if (!hasDetected) {
                                                        hasDetected = true
                                                        onBarcodeDetected(value)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .addOnCompleteListener {
                                        imageProxy.close()
                                    }
                            } else {
                                imageProxy.close()
                            }
                        }
                    }

                try {
                    cameraProvider.unbindAll()
                    cameraProvider.bindToLifecycle(
                        lifecycleOwner,
                        CameraSelector.DEFAULT_BACK_CAMERA,
                        preview,
                        analysis
                    )
                } catch (_: Exception) {}
            }, ContextCompat.getMainExecutor(ctx))

            previewView
        },
        modifier = Modifier.fillMaxSize()
    )
}
