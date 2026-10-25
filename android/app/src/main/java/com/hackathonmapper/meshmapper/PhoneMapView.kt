package com.hackathonmapper.meshmapper

import android.content.Context
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GpsFixed
import androidx.compose.material.icons.filled.PinDrop
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Theaters
import androidx.compose.material.icons.filled.WrongLocation
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hackathonmapper.meshcore.FloorPoint
import com.hackathonmapper.meshcore.GeoFrame
import com.hackathonmapper.meshcore.IntegrityAssessment
import com.hackathonmapper.meshcore.PositionEstimate
import com.hackathonmapper.meshcore.PositionSource
import com.hackathonmapper.meshcore.ScenarioInput
import com.hackathonmapper.meshcore.currentTime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
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
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.log2
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sinh
import kotlin.math.tan

/** What the map shows: frame coordinates (meters) at the screen center, and meters per pixel. */
private class MapCamera(x: Double, z: Double, metersPerPixel: Double) {
    var x by mutableDoubleStateOf(x)
    var z by mutableDoubleStateOf(z)
    var metersPerPixel by mutableDoubleStateOf(metersPerPixel)

    fun screen(p: FloorPoint, size: Size): Offset = Offset(
        (size.width / 2 + (p.x - x) / metersPerPixel).toFloat(),
        (size.height / 2 - (p.z - z) / metersPerPixel).toFloat(),
    )
}

/** Dark, muted base map like MapKit's `.standard(emphasis: .muted)` under `.colorScheme(.dark)`. */
private val mapBackground = Color(0.10f, 0.11f, 0.13f)
private val mapGrid = Color.White.copy(alpha = 0.07f)

