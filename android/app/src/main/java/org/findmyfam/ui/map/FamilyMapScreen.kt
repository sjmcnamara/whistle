package org.findmyfam.ui.map

import android.Manifest
import android.content.Context
import android.os.Build
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import android.util.TypedValue
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.ColorDrawable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.MutableState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Warning
import com.google.accompanist.permissions.ExperimentalPermissionsApi
import com.google.accompanist.permissions.isGranted
import com.google.accompanist.permissions.rememberMultiplePermissionsState
import com.google.accompanist.permissions.rememberPermissionState
import org.osmdroid.config.Configuration
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker
import org.findmyfam.viewmodels.AppViewModel
import org.findmyfam.viewmodels.LocationViewModel
import org.findmyfam.viewmodels.MemberAnnotation
import java.text.SimpleDateFormat
import java.util.*

data class GroupOption(val id: String, val name: String)

@OptIn(ExperimentalPermissionsApi::class, ExperimentalMaterial3Api::class)
@Composable
fun FamilyMapScreen(
    locationViewModel: LocationViewModel,
    groups: List<GroupOption> = emptyList(),
    onPermissionGranted: () -> Unit,
    whistleState: AppViewModel.WhistleState = AppViewModel.WhistleState.IDLE,
    onWhistle: () -> Unit = {},
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

    // Request notification permission on Android 13+ (non-blocking, no UI gate)
    val notificationPermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        rememberPermissionState(Manifest.permission.POST_NOTIFICATIONS)
    } else {
        null
    }

    // Configure osmdroid user agent + notify if permission already granted
    LaunchedEffect(Unit) {
        Configuration.getInstance().userAgentValue = context.packageName
        if (locationPermissions.allPermissionsGranted) {
            onPermissionGranted()
        }
        notificationPermission?.let {
            if (!it.status.isGranted) it.launchPermissionRequest()
        }
    }

    // Clear group filter if the selected group is no longer in the active list
    LaunchedEffect(groups) {
        locationViewModel.clearFilterIfInvalid(groups.map { it.id }.toSet())
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
                    text = "Whistle needs location access to share your position with your family group.",
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
            val mapViewRef = remember { mutableStateOf<MapView?>(null) }
            var selectedAnnotation by remember { mutableStateOf<MemberAnnotation?>(null) }
            OsmMapView(
                annotations = annotations,
                mapViewRef = mapViewRef,
                onMarkerTap = { selectedAnnotation = it }
            )

            selectedAnnotation?.let { ann ->
                MemberDetailSheet(annotation = ann, onDismiss = { selectedAnnotation = null })
            }

            // Group filter picker
            if (groups.isNotEmpty()) {
                val selectedGroupId by locationViewModel.selectedGroupId.collectAsState()
                var expanded by remember { mutableStateOf(false) }
                val selectedLabel = if (selectedGroupId == null) "All Groups"
                    else groups.find { it.id == selectedGroupId }?.name ?: "All Groups"

                Box(
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(12.dp)
                ) {
                    FilterChip(
                        selected = selectedGroupId != null,
                        onClick = { expanded = true },
                        label = { Text(selectedLabel) },
                        leadingIcon = {
                            Icon(
                                painter = androidx.compose.ui.res.painterResource(
                                    id = android.R.drawable.ic_menu_sort_by_size
                                ),
                                contentDescription = null,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    )
                    DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                        DropdownMenuItem(
                            text = { Text("All Groups") },
                            onClick = {
                                locationViewModel.selectGroup(null)
                                expanded = false
                            },
                            trailingIcon = {
                                if (selectedGroupId == null)
                                    Icon(
                                        imageVector = Icons.Default.Check,
                                        contentDescription = null
                                    )
                            }
                        )
                        HorizontalDivider()
                        groups.forEach { group ->
                            DropdownMenuItem(
                                text = { Text(group.name.ifEmpty { "Unnamed Group" }) },
                                onClick = {
                                    locationViewModel.selectGroup(group.id)
                                    expanded = false
                                },
                                trailingIcon = {
                                    if (selectedGroupId == group.id)
                                        Icon(
                                            imageVector = Icons.Default.Check,
                                            contentDescription = null
                                        )
                                }
                            )
                        }
                    }
                }
            }

            // Find me button
            val myAnnotation = annotations.find { it.isMe }
            if (myAnnotation != null) {
                SmallFloatingActionButton(
                    onClick = {
                        mapViewRef.value?.let { map ->
                            map.controller.animateTo(
                                GeoPoint(myAnnotation.position.latitude, myAnnotation.position.longitude),
                                18.0, 500L
                            )
                        }
                    },
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .padding(16.dp),
                    containerColor = MaterialTheme.colorScheme.primaryContainer
                ) {
                    Icon(
                        Icons.Default.MyLocation,
                        contentDescription = "Find me",
                        tint = MaterialTheme.colorScheme.onPrimaryContainer
                    )
                }
            }

            // Whistle button — force a location publish now, ignoring throttle,
            // motion backoff, and pause state (see AppViewModel.whistle()).
            ExtendedFloatingActionButton(
                onClick = onWhistle,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 24.dp),
                containerColor = if (whistleState == AppViewModel.WhistleState.FAILED)
                    MaterialTheme.colorScheme.errorContainer
                else MaterialTheme.colorScheme.primary,
                icon = {
                    when (whistleState) {
                        AppViewModel.WhistleState.SENDING ->
                            CircularProgressIndicator(
                                modifier = Modifier.size(20.dp),
                                strokeWidth = 2.dp,
                                color = MaterialTheme.colorScheme.onPrimary
                            )
                        AppViewModel.WhistleState.SENT ->
                            Icon(Icons.Default.Check, contentDescription = null)
                        AppViewModel.WhistleState.FAILED ->
                            Icon(Icons.Default.Warning, contentDescription = null)
                        AppViewModel.WhistleState.IDLE ->
                            Icon(Icons.Default.Sensors, contentDescription = null)
                    }
                },
                text = {
                    Text(
                        when (whistleState) {
                            AppViewModel.WhistleState.SENDING -> "Whistling…"
                            AppViewModel.WhistleState.SENT -> "Sent"
                            AppViewModel.WhistleState.FAILED -> "No fix"
                            AppViewModel.WhistleState.IDLE -> "Whistle"
                        }
                    )
                }
            )

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

/**
 * Renders a member pin matching iOS's MemberPinView: a white-ringed avatar
 * circle with a person glyph (blue fresh, grey stale), the display name
 * below with a white halo, and an orange stationary badge top-right.
 *
 * The bitmap is vertically centred on the avatar circle so the marker can
 * use ANCHOR_CENTER and the avatar sits exactly on the geo position.
 */
private fun memberPinDrawable(
    context: Context,
    name: String,
    isStale: Boolean,
    isStationary: Boolean
): BitmapDrawable {
    val dm = context.resources.displayMetrics
    val dp = dm.density
    val avatar = 38f * dp
    val badge = 16f * dp
    val gap = 2f * dp
    val halo = 3f * dp

    val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 11f, dm)
        typeface = Typeface.DEFAULT_BOLD
        textAlign = Paint.Align.CENTER
    }
    val fm = textPaint.fontMetrics
    val textHeight = fm.descent - fm.ascent
    // Space below the avatar for the label; mirrored above to keep the
    // avatar at the bitmap's vertical centre.
    val below = gap + textHeight + halo

    val width = maxOf(avatar + badge, textPaint.measureText(name) + 2 * halo).toInt() + 1
    val height = (avatar + 2 * below).toInt() + 1
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val cx = width / 2f
    val cy = height / 2f
    val r = avatar / 2f

    val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }

    // White ring + tinted disc
    fill.color = Color.WHITE
    canvas.drawCircle(cx, cy, r, fill)
    fill.color = if (isStale) 0xFF8E8E93.toInt() else 0xFF007AFF.toInt()
    val inner = r - 1.5f * dp
    canvas.drawCircle(cx, cy, inner, fill)

    // Person glyph: head + shoulders, clipped to the disc
    fill.color = Color.WHITE
    canvas.save()
    canvas.clipPath(Path().apply { addCircle(cx, cy, inner, Path.Direction.CW) })
    canvas.drawCircle(cx, cy - 0.30f * inner, 0.32f * inner, fill)
    canvas.drawCircle(cx, cy + 0.85f * inner, 0.62f * inner, fill)
    canvas.restore()

    if (isStationary) {
        val bx = cx + r - badge / 3f
        val by = cy - r + badge / 3f
        fill.color = 0xFFFF8C00.toInt()
        canvas.drawCircle(bx, by, badge / 2f, fill)
        val badgePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = badge * 0.6f
            textAlign = Paint.Align.CENTER
        }
        val bm = badgePaint.fontMetrics
        canvas.drawText("🧍", bx, by - (bm.ascent + bm.descent) / 2f, badgePaint)
    }

    // Name label with a white halo so it stays readable over map tiles
    val textY = cy + r + gap - fm.ascent
    textPaint.style = Paint.Style.STROKE
    textPaint.strokeWidth = halo
    textPaint.color = Color.WHITE
    canvas.drawText(name, cx, textY, textPaint)
    textPaint.style = Paint.Style.FILL
    textPaint.color = if (isStale) 0xFF6E6E73.toInt() else 0xFF1C1C1E.toInt()
    canvas.drawText(name, cx, textY, textPaint)

    return BitmapDrawable(context.resources, bitmap)
}

@Composable
private fun OsmMapView(
    annotations: List<MemberAnnotation>,
    mapViewRef: MutableState<MapView?> = mutableStateOf(null),
    onMarkerTap: (MemberAnnotation) -> Unit = {}
) {
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
                mapViewRef.value = this
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
                    icon = memberPinDrawable(
                        mapView.context, ann.displayName, ann.isStale, ann.isStationary
                    )
                    setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                    alpha = if (ann.isStale) 0.5f else 1.0f
                    setOnMarkerClickListener { _, _ ->
                        onMarkerTap(ann)
                        true   // suppress default info window
                    }
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
