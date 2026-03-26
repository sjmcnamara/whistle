package org.findmyfam.ui.map

import android.Manifest
import android.graphics.Color
import android.graphics.Paint
import android.graphics.drawable.ColorDrawable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.google.accompanist.permissions.ExperimentalPermissionsApi
import com.google.accompanist.permissions.rememberMultiplePermissionsState
import org.osmdroid.config.Configuration
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker
import org.findmyfam.viewmodels.LocationViewModel
import org.findmyfam.viewmodels.MemberAnnotation
import java.text.SimpleDateFormat
import java.util.*

@OptIn(ExperimentalPermissionsApi::class)
@Composable
fun FamilyMapScreen(
    locationViewModel: LocationViewModel,
    onPermissionGranted: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val annotations by locationViewModel.annotations.collectAsState()

    val locationPermissions = rememberMultiplePermissionsState(
        permissions = listOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION
        )
    ) { results ->
        if (results.values.any { it }) {
            onPermissionGranted()
        }
    }

    // Configure osmdroid user agent + notify if permission already granted
    LaunchedEffect(Unit) {
        Configuration.getInstance().userAgentValue = context.packageName
        if (locationPermissions.allPermissionsGranted) {
            onPermissionGranted()
        }
    }

    Box(modifier = modifier.fillMaxSize()) {
        if (!locationPermissions.allPermissionsGranted) {
            // Permission request
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                Text(
                    text = "Location Permission",
                    style = MaterialTheme.typography.headlineSmall
                )
                Spacer(modifier = Modifier.height(12.dp))
                Text(
                    text = "Famstr needs location access to share your position with your family group.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center
                )
                Spacer(modifier = Modifier.height(24.dp))
                Button(onClick = { locationPermissions.launchMultiplePermissionRequest() }) {
                    Text("Grant Location Access")
                }
            }
        } else {
            // OSM Map
            OsmMapView(annotations = annotations)

            // Empty state overlay
            if (annotations.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp)
                        .align(Alignment.TopCenter)
                ) {
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        colors = CardDefaults.cardColors(
                            containerColor = MaterialTheme.colorScheme.surfaceVariant
                        )
                    ) {
                        Text(
                            text = "No family locations yet. Locations will appear as group members share their positions.",
                            modifier = Modifier.padding(16.dp),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun OsmMapView(annotations: List<MemberAnnotation>) {
    val timeFormat = remember { SimpleDateFormat("h:mm a", Locale.getDefault()) }
    // Only auto-fit camera on first annotation load, not on every update
    var hasFittedCamera by remember { mutableStateOf(false) }

    AndroidView(
        factory = { ctx ->
            MapView(ctx).apply {
                setTileSource(TileSourceFactory.MAPNIK)
                setMultiTouchControls(true)
                controller.setZoom(4.0)
                controller.setCenter(GeoPoint(39.8283, -98.5795))
            }
        },
        update = { mapView ->
            // Update markers without touching the camera
            mapView.overlays.removeAll { it is Marker }

            for (ann in annotations) {
                val marker = Marker(mapView).apply {
                    position = GeoPoint(ann.position.latitude, ann.position.longitude)
                    title = ann.displayName
                    snippet = if (ann.isMe) "You • ${timeFormat.format(Date(ann.timestampMs))}"
                              else timeFormat.format(Date(ann.timestampMs))
                    setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_BOTTOM)
                    alpha = if (ann.isStale) 0.5f else 1.0f
                }
                mapView.overlays.add(marker)
            }

            // Fit camera only once when first annotations arrive
            if (annotations.isNotEmpty() && !hasFittedCamera) {
                hasFittedCamera = true
                if (annotations.size == 1) {
                    mapView.controller.setZoom(14.0)
                    mapView.controller.setCenter(
                        GeoPoint(annotations[0].position.latitude, annotations[0].position.longitude)
                    )
                } else {
                    var minLat = annotations[0].position.latitude
                    var maxLat = minLat
                    var minLon = annotations[0].position.longitude
                    var maxLon = minLon
                    for (ann in annotations) {
                        minLat = minOf(minLat, ann.position.latitude)
                        maxLat = maxOf(maxLat, ann.position.latitude)
                        minLon = minOf(minLon, ann.position.longitude)
                        maxLon = maxOf(maxLon, ann.position.longitude)
                    }
                    mapView.controller.setCenter(GeoPoint((minLat + maxLat) / 2, (minLon + maxLon) / 2))
                    mapView.controller.setZoom(12.0)
                }
            }

            mapView.invalidate()
        },
        modifier = Modifier.fillMaxSize()
    )
}
