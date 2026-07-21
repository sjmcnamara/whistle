package org.findmyfam.ui.map

import android.Manifest
import android.content.Context
import android.os.Build
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.util.TypedValue
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.ColorDrawable
import org.findmyfam.shared.models.MemberAvatarFallback
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
import androidx.compose.material.icons.filled.Podcasts
import androidx.compose.material.icons.filled.Warning
import com.google.accompanist.permissions.ExperimentalPermissionsApi
import com.google.accompanist.permissions.isGranted
import com.google.accompanist.permissions.rememberMultiplePermissionsState
import com.google.accompanist.permissions.rememberPermissionState
import kotlinx.coroutines.delay
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

/** Mirrors the iOS MemberAvatarView palette, in the same order. */
internal val INITIALS_PALETTE = intArrayOf(
    0xFF007AFF.toInt(), // blue
    0xFFAF52DE.toInt(), // purple
    0xFFFF2D55.toInt(), // pink
    0xFFFF9500.toInt(), // orange
    0xFF30B0C7.toInt(), // teal
    0xFF5856D6.toInt(), // indigo
    0xFF34C759.toInt(), // green
    0xFFA2845E.toInt()  // brown
)

@OptIn(ExperimentalPermissionsApi::class, ExperimentalMaterial3Api::class)
@Composable
fun MapScreen(
    locationViewModel: LocationViewModel,
    groups: List<GroupOption> = emptyList(),
    onPermissionGranted: () -> Unit,
    whistleState: AppViewModel.WhistleState = AppViewModel.WhistleState.IDLE,
    onWhistle: () -> Unit = {},
    avatarFor: (String) -> Bitmap? = { null },
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
                onMarkerTap = { selectedAnnotation = it },
                avatarFor = avatarFor
            )

            selectedAnnotation?.let { ann ->
                MemberDetailSheet(
                    annotation = ann,
                    avatarBitmap = avatarFor(ann.memberPubkeyHex),
                    onDismiss = { selectedAnnotation = null }
                )
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
            FloatingActionButton(
                onClick = onWhistle,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 24.dp),
                containerColor = if (whistleState == AppViewModel.WhistleState.FAILED)
                    MaterialTheme.colorScheme.errorContainer
                else MaterialTheme.colorScheme.primary,
            ) {
                when (whistleState) {
                    AppViewModel.WhistleState.SENDING ->
                        CircularProgressIndicator(
                            modifier = Modifier.size(24.dp),
                            strokeWidth = 2.dp,
                            color = MaterialTheme.colorScheme.onPrimary
                        )
                    AppViewModel.WhistleState.SENT ->
                        Icon(Icons.Default.Check, contentDescription = "Sent")
                    AppViewModel.WhistleState.FAILED ->
                        Icon(Icons.Default.Warning, contentDescription = "No fix")
                    AppViewModel.WhistleState.IDLE ->
                        Icon(Icons.Default.Podcasts, contentDescription = "Whistle")
                }
            }

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
                            text = "No locations yet. Locations will appear as group members share their positions.",
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
 * circle with a person glyph (blue fresh, grey stale), the display name and a
 * staleness counter below (each with a white halo), and an orange stationary
 * badge top-right.
 *
 * `counter` is the relative-time line under the name — count-up "2 min ago" for
 * other members, count-down "in 30s" for the own pin — matching iOS. Pass null
 * to omit it.
 *
 * The bitmap is vertically centred on the avatar circle so the marker can
 * use ANCHOR_CENTER and the avatar sits exactly on the geo position.
 */
