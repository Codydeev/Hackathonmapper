package com.hackathonmapper.meshmapper

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ApplicationInfo
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hackathonmapper.meshcore.FloorPoint
import com.hackathonmapper.meshcore.GeoFrame
import com.hackathonmapper.meshcore.IntegrityAssessment
import com.hackathonmapper.meshcore.MeshJson
import com.hackathonmapper.meshcore.PeerObservation
import com.hackathonmapper.meshcore.PositionEstimate
import com.hackathonmapper.meshcore.Prediction
import java.io.File

/**
 * Development only: draws the contract's golden records (contract/fixtures) through
 * `VizScene.contract`, to check the map on an emulator without phones. It never feeds the pipeline,
 * and the map shows a FIXTURE banner the whole time.
 *
 * iOS reads launch arguments and the fixtures next to the source file; on Android it is reachable
 * only in a debuggable build, through launch-intent extras, with the fixtures pushed to the app's
 * external files directory:
 *
 * ```
 * adb push contract/fixtures/. /sdcard/Android/data/com.hackathonmapper.meshmapper/files/fixtures/
 * adb shell am start -n com.hackathonmapper.meshmapper/.MainActivity --es GhostFixturePreview predicted
 * ```
 *
 * Extras: `GhostFixturePreview estimate|predicted`, `GhostFixtureOpen <phone id>|simulation|self`
 * (opens that phone's explainer or the simulation panel at launch, for screenshots) and
 * `GhostAutoInject jump|drift|outage` (presses that simulation-panel button 15 s after launch, the
 * same hub.inject call, so a live-pipeline run can be checked unattended).
 */
object FixturePreview {
    var stage: String? = null
        private set
    var open: String? = null
        private set
    var autoInject: VizScenarioControls.GNSSFault? = null
        private set
    private var configured = false
    private var directory: File? = null
    private val scenes = mutableMapOf<String, VizScene?>()

    /** Reads the launch extras once, in debuggable builds only (iOS compiles this out of Release). */
    fun configure(context: Context) {
        if (configured) return
        configured = true
        if (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) return
        val intent = context.findActivity()?.intent ?: return
        stage = intent.getStringExtra("GhostFixturePreview")
        open = intent.getStringExtra("GhostFixtureOpen")
        autoInject = mapOf(
            "jump" to VizScenarioControls.GNSSFault.jump,
            "drift" to VizScenarioControls.GNSSFault.drift,
            "outage" to VizScenarioControls.GNSSFault.outage,
        )[intent.getStringExtra("GhostAutoInject")]
        directory = context.getExternalFilesDir("fixtures")
        if (stage != null) appContext = context.applicationContext
    }

    private var appContext: Context? = null

    /** The fixture scene for `stage`, or null when the fixtures are not on the device. */
    fun scene(stage: String): VizScene? = scenes.getOrPut(stage) {
        val dir = directory ?: return@getOrPut null
        scene(stage) { name -> File(dir, "$name.json").takeIf { it.isFile }?.readText() }
    }

    /**
     * The section 1 story from the fixtures: A trusted GNSS, B placed over Bluetooth ("estimate") or
     * predicted ("predicted"), C's raw GNSS rejected for a 412 m jump. `load` returns a fixture's
     * JSON by name (e.g. "integrity-trusted").
     */
    fun scene(stage: String, load: (String) -> String?): VizScene? {
        val trusted = load("integrity-trusted")?.let { decode<IntegrityAssessment>(it) } ?: return null
        val rejected = load("integrity-rejected-jump")?.let { decode<IntegrityAssessment>(it) } ?: return null
        val bluetooth = load("position-ble-ambiguous")?.let { decode<PositionEstimate>(it) } ?: return null
        val prediction = load("prediction-kalman")?.let { decode<Prediction>(it) } ?: return null
        val observation = load("peer-observation")?.let { decode<PeerObservation>(it) } ?: return null

        val now = listOf(trusted.timestamp, rejected.timestamp, bluetooth.timestamp, prediction.timestamp).max() + 2
        val input = VizContractInputs(selfId = "phone-a", frameId = GeoFrame.defaultFrameId, now = now)
        input.labels.putAll(mapOf("phone-a" to "Otter 42", "phone-b" to "Lynx 17", "phone-c" to "Pike 31"))
        input.integrity["phone-a"] = trusted
        input.integrity["phone-c"] = rejected
        trusted.evaluatedFix?.let { input.positions["phone-a"] = it }
        trusted.evaluatedFix?.let { input.rawFixes["phone-a"] = it }
        rejected.evaluatedFix?.let { input.rawFixes["phone-c"] = it }
        when (stage) {
            "predicted" -> {
                input.predictions["phone-b"] = prediction
                // The fixture's last spot is inside Tietotalo, where the route model (correctly) finds no
                // path; the made-up walk ends on the path north of it instead.
                likelyPaths(FloorPoint(0.0, 60.0), now - prediction.lastObservedAt)?.let { input.likelyPaths["phone-b"] = it }
            }
            else -> {
                input.positions["phone-b"] = bluetooth
                input.observations = listOf(observation)
            }
        }
        return VizScene.contract(input)
    }

