package com.hackathonmapper.meshmapper

import android.content.Context
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GpsFixed
import androidx.compose.material.icons.filled.LocationOff
import androidx.compose.material.icons.filled.NearMe
import androidx.compose.material.icons.filled.PinDrop
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.filled.WrongLocation
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hackathonmapper.meshcore.FloorPoint
import com.hackathonmapper.meshcore.GeoFrame
import com.hackathonmapper.meshcore.PositionSource
import com.hackathonmapper.meshcore.currentTime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.PI
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.log2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sinh
import kotlin.math.tan

private val gpsColor = Color(0.72f, 0.57f, 1.0f)
private val bluetoothColor = Color(0.31f, 0.83f, 0.92f)
private val predictedColor = Color(0xFFFF9500)
private val grayColor = Color(0xFF8E8E93)

/** What the map shows: frame coordinates (meters) at the screen center, and meters per pixel. */
private class MapCamera(x: Double, z: Double, metersPerPixel: Double) {
    var x by mutableStateOf(x)
    var z by mutableStateOf(z)
    var metersPerPixel by mutableStateOf(metersPerPixel)
}

/**
 * The whole app for most people: one map with this phone and every phone the mesh reaches.
 * A phone without GPS is placed here, on the phone itself, from the Bluetooth signal of the
 * phones around it; when Bluetooth loses it, the movement model keeps predicting where it is.
 *
 * Android draws the map itself on a Canvas in frame coordinates (no Google Maps), with
 * OpenStreetMap tiles underneath when the frame has a GPS origin and the phone is online, and a
 * metric grid otherwise. Pan and pinch-zoom like MapKit.
 */
