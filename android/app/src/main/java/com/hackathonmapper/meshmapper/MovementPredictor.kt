package com.hackathonmapper.meshmapper

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.hackathonmapper.meshcore.FloorPoint
import com.hackathonmapper.meshcore.GeoFrame
import com.hackathonmapper.meshcore.currentTime
import kotlin.math.max
import kotlin.math.min

/**
 * Keeps each phone's recent track and, when Bluetooth loses a phone, predicts where it has
 * probably walked since, with two on-device models trained on walking tracks around Hervanta:
 * - the movement model (v2): a cloud that grows with time, instead of a dot frozen at the last spot;
 * - the route model (v3, walks the bundled path graph): 2-4 routes with percentages ("65 % straight
 *   on at the fork in 240 m") and where along each one they probably are by now.
 */
class MovementPredictor(context: Context) {
    data class Cloud(
        val id: String,
        /** Most likely spot (weighted mean of the mixture). */
        val center: FloorPoint,
        val points: List<FloorPoint>,
        /** Seconds since the phone was last placed. */
        val horizon: Double,
    )

    data class RouteOption(
        /** Rank, 0 = most likely. */
        val id: Int,
        val probability: Double,
        val text: String,
        val line: List<FloorPoint>,
        /** Where along this route they probably are by now (median), and the 10-90 % stretch. */
        val here: FloorPoint?,
        val band: List<FloorPoint>,
    )

    data class Routes(
        val options: List<RouteOption>,
        /** Chance they left the paths altogether. */
        val offPath: Double,
    )

    /** Swift's `(t: Double, point: FloorPoint)` track sample. */
    private data class TrackSample(val t: Double, val point: FloorPoint)

    /** Swift's `(t: Double, accuracy: Double)`. */
    private data class Placed(val t: Double, val accuracy: Double)

    private class Cached<T>(val placedAt: Double, val value: T)

    companion object {
        /** Seconds of track kept per phone; the models read the last 60 s. */
        const val trackSeconds: Double = 120.0
        const val cloudPoints = 80
        const val maxRoutes = 4

        /**
         * Whether the model also reads the map patch around the person. Off: on held-out Hervanta the
         * map made the cloud sharper (37 m vs 43 m median error at 1 min, mesh history) but too tight,
         * holding its 90% area only 77-85% of the time against 83-88% without it (ml/README.md).
         * The map is still used to convert positions; the route model is where the paths count.
         */
        const val readsMap = false
    }

    var clouds: Map<String, Cloud> by mutableStateOf(emptyMap())
        private set
    var routes: Map<String, Routes> by mutableStateOf(emptyMap())
        private set

    private val model: MovementModel?

    /** The map the movement model reads (ml/export/maps/hervanta), in its own metre frame. */
    private val map: MovementModel.MapLayer?

    /** Loaded in the background: the path graph is 4 MB. */
    private var routeModel: RouteModel? = null
    private var tracks: MutableMap<String, List<TrackSample>> = mutableMapOf()
    private var lastPlaced: MutableMap<String, Placed> = mutableMapOf()

    /** The horizon-independent parts, made once per dropout. */
    private var prepared: MutableMap<String, Cached<MovementModel.Prepared>> = mutableMapOf()
    private var routePredictions: MutableMap<String, Cached<RouteModel.Prediction>> = mutableMapOf()

    init {
        val assets = context.applicationContext.assets
        fun resource(name: String): ByteArray? = try {
            assets.open(name).use { it.readBytes() }
        } catch (e: Exception) {
            null
        }
        val model = resource("movement-model-v2.json")?.let {
            try {
                MovementModel(it.decodeToString())
            } catch (e: Exception) {
                null
            }
        }
        this.model = model
        // Without the map the v2 model still runs; it was trained to know when the map is missing.
        val png = if (model?.usesMap == true) resource("hervanta-map.png") else null
        val meta = if (png != null) resource("hervanta-map.json") else null
        map = if (png != null && meta != null) {
            try {
                MovementModel.MapLayer.fromPng(png, meta.decodeToString())
            } catch (e: Exception) {
                null
            }
        } else {
            null
        }
        // Reading the graph takes a few hundred milliseconds on a phone: keep it off the main thread.
        val main = Handler(Looper.getMainLooper())
        Thread {
            val tables = resource("route-model.json")
            val graph = resource("hervanta-graph.json")
            val loaded = if (tables != null && graph != null) {
                try {
                    RouteModel(model = tables, graph = graph)
                } catch (e: Exception) {
                    null
                }
            } else {
                null
            }
            if (loaded != null) main.post { routeModel = loaded }
        }.apply { priority = Thread.MIN_PRIORITY; isDaemon = true }.start()
    }

    val isAvailable: Boolean get() = model != null

    fun reset() {
        tracks = mutableMapOf()
        lastPlaced = mutableMapOf()
        prepared = mutableMapOf()
        routePredictions = mutableMapOf()
        clouds = emptyMap()
        routes = emptyMap()
    }