private fun memberPinDrawable(
    context: Context,
    name: String,
    counter: String?,
    isStale: Boolean,
    isStationary: Boolean?,
    avatarBitmap: Bitmap? = null,
    pubkeyHex: String = ""
): BitmapDrawable {
    val dm = context.resources.displayMetrics
    val dp = dm.density
    val avatar = 38f * dp
    val badge = 16f * dp
    val gap = 2f * dp
    val lineGap = 1f * dp
    val halo = 3f * dp

    val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 11f, dm)
        typeface = Typeface.DEFAULT_BOLD
        textAlign = Paint.Align.CENTER
    }
    val fm = textPaint.fontMetrics
    val textHeight = fm.descent - fm.ascent

    val counterPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 10f, dm)
        textAlign = Paint.Align.CENTER
    }
    val cfm = counterPaint.fontMetrics
    val counterHeight = if (counter != null) cfm.descent - cfm.ascent else 0f

    // Space below the avatar for the name (+ optional counter line); mirrored
    // above to keep the avatar at the bitmap's vertical centre.
    val below = gap + textHeight +
        (if (counter != null) lineGap + counterHeight else 0f) + halo

    val labelWidth = maxOf(
        textPaint.measureText(name),
        if (counter != null) counterPaint.measureText(counter) else 0f
    )
    val width = maxOf(avatar + badge, labelWidth + 2 * halo).toInt() + 1
    val height = (avatar + 2 * below).toInt() + 1
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val cx = width / 2f
    val cy = height / 2f
    val r = avatar / 2f

    val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }

    // White ring
    fill.color = Color.WHITE
    canvas.drawCircle(cx, cy, r, fill)
    val inner = r - 1.5f * dp

    if (avatarBitmap != null) {
        // Photo, centre-cropped into the disc.
        canvas.save()
        canvas.clipPath(Path().apply { addCircle(cx, cy, inner, Path.Direction.CW) })
        val side = minOf(avatarBitmap.width, avatarBitmap.height)
        val src = Rect(
            (avatarBitmap.width - side) / 2,
            (avatarBitmap.height - side) / 2,
            (avatarBitmap.width + side) / 2,
            (avatarBitmap.height + side) / 2
        )
        val dst = RectF(cx - inner, cy - inner, cx + inner, cy + inner)
        val imagePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            isFilterBitmap = true
            if (isStale) {
                // Desaturate to match the grey treatment of a stale pin.
                colorFilter = ColorMatrixColorFilter(ColorMatrix().apply { setSaturation(0f) })
            }
        }
        canvas.drawBitmap(avatarBitmap, src, dst, imagePaint)
        canvas.restore()
    } else {
        // Initials on a stable per-member colour.
        fill.color = if (isStale) 0xFF8E8E93.toInt() else {
            INITIALS_PALETTE[MemberAvatarFallback.colorIndex(pubkeyHex)]
        }
        canvas.drawCircle(cx, cy, inner, fill)

        val initialsPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = inner * 0.9f
            typeface = Typeface.DEFAULT_BOLD
            textAlign = Paint.Align.CENTER
        }
        val ifm = initialsPaint.fontMetrics
        canvas.drawText(
            MemberAvatarFallback.initials(name),
            cx,
            cy - (ifm.ascent + ifm.descent) / 2f,
            initialsPaint
        )
    }

    if (isStationary == true) {
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

    // Staleness counter, one line below the name (iOS's .secondary relative text)
    if (counter != null) {
        val counterY = textY + fm.descent + lineGap - cfm.ascent
        counterPaint.style = Paint.Style.STROKE
        counterPaint.strokeWidth = halo
        counterPaint.color = Color.WHITE
        canvas.drawText(counter, cx, counterY, counterPaint)
        counterPaint.style = Paint.Style.FILL
        counterPaint.color = 0xFF6E6E73.toInt()
        canvas.drawText(counter, cx, counterY, counterPaint)
    }

    return BitmapDrawable(context.resources, bitmap)
}

@Composable
private fun OsmMapView(
    annotations: List<MemberAnnotation>,
    mapViewRef: MutableState<MapView?> = mutableStateOf(null),
    onMarkerTap: (MemberAnnotation) -> Unit = {},
    avatarFor: (String) -> Bitmap? = { null }
) {
    val timeFormat = remember { SimpleDateFormat("h:mm a", Locale.getDefault()) }
    // Only auto-fit camera on first annotation load, not on every update
    var hasFittedCamera by remember { mutableStateOf(false) }

    // Tick every second so the per-pin staleness counter stays live. The bitmap
    // is static once drawn, so we re-render markers on each tick (the family pin
    // count is small). `now` is read inside `update` to drive its re-execution.
    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1000L)
            now = System.currentTimeMillis()
        }
    }

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
            // Read `now` so this block re-runs on each tick, refreshing counters.
            val tickNow = now
            // Update markers without touching the camera
            mapView.overlays.removeAll { it is Marker }

            for (ann in annotations) {
                // Own pin counts down to its next publish; others count up since
                // last seen — mirrors iOS MemberPinView.
                val counter = if (ann.isMe && ann.nextUpdateMs != null) {
                    formatCountdownShort(ann.nextUpdateMs - tickNow)
                } else {
                    formatAgeShort(tickNow - ann.timestampMs)
                }
                val marker = Marker(mapView).apply {
                    position = GeoPoint(ann.position.latitude, ann.position.longitude)
                    title = ann.displayName
                    snippet = if (ann.isMe) "You • ${timeFormat.format(Date(ann.timestampMs))}"
                              else timeFormat.format(Date(ann.timestampMs))
                    icon = memberPinDrawable(
                        mapView.context, ann.displayName, counter, ann.isStale, ann.isStationary,
                        avatarFor(ann.memberPubkeyHex), ann.memberPubkeyHex
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

/** Count-up since last seen: "5s ago" / "2 min ago" / "1 hr ago" / "3 d ago". */
private fun formatAgeShort(deltaMs: Long): String {
    val s = maxOf(0L, deltaMs / 1000)
    return when {
        s < 60 -> "${s}s ago"
        s < 3600 -> "${s / 60} min ago"
        s < 86_400 -> "${s / 3600} hr ago"
        else -> "${s / 86_400} d ago"
    }
}

/** Count-down to own next publish: "in 5s" / "in 2 min" / "in 1 hr"; "now" when due. */
private fun formatCountdownShort(deltaMs: Long): String {
    val s = deltaMs / 1000
    return when {
        s <= 0 -> "now"
        s < 60 -> "in ${s}s"
        s < 3600 -> "in ${s / 60} min"
        else -> "in ${s / 3600} hr"
    }
}