@Composable
fun PhoneMapView(model: MeshModel) {
    val tracker = model.tracker
    val predictor = model.predictor
    val context = LocalContext.current
    val tiles = remember { TileCache.shared(context) }
    val measurer = rememberTextMeasurer()
    val scope = rememberCoroutineScope()

    // Starts over the frame's origin (Hervanta campus) until there is someone to show.
    val camera = remember { MapCamera(0.0, 0.0, 600.0 / 400.0) }
    var following by rememberSaveable { mutableStateOf(true) }
    var pinning by rememberSaveable { mutableStateOf(false) }
    var canvasSize by remember { mutableStateOf(Size.Zero) }
    var cameraJob by remember { mutableStateOf<Job?>(null) }

    fun point(phone: TrackedPhone): FloorPoint? = predictor.clouds[phone.id]?.center ?: phone.point

    /** Keeps every phone in view until the user pans; the scope button brings it back. */
    fun fitCamera(animated: Boolean = true) {
        if (!following || canvasSize.width <= 0f) return
        val points = mutableListOf<Pair<FloorPoint, Double>>()
        for (phone in tracker.phones) {
            val cloud = predictor.clouds[phone.id]
            if (cloud != null) {
                points.add(cloud.center to 30.0)
            } else {
                val p = phone.point ?: continue
                points.add(p to (phone.radius ?: 10.0))
            }
        }
        if (points.isEmpty()) return
        val xs = points.map { it.first.x }
        val zs = points.map { it.first.z }
        val cx = (xs.min() + xs.max()) / 2
        val cz = (zs.min() + zs.max()) / 2
        val pad = max(60.0, (points.maxOf { it.second }) * 2.5)
        val spanX = max(xs.max() - xs.min() + pad, 120.0)
        val spanZ = max(zs.max() - zs.min() + pad, 120.0)
        val mpp = max(spanX / canvasSize.width, spanZ / canvasSize.height)
        cameraJob?.cancel()
        if (!animated) {
            camera.x = cx; camera.z = cz; camera.metersPerPixel = mpp
            return
        }
        val from = Triple(camera.x, camera.z, camera.metersPerPixel)
        cameraJob = scope.launch {
            animate(0f, 1f, animationSpec = tween(600)) { t, _ ->
                camera.x = from.first + (cx - from.first) * t
                camera.z = from.second + (cz - from.second) * t
                camera.metersPerPixel = exp(ln(from.third) + (ln(mpp) - ln(from.third)) * t)
            }
        }
    }

    LaunchedEffect(tracker.phones, canvasSize) { fitCamera(animated = camera.metersPerPixel != 600.0 / 400.0) }

    val origin = GeoFrame.origins[model.frameID]
    val background = MaterialTheme.colorScheme.surfaceContainerHighest
    val gridColor = MaterialTheme.colorScheme.outlineVariant
    val labelColor = MaterialTheme.colorScheme.onSurface
    val haloColor = MaterialTheme.colorScheme.surface

    Box(Modifier.fillMaxSize()) {
        Canvas(
            Modifier
                .fillMaxSize()
                .background(background)
                .pointerInput(Unit) {
                    detectTransformGestures { centroid, pan, zoom, _ ->
                        following = false
                        cameraJob?.cancel()
                        val mid = Offset(size.width / 2f, size.height / 2f)
                        // The point under the fingers stays under them while zooming.
                        val wx = camera.x + (centroid.x - mid.x) * camera.metersPerPixel
                        val wz = camera.z - (centroid.y - mid.y) * camera.metersPerPixel
                        val mpp = (camera.metersPerPixel / zoom).coerceIn(0.02, 200.0)
                        camera.metersPerPixel = mpp
                        camera.x = wx - (centroid.x - mid.x) * mpp - pan.x * mpp
                        camera.z = wz + (centroid.y - mid.y) * mpp + pan.y * mpp
                    }
                }
                .pointerInput(Unit) {
                    detectTapGestures { tap ->
                        if (!pinning) return@detectTapGestures
                        val x = camera.x + (tap.x - size.width / 2f) * camera.metersPerPixel
                        val z = camera.z - (tap.y - size.height / 2f) * camera.metersPerPixel
                        // Same path as MapKit: the tapped coordinate, back into the frame.
                        val c = GeoFrame.coordinate(model.frameID, x, z)
                        model.pinHere(c?.latitude ?: Double.NaN, c?.longitude ?: Double.NaN)
                        pinning = false
                        following = true
                    }
                },
        ) {
            if (canvasSize != size) canvasSize = size
            val mpp = camera.metersPerPixel
            fun screen(p: FloorPoint) = Offset(
                (size.width / 2 + (p.x - camera.x) / mpp).toFloat(),
                (size.height / 2 - (p.z - camera.z) / mpp).toFloat(),
            )

            drawGrid(camera, gridColor)
            if (origin != null && origin.bearingDegrees == 0.0) {
                tiles.version // Read here so a tile that arrives redraws the map.
                drawTiles(tiles, model.frameID, camera, density)
            }

            for (link in tracker.links) {
                val a = tracker.phones.firstOrNull { it.id == link.a }?.let { point(it) } ?: continue
                val b = tracker.phones.firstOrNull { it.id == link.b }?.let { point(it) } ?: continue
                drawLine(
                    Color.White.copy(alpha = 0.6f), screen(a), screen(b), strokeWidth = 1.5.dp.toPx(),
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx())),
                )
                // The measured range; the line's length on the map matches it.
                val middle = screen(FloorPoint((a.x + b.x) / 2, (a.z + b.z) / 2))
                drawCapsuleLabel(measurer, fmt("%.1f m", link.measured), middle)
            }

            for (phone in tracker.phones) {
                val cloud = predictor.clouds[phone.id]
                if (cloud != null) {
                    for (p in cloud.points) drawCircle(predictedColor.copy(alpha = 0.7f), 2.dp.toPx(), screen(p))
                    drawMarker(screen(cloud.center), predictedColor, phone.isSelf, dashed = true)
                    drawName(measurer, name(phone), screen(cloud.center), phone.isSelf, labelColor, haloColor)
                    continue
                }
                val p = phone.point ?: continue
                val color = color(phone)
                val ring = phone.ring
                val radius = phone.radius
                if (ring != null) {
                    // Only the distance is known: anywhere on this ring.
                    drawCircle(
                        color.copy(alpha = 0.8f), (ring.radius / mpp).toFloat(), screen(ring.center),
                        style = Stroke(1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(5.dp.toPx(), 4.dp.toPx()))),
                    )
                } else if (radius != null && radius > 0) {
                    drawCircle(color.copy(alpha = 0.14f), (radius / mpp).toFloat(), screen(p))
                    drawCircle(color.copy(alpha = 0.8f), (radius / mpp).toFloat(), screen(p), style = Stroke(1.dp.toPx()))
                }
                drawMarker(screen(p), color, phone.isSelf, dashed = phone.state == TrackedPhone.State.lastSeen)
                drawName(measurer, name(phone), screen(p), phone.isSelf, labelColor, haloColor)
            }
        }

        Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            val status = status(model)
            StatusCard(
                title = status.title, detail = status.detail, tint = status.tint, name = model.label,
                hint = if (pinning) "Tap the map where you are standing" else null,
                problem = model.permissionProblem,
                modifier = Modifier.padding(horizontal = 12.dp).padding(top = 8.dp),
            )
            Spacer(Modifier.weight(1f))
            ScaleBar(camera.metersPerPixel, Modifier.padding(start = 16.dp, bottom = 8.dp))
            if (origin != null) {
                Text(
                    "© OpenStreetMap contributors",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 16.dp, bottom = 6.dp),
                )
            }
            Controls(
                model = model,
                pinning = pinning,
                following = following,
                onPin = { if (model.positionChoice == PositionChoice.manual) model.unpin() else pinning = !pinning },
                onFollow = { following = true; fitCamera() },
                modifier = Modifier.padding(horizontal = 12.dp).padding(bottom = 12.dp),
            )
        }
    }
}