/**
 * The whole app for most people: one map with this phone and every phone the mesh reaches, drawn
 * by GhostCore's map layer from what GhostCoreHub decided this second. Each phone shows how it is
 * placed (GPS trusted, Bluetooth estimate with its 95% circle, predicted with its age), the links and
 * relay routes between phones, and, when the trust checks refuse a GPS fix, where that fix claimed
 * to be and why it was refused.
 *
 * Android draws the map itself on a Canvas in frame coordinates (no Google Maps), with
 * OpenStreetMap tiles underneath (dimmed, for the dark map) when the frame has a north-up GPS
 * origin and the phone is online, and a metric grid otherwise. Pan and pinch-zoom like MapKit.
 * ContentView hosts it as the root and shows the settings tabs in a sheet.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PhoneMapView(
    model: MeshModel,
    hub: GhostCoreHub = model.ghost,
    predictor: MovementPredictor = model.predictor,
    bluetooth: BluetoothMesh = model.bluetooth,
) {
    val context = LocalContext.current
    val tiles = remember { TileCache.shared(context) }
    val scope = rememberCoroutineScope()
    remember { FixturePreview.configure(context) }
    val assetScenarios = remember { bundledScenarioAssets(context) }

    /** Starts over the frame's origin (Hervanta campus) until there is someone to show. */
    val camera = remember { MapCamera(0.0, 0.0, 600.0 / 400.0) }
    var following by rememberSaveable { mutableStateOf(true) }
    var pinning by rememberSaveable { mutableStateOf(false) }
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    var showingSimulation by rememberSaveable { mutableStateOf(false) }
    var canvasSize by remember { mutableStateOf(Size.Zero) }
    var cameraJob by remember { mutableStateOf<Job?>(null) }
    // SwiftUI's TimelineView(.periodic(by: 1)): ages on screen count up every second.
    var now by remember { mutableDoubleStateOf(currentTime()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1000)
            now = currentTime()
        }
    }

    /** The one place the map's data is assembled. */
    fun currentScene(): VizScene {
        FixturePreview.stage?.let { stage -> FixturePreview.scene(stage)?.let { return it } }
        return VizScene.hub(hub, model, predictor, now)
    }

    /**
     * What the simulation panel injects. Every action is a raw input through GhostCoreHub: GNSS
     * faults act on this phone's own GPS (other phones are other devices), a link toggle forces this
     * phone's Bluetooth link to that peer down or up. Parameters follow ARCHITECTURE.md S2/S3.
     */
    fun scenarioControls(): VizScenarioControls {
        val me = model.deviceID
        val scenarios = hub.availableScenarios.ifEmpty { assetScenarios }
        val controls = VizScenarioControls()
        controls.scenarios = scenarios.map { VizScenarioControls.Option(it.id, "${it.id} · ${it.title}", it.summary) }
        controls.roles = scenarios.flatMap { s -> s.phones.map { it.id } }.toSet().sorted()
        controls.run = run@{ id, role, roleMap ->
            val scenario = scenarios.firstOrNull { it.id == id } ?: return@run
            if (role == null) return@run
            model.simulateGPSLoss = false
            hub.play(scenario, role, roleMap)
        }
        if (hub.simulationActive || hub.scenario?.isRunning == true || model.simulateGPSLoss) {
            controls.stop = {
                model.simulateGPSLoss = false
                hub.stop()
            }
        }
        controls.supportedGNSS = VizScenarioControls.GNSSFault.entries.toSet()
        controls.gnss = { fault ->
            when (fault) {
                VizScenarioControls.GNSSFault.jump -> hub.inject(ScenarioInput.gnssJump(me, 400.0, 0.0))
                VizScenarioControls.GNSSFault.drift -> hub.inject(ScenarioInput.gnssDrift(me, 1.0, 90.0))
                VizScenarioControls.GNSSFault.outage -> hub.inject(ScenarioInput.gnssOutage(me, true))
                VizScenarioControls.GNSSFault.restore -> {
                    model.simulateGPSLoss = false
                    hub.inject(ScenarioInput.gnssClear(me))
                }
            }
        }
        controls.peers = hub.phones.filter { !it.isSelf }.map {
            VizScenarioControls.Peer(it.id, it.label, linkUp = it.id !in hub.forcedDown)
        }
        controls.setPeerLink = { peer, up -> hub.inject(ScenarioInput.peerLink(me, peer, up)) }
        controls.unavailableReason = if (model.isRunning) "Not available on this build." else "Start the mesh first."
        return controls
    }

    /** Keeps every phone (and any refused GPS fix) in view until the user pans; the scope button brings it back. */
    fun fitCamera(animated: Boolean = true) {
        if (!following || canvasSize.width <= 0f || canvasSize.height <= 0f) return
        val scene = currentScene()
        val points = mutableListOf<Pair<FloorPoint, Double>>()
        for (phone in scene.phones) {
            scene.drawnPoint(phone.id)?.let { points.add(it to if (phone.kind == PositionEstimate.Kind.predicted) 30.0 else (phone.r95 ?: 10.0)) }
            val integrity = phone.integrity
            if (integrity != null &&
                (integrity.status == IntegrityAssessment.Status.rejected || integrity.status == IntegrityAssessment.Status.suspect)
            ) {
                integrity.evaluatedFix?.point?.let { points.add(it to 10.0) }
            }
            for (option in phone.likelyPaths?.options ?: emptyList()) option.here?.let { points.add(it to 10.0) }
        }
        if (points.isEmpty()) return
        val xs = points.map { it.first.x }
        val zs = points.map { it.first.z }
        val cx = (xs.min() + xs.max()) / 2
        val cz = (zs.min() + zs.max()) / 2
        // Extra room top and bottom for the status card and the controls.
        val pad = max(80.0, points.maxOf { it.second } * 2.5)
        val spanZ = (zs.max() - zs.min()) * 1.6 + pad
        // Wider sideways: labels hang off the dots horizontally.
        val spanX = (xs.max() - xs.min()) * 1.5 + pad * 1.5
        val mpp = max(max(spanX, 140.0) / canvasSize.width, max(spanZ, 140.0) / canvasSize.height)
        cameraJob?.cancel()
        if (!animated) {
            camera.x = cx
            camera.z = cz
            camera.metersPerPixel = mpp
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

    var firstFit by remember { mutableStateOf(true) }
    LaunchedEffect(hub.phones, canvasSize) {
        if (canvasSize.width <= 0f) return@LaunchedEffect
        fitCamera(animated = !firstFit)
        firstFit = false
    }

    LaunchedEffect(Unit) {
        when (val target = FixturePreview.open) {
            null -> {}
            "simulation" -> showingSimulation = true
            "self" -> selected = model.deviceID
            else -> selected = target
        }
        FixturePreview.autoInject?.let { fault ->
            delay(15_000)
            scenarioControls().gnss?.invoke(fault)
        }
    }

    val scene = currentScene()
    val content = GhostMapContent(scene, selected) { selected = it }
    val origin = GeoFrame.origins[scene.frameId]

    Box(Modifier.fillMaxSize().background(mapBackground)) {
        Box(
            Modifier
                .fillMaxSize()
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
            Canvas(Modifier.fillMaxSize()) {
                if (canvasSize != size) canvasSize = size
                drawGrid(camera, mapGrid)
                if (origin != null && origin.bearingDegrees == 0.0) {
                    tiles.version // Read here so a tile that arrives redraws the map.
                    drawTiles(tiles, scene.frameId, camera, density)
                }
                content.draw(this, { camera.screen(it, size) }, camera.metersPerPixel)
            }
            content.Annotations { p -> if (canvasSize.width > 0f) camera.screen(p, canvasSize) else null }
        }

        Column(
            Modifier
                .fillMaxSize()
                .safeDrawingPadding()
                .padding(horizontal = GhostTheme.gap3)
                .padding(top = GhostTheme.gap2, bottom = GhostTheme.gap3),
            verticalArrangement = Arrangement.spacedBy(GhostTheme.gap2),
        ) {
            if (FixturePreview.stage != null) FixtureBanner()
            if (scene.anySimulated) {
                SimulationBanner(scene.scenario, scenarioControls().stop)
            }
            val me = scene.me
            StatusPanel(
                scene, model.label, fallbackStatus(model, bluetooth),
                hint = if (pinning) "Tap the map where you are standing" else null,
                modifier = Modifier.clickable(remember { MutableInteractionSource() }, indication = null) {
                    me?.let { selected = it.id }
                },
                problem = model.permissionProblem,
            )
            Spacer(Modifier.weight(1f))
            ScaleBar(camera.metersPerPixel)
            if (origin != null && origin.bearingDegrees == 0.0) {
                Text("© OpenStreetMap contributors", style = TextStyle(fontSize = 10.sp), color = GhostTheme.muted)
            }
            val lost = lostWithPaths(scene, selected)
            val lostPaths = lost?.likelyPaths
            if (me != null && showsCompare(me, scene)) {
                CompareCard(me, scene, Modifier.clickable(remember { MutableInteractionSource() }, indication = null) { selected = me.id })
            } else if (lost != null && lostPaths != null) {
                LikelyPathsCard(
                    lost, lostPaths, scene.now,
                    Modifier.clickable(remember { MutableInteractionSource() }, indication = null) { selected = lost.id },
                )
            }
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                GhostLegend(scene.integrityConnected)
            }
            Controls(
                model = model,
                pinning = pinning,
                following = following,
                onSimulate = { showingSimulation = true },
                onPin = { if (model.positionChoice == PositionChoice.manual) model.unpin() else pinning = !pinning },
                onFollow = {
                    following = true
                    fitCamera()
                },
            )
        }
    }

    selected?.let { phoneId ->
        ModalBottomSheet(
            onDismissRequest = { selected = null },
            sheetState = rememberModalBottomSheetState(),
            containerColor = Color.Black,
            contentColor = GhostTheme.text,
        ) {
            TrustExplainer(phoneId, currentScene()) { selected = null }
        }
    }

    if (showingSimulation) {
        ModalBottomSheet(
            onDismissRequest = { showingSimulation = false },
            sheetState = rememberModalBottomSheetState(),
            containerColor = Color.Black,
            contentColor = GhostTheme.text,
        ) {
            ScenarioPanel(scenarioControls(), currentScene().scenario) { showingSimulation = false }
        }
    }
}