    /**
     * `frameId` is the shared frame of the tracker's points; the map and the path graph are only
     * used when that frame has a GPS origin, since points are converted through latitude and longitude.
     */
    fun update(phones: List<TrackedPhone>, frameId: String, now: Double = currentTime()) {
        val t = now
        val anchored = GeoFrame.origins[frameId] != null
        val map = if (anchored) this.map else null
        val newClouds = mutableMapOf<String, Cloud>()
        val newRoutes = mutableMapOf<String, Routes>()
        for (phone in phones) {
            when (phone.state) {
                is TrackedPhone.State.placed, TrackedPhone.State.estimated -> {
                    val point = phone.point ?: continue
                    val track = ((tracks[phone.id] ?: emptyList()) + TrackSample(t, point)).filter { t - it.t <= trackSeconds }
                    tracks[phone.id] = track
                    lastPlaced[phone.id] = Placed(t, min(max(phone.radius ?: 5.0, 3.0), 30.0))
                    prepared.remove(phone.id)
                    routePredictions.remove(phone.id)
                }
                TrackedPhone.State.lastSeen -> {
                    val track = tracks[phone.id]
                    if (track.isNullOrEmpty()) continue
                    val placed = lastPlaced[phone.id] ?: continue
                    val horizon = t - placed.t
                    val model = model
                    if (model != null) {
                        newClouds[phone.id] = cloud(phone.id, model, map, track, placed, horizon, frameId)
                    }
                    val routeModel = routeModel
                    if (anchored && routeModel != null) {
                        val found = routeOptions(phone.id, routeModel, track, placed, horizon, frameId)
                        if (found != null) newRoutes[phone.id] = found
                    }
                }
                TrackedPhone.State.unplaced -> continue
            }
        }
        clouds = newClouds
        routes = newRoutes
    }

    private fun cloud(
        id: String,
        model: MovementModel,
        map: MovementModel.MapLayer?,
        track: List<TrackSample>,
        placed: Placed,
        horizon: Double,
        frameId: String,
    ): Cloud {
        val cached = prepared[id]
        val ready: MovementModel.Prepared
        if (cached != null && cached.placedAt == placed.t) {
            ready = cached.value
        } else {
            val modelTrack = track.map { trackPoint(it.t, toModel(it.point, frameId, map)) }
            val history = model.history(modelTrack, placed.t)
            ready = model.prepare(history, placed.accuracy, if (readsMap) map else null)
            prepared[id] = Cached(placed.t, ready)
        }
        val prediction = model.predict(ready, horizon)
        // Same seed every second, so the dots drift as the cloud grows instead of flickering.
        val rng = SplitMix64(id.hashCode().toLong().toULong())
        val points = prediction.sample(cloudPoints, rng).map { fromModel(it, frameId, map) }
        var cx = 0.0
        var cy = 0.0
        for ((w, m) in prediction.weights.zip(prediction.means)) {
            cx += w * m.x; cy += w * m.y
        }
        return Cloud(id, fromModel(MovementModel.Point(cx, cy), frameId, map), points, horizon)
    }

    private fun routeOptions(
        id: String,
        routeModel: RouteModel,
        track: List<TrackSample>,
        placed: Placed,
        horizon: Double,
        frameId: String,
    ): Routes? {
        val cached = routePredictions[id]
        val prediction: RouteModel.Prediction
        if (cached != null && cached.placedAt == placed.t) {
            prediction = cached.value
        } else {
            val graphTrack = track.mapNotNull { sample ->
                val c = GeoFrame.coordinate(frameId, sample.point.x, sample.point.z) ?: return@mapNotNull null
                trackPoint(sample.t, routeModel.toXY(c.latitude, c.longitude))
            }
            if (graphTrack.isEmpty()) return null
            prediction = routeModel.predict(graphTrack, placed.t, placed.accuracy)
            routePredictions[id] = Cached(placed.t, prediction)
        }
        fun floor(p: MovementModel.Point): FloorPoint? {
            val c = routeModel.toLatLon(p)
            return GeoFrame.position(frameId, c.lat, c.lon)?.let { FloorPoint(it.x, it.z) }
        }
        val markers = routeModel.whereAlong(prediction, horizon)
        val options = prediction.routes.zip(markers).take(maxRoutes).mapIndexed { rank, pair ->
            RouteOption(
                id = rank, probability = pair.first.p, text = pair.first.text, line = pair.first.line.mapNotNull { floor(it) },
                here = floor(pair.second.point), band = pair.second.band.mapNotNull { floor(it) },
            )
        }
        return if (options.isEmpty()) null else Routes(options, prediction.offPath)
    }

    /**
     * Tracker frame (x east, z north) to the map's frame (x east, y north), through GPS coordinates.
     * Without a map the model only needs relative positions, so the point is used as it is.
     */
    private fun toModel(p: FloorPoint, frameId: String, map: MovementModel.MapLayer?): MovementModel.Point {
        if (map == null) return MovementModel.Point(p.x, p.z)
        val c = GeoFrame.coordinate(frameId, p.x, p.z) ?: return MovementModel.Point(p.x, p.z)
        return map.toXY(c.latitude, c.longitude)
    }

    private fun fromModel(p: MovementModel.Point, frameId: String, map: MovementModel.MapLayer?): FloorPoint {
        if (map == null) return FloorPoint(p.x, p.y)
        val (lat, lon) = map.toLatLon(p)
        val q = GeoFrame.position(frameId, lat, lon) ?: return FloorPoint(p.x, p.y)
        return FloorPoint(q.x, q.z)
    }

    /** Swift's private `MovementModel.TrackPoint(t:point:)` initializer. */
    private fun trackPoint(t: Double, point: MovementModel.Point) = MovementModel.TrackPoint(t, point.x, point.y)
}

/** Small deterministic generator for stable cloud dots (bit-exact with the Swift SplitMix64). */
class SplitMix64(seed: ULong) : RandomSource {
    private var state: ULong = seed

    override fun next(): ULong {
        state += 0x9E3779B97F4A7C15uL
        var z = state
        z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9uL
        z = (z xor (z shr 27)) * 0x94D049BB133111EBuL
        return z xor (z shr 31)
    }
}