private fun name(phone: TrackedPhone): String = if (phone.isSelf) "You" else phone.label

private fun color(phone: TrackedPhone): Color = when (phone.state) {
    is TrackedPhone.State.placed -> gpsColor
    TrackedPhone.State.estimated -> bluetoothColor
    TrackedPhone.State.lastSeen -> predictedColor
    TrackedPhone.State.unplaced -> grayColor
}

// MARK: - Controls

@Composable
private fun Controls(
    model: MeshModel,
    pinning: Boolean,
    following: Boolean,
    onPin: () -> Unit,
    onFollow: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val padding = PaddingValues(horizontal = 14.dp, vertical = 12.dp)
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        Button(
            onClick = { model.simulateGPSLoss = !model.simulateGPSLoss },
            modifier = Modifier.weight(1f),
            contentPadding = padding,
            colors = ButtonDefaults.buttonColors(containerColor = if (model.simulateGPSLoss) predictedColor else gpsColor, contentColor = Color.White),
        ) {
            Icon(if (model.simulateGPSLoss) Icons.Filled.LocationOff else Icons.Filled.NearMe, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text(if (model.simulateGPSLoss) "GPS off (demo)" else "GPS on", maxLines = 1)
        }
        val manual = model.positionChoice == PositionChoice.manual
        Button(onClick = onPin, contentPadding = padding) {
            Icon(if (manual) Icons.Filled.WrongLocation else Icons.Filled.PinDrop, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text(if (manual) "Unpin" else if (pinning) "Cancel" else "Pin me", maxLines = 1)
        }
        if (!following) {
            Button(onClick = onFollow, contentPadding = PaddingValues(12.dp)) {
                Icon(Icons.Filled.GpsFixed, contentDescription = "Show everyone")
            }
        }
        Button(onClick = { model.showingSettings = true }, contentPadding = PaddingValues(12.dp)) {
            Icon(Icons.Filled.Settings, contentDescription = "Settings")
        }
    }
}

// MARK: - Status

private data class MapStatus(val title: String, val detail: String, val tint: Color)

private fun status(model: MeshModel): MapStatus {
    val tracker = model.tracker
    if (!model.isRunning) return MapStatus("Mesh stopped", "Open settings to start it", grayColor)
    val nearby = model.bluetooth.neighbors.size
    val nearbyText = if (nearby == 0) "No phones nearby yet" else "$nearby phone${if (nearby == 1) "" else "s"} nearby"
    val me = tracker.me
        ?: return if (model.gpsPosition == null && model.positionChoice == PositionChoice.gps) {
            MapStatus("Looking for a phone with GPS…", nearbyText, grayColor)
        } else {
            MapStatus("Starting…", nearbyText, grayColor)
        }
    val radius = me.radius?.let { "±${swiftRoundedInt(it)} m" } ?: ""
    return when (val state = me.state) {
        is TrackedPhone.State.placed -> when (state.source) {
            PositionSource.manual -> MapStatus("Pinned spot", "You placed yourself on the map · $nearbyText", gpsColor)
            PositionSource.uwb -> MapStatus("UWB $radius", nearbyText, gpsColor)
            PositionSource.fused -> MapStatus("Motion + anchors $radius", nearbyText, gpsColor)
            else -> MapStatus("GPS $radius", nearbyText, gpsColor)
        }
        TrackedPhone.State.estimated -> {
            val hops = me.hops?.let { " · $it hop${if (it == 1) "" else "s"}" } ?: ""
            val via = strongestPlacedNeighbor(tracker, me.id)?.let { " via $it" } ?: ""
            val title = if (me.ambiguous) "Bluetooth: direction unclear" else "Found over Bluetooth"
            MapStatus(title, "$radius$via$hops", bluetoothColor)
        }
        TrackedPhone.State.lastSeen -> {
            val age = (currentTime() - me.since).toInt()
            if (model.predictor.clouds[me.id] != null) {
                MapStatus("Position lost $age s ago", "Movement model is predicting where you are", predictedColor)
            } else {
                MapStatus("Position lost $age s ago", "Showing your last known spot", predictedColor)
            }
        }
        TrackedPhone.State.unplaced -> MapStatus("Looking for a phone with GPS…", nearbyText, grayColor)
    }
}

/** The placed phone with the strongest signal to `id`: who this phone is located from. */
private fun strongestPlacedNeighbor(tracker: BluetoothTracker, id: String): String? {
    val placed = tracker.phones.filter {
        it.state is TrackedPhone.State.placed || it.state == TrackedPhone.State.estimated
    }.map { it.id }.toSet()
    val link = tracker.links
        .filter { (it.a == id && it.b in placed) || (it.b == id && it.a in placed) }
        .maxByOrNull { it.rssi } ?: return null
    val other = if (link.a == id) link.b else link.a
    return tracker.phones.firstOrNull { it.id == other }?.label
}

@Composable
private fun StatusCard(
    title: String,
    detail: String,
    tint: Color,
    name: String,
    hint: String?,
    problem: String?,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLowest.copy(alpha = 0.92f),
        shadowElevation = 2.dp,
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                name.uppercase(),
                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(title, style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold), color = tint)
            if (detail.isNotEmpty()) Text(detail, style = MaterialTheme.typography.bodyMedium)
            if (problem != null) {
                Text(problem, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error)
            }
            if (hint != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.TouchApp, contentDescription = null, tint = predictedColor, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(hint, style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold), color = predictedColor)
                }
            }
        }
    }
}