// MARK: - Controls

@Composable
private fun Controls(
    model: MeshModel,
    pinning: Boolean,
    following: Boolean,
    onSimulate: () -> Unit,
    onPin: () -> Unit,
    onFollow: () -> Unit,
) {
    val padding = PaddingValues(horizontal = 14.dp, vertical = 12.dp)
    val raised = ButtonDefaults.buttonColors(containerColor = GhostTheme.surfaceRaised, contentColor = GhostTheme.text)
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap2), verticalAlignment = Alignment.CenterVertically) {
        Button(
            onClick = onSimulate,
            modifier = Modifier.weight(1f),
            contentPadding = padding,
            colors = ButtonDefaults.buttonColors(containerColor = GhostTheme.simulation, contentColor = Color.Black),
        ) {
            Icon(Icons.Filled.Theaters, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text("Simulate", maxLines = 1)
        }
        val manual = model.positionChoice == PositionChoice.manual
        Button(onClick = onPin, contentPadding = padding, colors = raised) {
            Icon(if (manual) Icons.Filled.WrongLocation else Icons.Filled.PinDrop, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text(if (manual) "Unpin" else if (pinning) "Cancel" else "Pin me", maxLines = 1)
        }
        if (!following) {
            Button(onClick = onFollow, contentPadding = PaddingValues(12.dp), colors = raised) {
                Icon(Icons.Filled.GpsFixed, contentDescription = "Show everyone")
            }
        }
        Button(onClick = { model.showingSettings = true }, contentPadding = PaddingValues(12.dp), colors = raised) {
            Icon(Icons.Filled.Settings, contentDescription = "Settings")
        }
    }
}

// MARK: - Status

/** Shown until the tracker has this phone. */
private fun fallbackStatus(model: MeshModel, bluetooth: BluetoothMesh): StatusFallback {
    if (!model.isRunning) return StatusFallback("Mesh stopped", "Open settings to start it")
    val nearby = bluetooth.neighbors.size
    val nearbyText = if (nearby == 0) "No phones nearby yet" else "$nearby phone${if (nearby == 1) "" else "s"} nearby"
    return if (model.ghost.publication.source != PositionSource.gps && model.positionChoice == PositionChoice.gps) {
        StatusFallback("Looking for a phone with GPS…", nearbyText)
    } else {
        StatusFallback("Starting…", nearbyText)
    }
}

/** The predicted phone whose likely paths the card spells out: the selected one, else the first. */
private fun lostWithPaths(scene: VizScene, selectedId: String?): VizPhone? {
    val lost = scene.phones.filter { it.likelyPaths != null }
    return lost.firstOrNull { it.id == selectedId } ?: lost.firstOrNull()
}

/** The raw-vs-estimate card earns its space when the two disagree or GPS is not simply trusted. */
private fun showsCompare(me: VizPhone, scene: VizScene): Boolean {
    val fix = me.comparedFix ?: return false
    val status = me.integrity?.status
    if (status in listOf(
            IntegrityAssessment.Status.rejected, IntegrityAssessment.Status.suspect,
            IntegrityAssessment.Status.degraded, IntegrityAssessment.Status.insufficientEvidence,
        )
    ) {
        return true
    }
    val shown = scene.drawnPoint(me.id) ?: return true
    return hypot(shown.x - fix.point.x, shown.z - fix.point.z) > max(10.0, me.r95 ?: 0.0)
}

/** MapKit's scale view: a bar of a round length. */
@Composable
private fun ScaleBar(metersPerPixel: Double, modifier: Modifier = Modifier) {
    val measurer = rememberTextMeasurer()
    Canvas(modifier.size(width = 120.dp, height = 22.dp)) {
        val target = 100.dp.toPx() * metersPerPixel
        val magnitude = 10.0.pow(floor(log10(target)))
        val length = listOf(5.0, 2.0, 1.0).map { it * magnitude }.first { it <= target }
        val px = (length / metersPerPixel).toFloat()
        val y = size.height - 3.dp.toPx()
        drawLine(Color.Black.copy(alpha = 0.6f), Offset(0f, y), Offset(px, y), strokeWidth = 5.dp.toPx())
        drawLine(GhostTheme.text, Offset(0f, y), Offset(px, y), strokeWidth = 2.dp.toPx())
        val text = when {
            length >= 1000 -> vizFormat("%.0f km", length / 1000)
            length >= 1 -> "${length.roundToInt()} m"
            else -> vizFormat("%.1f m", length)
        }
        val layout = measurer.measure(text, TextStyle(fontSize = 11.sp, color = GhostTheme.text), maxLines = 1)
        drawText(layout, topLeft = Offset(0f, 7.dp.toPx() - layout.size.height / 2f))
    }
}

// MARK: - Base map

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
 * grid showing. Dimmed so the position colours carry the meaning, like the muted dark MapKit map.
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
    var drewAny = false
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
            drewAny = true
        }
    }
    if (drewAny) drawRect(mapBackground.copy(alpha = 0.62f))
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