    private inline fun <reified T> decode(text: String): T? = try {
        MeshJson.decodeFromString<T>(text)
    } catch (_: Exception) {
        null
    }

    private val routeModel: RouteModel? by lazy {
        val context = appContext ?: return@lazy null
        try {
            val tables = context.assets.open("route-model.json").use { it.readBytes() }
            val graph = context.assets.open("hervanta-graph.json").use { it.readBytes() }
            RouteModel(model = tables, graph = graph)
        } catch (_: Exception) {
            null
        }
    }
    private val pathsCache = mutableMapOf<String, VizLikelyPaths?>()

    /**
     * The real route model run on a made-up 60 s walk north at 1.3 m/s into `last`, the fixture's
     * last observed spot. Only the input track is invented; the routes are the model's output.
     */
    fun likelyPaths(last: FloorPoint, horizon: Double): VizLikelyPaths? {
        val key = "${last.x},${last.z},${horizon.toInt()}"
        if (pathsCache.containsKey(key)) return pathsCache[key]
        val model = routeModel ?: return null
        val frame = GeoFrame.defaultFrameId
        val track = (0..60).mapNotNull { i ->
            val c = GeoFrame.coordinate(frame, last.x, last.z - 1.3 * (60 - i)) ?: return@mapNotNull null
            val p = model.toXY(lat = c.latitude, lon = c.longitude)
            MovementModel.TrackPoint(t = i.toDouble(), x = p.x, y = p.y)
        }
        val prediction = model.predict(track = track, now = 60.0, accuracy = 8.0)
        fun floor(p: MovementModel.Point): FloorPoint? {
            val (lat, lon) = model.toLatLon(p)
            return GeoFrame.position(frame, lat, lon)?.let { FloorPoint(it.x, it.z) }
        }
        val options = prediction.routes.zip(model.whereAlong(prediction, seconds = horizon)).take(4).mapIndexed { rank, (route, marker) ->
            VizLikelyPath(
                rank = rank, probability = route.p, text = route.text, line = route.line.mapNotNull { floor(it) },
                here = floor(marker.point), band = marker.band.mapNotNull { floor(it) },
            )
        }
        val paths = if (options.isEmpty()) null else VizLikelyPaths(options, prediction.offPath)
        pathsCache[key] = paths
        return paths
    }
}

private fun Context.findActivity(): Activity? {
    var c: Context? = this
    while (c is ContextWrapper) {
        if (c is Activity) return c
        c = c.baseContext
    }
    return null
}

/** Red banner over the map while fixtures are shown. */
@Composable
fun FixtureBanner(modifier: Modifier = Modifier) {
    Text(
        "FIXTURE PREVIEW · NOT LIVE · DEBUG BUILD",
        style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Black, textAlign = TextAlign.Center),
        color = Color.White,
        modifier = modifier
            .fillMaxWidth()
            .background(GhostTheme.rejected, RoundedCornerShape(10.dp))
            .padding(vertical = 6.dp),
    )
}

/** Android Studio preview of the fixed GhostUI chrome (the fixture scene needs the records on a device). */
@Preview(showBackground = true, backgroundColor = 0xFF000000)
@Composable
private fun GhostChromePreview() {
    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        FixtureBanner()
        SimulationBanner(VizScenarioState("S5 · Walk out of range", 42.0, 3, null, true), stop = {})
        GhostLegend(integrityConnected = true)
        GhostLegend(integrityConnected = false)
    }
}