/** MapKit's scale view: a bar of a round length. */
@Composable
private fun ScaleBar(metersPerPixel: Double, modifier: Modifier = Modifier) {
    val measurer = rememberTextMeasurer()
    val color = MaterialTheme.colorScheme.onSurface
    val halo = MaterialTheme.colorScheme.surface
    Canvas(modifier.size(width = 120.dp, height = 22.dp)) {
        val target = 100.dp.toPx() * metersPerPixel
        val magnitude = 10.0.pow(floor(log10(target)))
        val length = listOf(5.0, 2.0, 1.0).map { it * magnitude }.first { it <= target }
        val px = (length / metersPerPixel).toFloat()
        val y = size.height - 3.dp.toPx()
        drawLine(halo, Offset(0f, y), Offset(px, y), strokeWidth = 5.dp.toPx())
        drawLine(color, Offset(0f, y), Offset(px, y), strokeWidth = 2.dp.toPx())
        drawLabel(measurer, if (length >= 1) meters(length) else fmt("%.1f m", length), TextStyle(fontSize = 11.sp, color = color), Offset(0f, 7.dp.toPx()), leading = true)
    }
}

// MARK: - Drawing

private fun DrawScope.drawMarker(at: Offset, color: Color, isSelf: Boolean, dashed: Boolean) {
    val r = (if (isSelf) 11 else 8).dp.toPx()
    drawCircle(Color.Black.copy(alpha = 0.25f), r + 1.5.dp.toPx(), at + Offset(0f, 1.dp.toPx()))
    drawCircle(color, r, at)
    val width = (if (isSelf) 3 else 2).dp.toPx()
    drawCircle(
        Color.White, r, at,
        style = Stroke(width, pathEffect = if (dashed) PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx())) else null),
    )
}

/** The annotation title under a marker, with a halo so it reads on any background. */
private fun DrawScope.drawName(measurer: TextMeasurer, text: String, at: Offset, isSelf: Boolean, color: Color, halo: Color) {
    val style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = color)
    val layout = measurer.measure(text, style, maxLines = 1)
    val top = at.y + (if (isSelf) 14 else 11).dp.toPx()
    val left = at.x - layout.size.width / 2f
    drawRoundRect(
        halo.copy(alpha = 0.75f),
        topLeft = Offset(left - 4.dp.toPx(), top - 1.dp.toPx()),
        size = Size(layout.size.width + 8.dp.toPx(), layout.size.height + 2.dp.toPx()),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(4.dp.toPx()),
    )
    drawPlainText(measurer, text, style, Offset(left, top))
}

private fun DrawScope.drawPlainText(measurer: TextMeasurer, text: String, style: TextStyle, topLeft: Offset) {
    drawText(measurer.measure(text, style, maxLines = 1), topLeft = topLeft)
}

private fun DrawScope.drawCapsuleLabel(measurer: TextMeasurer, text: String, at: Offset) {
    val style = TextStyle(fontSize = 11.sp, color = Color.White, fontFeatureSettings = "tnum")
    val layout = measurer.measure(text, style, maxLines = 1)
    val w = layout.size.width + 8.dp.toPx()
    val h = layout.size.height.toFloat()
    drawRoundRect(
        Color.Black.copy(alpha = 0.55f),
        topLeft = Offset(at.x - w / 2, at.y - h / 2),
        size = Size(w, h),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(h / 2),
    )
    drawText(layout, topLeft = Offset(at.x - layout.size.width / 2f, at.y - h / 2))
}

/** A metric grid, so the map stays readable offline and in room frames. */
private fun DrawScope.drawGrid(camera: MapCamera, color: Color) {
    val mpp = camera.metersPerPixel
    val target = 80.dp.toPx() * mpp
    val magnitude = 10.0.pow(floor(log10(target)))
    val step = listOf(1.0, 2.0, 5.0, 10.0).map { it * magnitude }.first { it >= target }
    val halfW = size.width / 2 * mpp
    val halfH = size.height / 2 * mpp
    var x = floor((camera.x - halfW) / step) * step
    while (x <= camera.x + halfW) {
        val sx = (size.width / 2 + (x - camera.x) / mpp).toFloat()
        drawLine(color, Offset(sx, 0f), Offset(sx, size.height), strokeWidth = 1f)
        x += step
    }
    var z = floor((camera.z - halfH) / step) * step
    while (z <= camera.z + halfH) {
        val sy = (size.height / 2 - (z - camera.z) / mpp).toFloat()
        drawLine(color, Offset(0f, sy), Offset(size.width, sy), strokeWidth = 1f)
        z += step
    }
}

/**
 * OpenStreetMap tiles under the stage, like the dashboard's (website/src/scene.ts). Only for
 * north-up frames with a GPS origin; tiles that are not cached and cannot be fetched leave the
 * grid showing.
 */
private fun DrawScope.drawTiles(tiles: TileCache, frameId: String, camera: MapCamera, density: Float) {
    val mpp = camera.metersPerPixel
    val center = GeoFrame.coordinate(frameId, camera.x, camera.z) ?: return
    val metersPerTile = 40_075_016.686 * cos(center.latitude * PI / 180)
    // Tiles drawn at roughly their native 256 dp, so labels keep their size.
    val zoom = (log2(metersPerTile / (256 * density * mpp))).roundToInt().coerceIn(2, 19)
    val n = 1 shl zoom
    val halfW = size.width / 2 * mpp
    val halfH = size.height / 2 * mpp
    val nw = GeoFrame.coordinate(frameId, camera.x - halfW, camera.z + halfH) ?: return
    val se = GeoFrame.coordinate(frameId, camera.x + halfW, camera.z - halfH) ?: return
    val x0 = tileX(nw.longitude, n)
    val x1 = tileX(se.longitude, n)
    val y0 = tileY(nw.latitude, n)
    val y1 = tileY(se.latitude, n)
    if ((x1 - x0 + 1) * (y1 - y0 + 1) > 80) return
    val frame = { lat: Double, lon: Double -> GeoFrame.position(frameId, lat, lon) }
    for (ty in y0..y1) {
        for (tx in x0..x1) {
            if (ty !in 0 until n) continue
            val wrapped = ((tx % n) + n) % n
            val image = tiles.get(zoom, wrapped, ty) ?: continue
            val a = frame(tileLat(ty, n), tileLon(tx, n)) ?: continue
            val b = frame(tileLat(ty + 1, n), tileLon(tx + 1, n)) ?: continue
            val left = (size.width / 2 + (a.x - camera.x) / mpp).toFloat()
            val top = (size.height / 2 - (a.z - camera.z) / mpp).toFloat()
            val right = (size.width / 2 + (b.x - camera.x) / mpp).toFloat()
            val bottom = (size.height / 2 - (b.z - camera.z) / mpp).toFloat()
            drawImage(
                image,
                dstOffset = IntOffset(floor(left).toInt(), floor(top).toInt()),
                dstSize = IntSize(
                    (kotlin.math.ceil(right) - floor(left)).toInt().coerceAtLeast(1),
                    (kotlin.math.ceil(bottom) - floor(top)).toInt().coerceAtLeast(1),
                ),
            )
        }
    }
}

private fun tileX(lon: Double, n: Int): Int = floor((lon + 180) / 360 * n).toInt()
private fun tileY(lat: Double, n: Int): Int {
    val r = lat * PI / 180
    return floor((1 - ln(tan(r) + 1 / cos(r)) / PI) / 2 * n).toInt()
}
private fun tileLon(x: Int, n: Int): Double = x.toDouble() / n * 360 - 180
private fun tileLat(y: Int, n: Int): Double = atan(sinh(PI * (1 - 2.0 * y / n))) * 180 / PI

/**
 * OpenStreetMap raster tiles: memory cache, disk cache in the app's cache directory, a few
 * downloads at a time. Offline, a failed tile is retried after a minute; nothing else changes.
 */
class TileCache private constructor(context: Context) {
    companion object {
        private const val retryAfter = 60.0
        private const val userAgent = "MeshMapper-Android/0.1 (hackathon mesh positioning demo)"

        @Volatile
        private var instance: TileCache? = null

        fun shared(context: Context): TileCache =
            instance ?: synchronized(this) { instance ?: TileCache(context.applicationContext).also { instance = it } }

        private fun url(z: Int, x: Int, y: Int) = "https://tile.openstreetmap.org/$z/$x/$y.png"
    }

    private val directory = File(context.cacheDir, "osm-tiles")
    private val memory = LruCache<String, ImageBitmap>(96)
    private val failedAt = mutableMapOf<String, Double>()
    private val loading = mutableSetOf<String>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val downloads = Semaphore(4)

    /** Bumped whenever a tile arrives, so the map redraws. */
    var version by mutableIntStateOf(0)
        private set

    /** The tile if it is ready; otherwise starts loading it and returns null. Main thread only. */
    fun get(z: Int, x: Int, y: Int): ImageBitmap? {
        val key = "$z/$x/$y"
        memory.get(key)?.let { return it }
        if (key in loading) return null
        val failed = failedAt[key]
        if (failed != null && currentTime() - failed < retryAfter) return null
        loading.add(key)
        scope.launch {
            val image = withContext(Dispatchers.IO) { load(z, x, y) }
            loading.remove(key)
            if (image != null) {
                memory.put(key, image)
                failedAt.remove(key)
                version += 1
            } else {
                failedAt[key] = currentTime()
            }
        }
        return null
    }

    private suspend fun load(z: Int, x: Int, y: Int): ImageBitmap? {
        val file = File(directory, "$z/$x/$y.png")
        try {
            if (file.exists()) {
                BitmapFactory.decodeFile(file.path)?.let { return it.asImageBitmap() }
            }
        } catch (_: Exception) {
        }
        return downloads.withPermit {
            try {
                val connection = URL(url(z, x, y)).openConnection() as HttpURLConnection
                connection.connectTimeout = 5_000
                connection.readTimeout = 8_000
                connection.setRequestProperty("User-Agent", userAgent)
                try {
                    if (connection.responseCode != 200) return@withPermit null
                    val bytes = connection.inputStream.use { it.readBytes() }
                    val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return@withPermit null
                    try {
                        file.parentFile?.mkdirs()
                        file.writeBytes(bytes)
                    } catch (_: Exception) {
                    }
                    bitmap.asImageBitmap()
                } finally {
                    connection.disconnect()
                }
            } catch (_: Exception) {
                null
            }
        }
    }
}
