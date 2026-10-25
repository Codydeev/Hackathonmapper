// Movement model runtime for Android (port of MovementModel.swift). Predicts where a person is
// likely to be h seconds from now, from where they were over the last 60 s and, with a v2
// model, from the map around them and where they planned to go. Used when a phone drops out of
// Bluetooth range: its last known track keeps moving as a growing cloud instead of a frozen dot.
// Plain Kotlin and kotlinx.serialization; only MapLayer.fromPng touches Android (BitmapFactory).
//
//   val model = MovementModel(json)                                   // movement-model.json text
//   val map = MovementModel.MapLayer.fromPng(pngBytes, metaJson)      // optional (v2)
//   val hist = model.history(track, now)                              // [(t, x, y)], seconds + metres
//   val pred = model.predict(hist, accuracy = 12.0, horizon = 60.0, map = map, destination = null)
//   val dots = pred.sample(300)                                       // for drawing
//
// Positions are metres in a flat frame. With a map they must be in the map's frame:
// MapLayer.toXY(lat, lon) converts GPS coordinates. Without a map any frame works (the demo's
// x/z floor plane, or east/north).

package com.hackathonmapper.meshmapper

import android.graphics.BitmapFactory
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.ln1p
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tanh

class MovementModel(json: String) {
    @Serializable
    data class Spec(
        val version: Int? = null,
        val K: Int,
        val histN: Int,
        val histStep: Double,
        val hMin: Double,
        val hMax: Double,
        val headingLookback: List<Int>,
        val headingMin: Double,
        val posScale: Double,
        val accScale: Double,
        val stdFloor: Double,
        val horizonScale: List<Double>,
        internal val layers: List<Layer>,
        internal val patch: PatchSpec? = null,
        internal val destFar: Double? = null,
        internal val cnn: List<ConvLayer>? = null,
        internal val cnnFc: Layer? = null,
    )

    @Serializable
    data class Layer(val w: List<List<Double>>, val b: List<Double>)

    @Serializable
    data class ConvLayer(val w: List<List<List<List<Double>>>>, val b: List<Double>, val stride: Int, val pad: Int)

    @Serializable
    data class PatchSpec(val size: Int, val res: Double, val ahead: Double)

    data class Point(var x: Double, var y: Double)

    data class TrackPoint(var t: Double, var x: Double, var y: Double)

    /** One 2×2 covariance: xx, xy, yy. */
    data class Cov(val xx: Double, val xy: Double, val yy: Double)

    /** The map image the model reads (R paths, G roads, B water) and its frame. */
    class MapLayer(rgb: IntArray, val meta: Meta) {
        @Serializable
        data class Meta(
            val lat0: Double,
            val lon0: Double,
            val xMin: Double,
            val yMax: Double,
            val res: Double,
            val width: Int,
            val height: Int,
        )

        /** width * height * 3 values 0–255, row by row from the north edge. */
        internal val pixels: IntArray = rgb

        init {
            require(rgb.size == meta.width * meta.height * 3)
        }

        companion object {
            /** Load the PNG exported next to its meta JSON (ml/export/maps/). */
            fun fromPng(png: ByteArray, metaJson: String): MapLayer {
                val meta = jsonFormat.decodeFromString(Meta.serializer(), metaJson)
                val bitmap = BitmapFactory.decodeByteArray(png, 0, png.size)
                    ?: throw IllegalArgumentException("map image does not decode")
                if (bitmap.width != meta.width || bitmap.height != meta.height) {
                    throw IllegalArgumentException("map image does not match its meta")
                }
                val argb = IntArray(meta.width * meta.height)
                bitmap.getPixels(argb, 0, meta.width, 0, 0, meta.width, meta.height)
                val rgb = IntArray(meta.width * meta.height * 3)
                for (i in argb.indices) {
                    val c = argb[i]
                    rgb[3 * i] = (c shr 16) and 255
                    rgb[3 * i + 1] = (c shr 8) and 255
                    rgb[3 * i + 2] = c and 255
                }
                return MapLayer(rgb, meta)
            }
        }

        /** GPS coordinates to this map's metre frame (x east, y north). */
        fun toXY(lat: Double, lon: Double): Point {
            val r = 6371000.0
            val rad = Math.PI / 180
            return Point(r * cos(meta.lat0 * rad) * (lon - meta.lon0) * rad, r * (lat - meta.lat0) * rad)
        }

        /** This map's metre frame back to GPS coordinates. */
        fun toLatLon(p: Point): Pair<Double, Double> {
            val r = 6371000.0
            val deg = 180 / Math.PI
            return Pair(meta.lat0 + p.y / r * deg, meta.lon0 + p.x / (r * cos(meta.lat0 / deg)) * deg)
        }

        internal fun value(row: Int, col: Int, ch: Int): Double {
            if (row < 0 || col < 0 || row >= meta.height || col >= meta.width) return 0.0
            return pixels[(row * meta.width + col) * 3 + ch] / 255.0
        }
    }

    /** A mixture of 2D Gaussians: where the person may be. */
    class Prediction(val weights: List<Double>, val means: List<Point>, val covs: List<Cov>) {
        /** Probability density per square metre at a point. */
        fun density(p: Point): Double {
            var sum = 0.0
            for (k in weights.indices) {
                val c = covs[k]
                val det = c.xx * c.yy - c.xy * c.xy
                val dx = p.x - means[k].x
                val dy = p.y - means[k].y
                val q = (c.yy * dx * dx - 2 * c.xy * dx * dy + c.xx * dy * dy) / det
                sum += weights[k] * exp(-q / 2) / (2 * Math.PI * sqrt(det))
            }
            return sum
        }

        /** Random positions from the prediction, for a cloud or a particle filter. */
        fun sample(n: Int, rng: RandomSource): List<Point> = (0 until n).map {
            var u = rng.nextUnit()
            var k = 0
            while (k < weights.size - 1 && u > weights[k]) {
                u -= weights[k]; k += 1
            }
            val c = covs[k]
            val l11 = sqrt(c.xx)
            val l21 = c.xy / l11
            val l22 = sqrt(max(0.0, c.yy - l21 * l21))
            val r = sqrt(-2 * ln(1 - rng.nextUnit()))
            val a = 2 * Math.PI * rng.nextUnit()
            val z1 = r * cos(a)
            val z2 = r * sin(a)
            Point(means[k].x + l11 * z1, means[k].y + l21 * z1 + l22 * z2)
        }

        fun sample(n: Int): List<Point> = sample(n, SystemRandomSource)
    }

    /**
     * Everything that does not depend on the horizon: make it once when the link drops, then
     * call predict(prepared, horizon) as time passes.
     */
    class Prepared internal constructor(
        internal val past: DoubleArray,
        internal val accuracy: Double,
        internal val has: Double,
        internal val th: Double,
        val origin: Point,
        internal val extra: DoubleArray,
        internal val emb: DoubleArray,
    )

    val spec: Spec = jsonFormat.decodeFromString(Spec.serializer(), json)

    // Weights as primitive arrays, so inference does not unbox every multiply.
    private val layerW: List<Array<DoubleArray>> = spec.layers.map { l -> Array(l.w.size) { l.w[it].toDoubleArray() } }
    private val layerB: List<DoubleArray> = spec.layers.map { it.b.toDoubleArray() }

    val usesMap: Boolean get() = spec.cnn != null

    /**
     * Positions every histStep seconds ending at `now`, oldest first, linearly interpolated from
     * reports sorted by time. Before the first report the person is assumed to have stood at the
     * first position.
     */
    fun history(track: List<TrackPoint>, now: Double): List<Point> {
        require(track.isNotEmpty())
        val out = ArrayList<Point>(spec.histN)
        var j = 0
        for (i in spec.histN - 1 downTo 0) {
            val t = now - i.toDouble() * spec.histStep
            while (j < track.size - 1 && track[j + 1].t <= t) j += 1
            val a = track[j]
            val b = track[min(j + 1, track.size - 1)]
            if (t <= a.t || j == track.size - 1) {
                out.add(Point(a.x, a.y))
            } else if (t >= b.t) {
                out.add(Point(b.x, b.y))
            } else {
                val f = (t - a.t) / (b.t - a.t)
                out.add(Point(a.x + f * (b.x - a.x), a.y + f * (b.y - a.y)))
            }
        }
        return out
    }

    /**
     * The map patch the model sees: rows from far ahead to behind, columns from left to right,
     * rotated so the walking direction points up.
     */
    internal fun samplePatch(map: MapLayer, origin: Point, th: Double): DoubleArray {
        val p = spec.patch!!
        val n = p.size
        val m = map.meta
        val out = DoubleArray(3 * n * n)
        val c = cos(th)
        val s = sin(th)
        for (r in 0 until n) {
            for (k in 0 until n) {
                val u = p.ahead + (n.toDouble() / 2 - (r.toDouble() + 0.5)) * p.res
                val v = (n.toDouble() / 2 - (k.toDouble() + 0.5)) * p.res
                val x = origin.x + c * u - s * v
                val y = origin.y + s * u + c * v
                val col = (x - m.xMin) / m.res - 0.5
                val row = (m.yMax - y) / m.res - 0.5
                val c0 = floor(col).toInt()
                val r0 = floor(row).toInt()
                val fc = col - c0
                val fr = row - r0
                for (ch in 0 until 3) {
                    out[(ch * n + r) * n + k] =
                        (1 - fr) * ((1 - fc) * map.value(r0, c0, ch) + fc * map.value(r0, c0 + 1, ch)) +
                        fr * ((1 - fc) * map.value(r0 + 1, c0, ch) + fc * map.value(r0 + 1, c0 + 1, ch))
                }
            }
        }
        return out
    }

    internal fun mapEmbedding(patch: DoubleArray): DoubleArray {
        var input = patch
        var channels = 3
        var h = spec.patch!!.size
        var w = h
        for (layer in spec.cnn!!) {
            val kSize = layer.w[0][0].size
            val outChannels = layer.b.size
            val ho = (h + 2 * layer.pad - kSize) / layer.stride + 1
            val wo = (w + 2 * layer.pad - kSize) / layer.stride + 1
            val out = DoubleArray(outChannels * ho * wo)
            for (o in 0 until outChannels) {
                for (y in 0 until ho) {
                    for (x in 0 until wo) {
                        var sum = layer.b[o]
                        for (c in 0 until channels) {
                            val wk = layer.w[o][c]
                            for (ky in 0 until kSize) {
                                val iy = y * layer.stride - layer.pad + ky
                                if (iy < 0 || iy >= h) continue
                                for (kx in 0 until kSize) {
                                    val ix = x * layer.stride - layer.pad + kx
                                    if (ix < 0 || ix >= w) continue
                                    sum += wk[ky][kx] * input[(c * h + iy) * w + ix]
                                }
                            }
                        }
                        out[(o * ho + y) * wo + x] = silu(sum)
                    }
                }
            }
            input = out; channels = outChannels; h = ho; w = wo
        }
        val fc = spec.cnnFc!!
        return DoubleArray(fc.b.size) { o ->
            var sum = fc.b[o]
            for (i in input.indices) sum += fc.w[o][i] * input[i]
            silu(sum)
        }
    }

    fun prepare(history: List<Point>, accuracy: Double, map: MapLayer? = null, destination: Point? = null): Prepared {
        val hist = history
        val n = spec.histN
        require(hist.size == n)
        val o = hist[n - 1]
        val d = hist.map { Point(it.x - o.x, it.y - o.y) }
        var th = 0.0
        var has = 0.0
        for (k in spec.headingLookback) {
            val vx = -d[n - 1 - k].x
            val vy = -d[n - 1 - k].y
            if (sqrt(vx * vx + vy * vy) >= spec.headingMin) {
                th = atan2(vy, vx); has = 1.0; break
            }
        }
        val c = cos(th)
        val s = sin(th)
        val past = DoubleArray(2 * (n - 1))
        for (i in 0 until n - 1) {
            past[2 * i] = (c * d[i].x + s * d[i].y) / spec.posScale
            past[2 * i + 1] = (-s * d[i].x + c * d[i].y) / spec.posScale
        }
        var extra = DoubleArray(0)
        var emb = DoubleArray(0)
        if (usesMap) {
            val list = if (destination != null) {
                val dx = destination.x - o.x
                val dy = destination.y - o.y
                val u = c * dx + s * dy
                val v = -s * dx + c * dy
                val dist = max(sqrt(u * u + v * v), 1e-6)
                mutableListOf(u / dist, v / dist, ln1p(dist) / ln1p(spec.destFar!!), 1.0)
            } else {
                mutableListOf(0.0, 0.0, 0.0, 0.0)
            }
            list.add(if (map == null) 0.0 else 1.0)
            extra = list.toDoubleArray()
            emb = if (map != null) mapEmbedding(samplePatch(map, o, th)) else DoubleArray(spec.cnnFc!!.b.size)
        }
        return Prepared(past, accuracy, has, th, o, extra, emb)
    }

    fun predict(prepared: Prepared, horizon: Double): Prediction {
        val p = prepared
        val h = min(spec.hMax, max(spec.hMin, horizon))
        var x = p.past + doubleArrayOf(ln(h) / ln(spec.hMax), sqrt(h / spec.hMax), p.accuracy / spec.accScale, p.has) +
            p.extra + p.emb
        for (li in layerW.indices) {
            val w = layerW[li]
            val out = layerB[li].copyOf()
            for (o in out.indices) {
                val row = w[o]
                var sum = out[o]
                for (i in x.indices) sum += row[i] * x[i]
                out[o] = if (li < layerW.size - 1) silu(sum) else sum
            }
            x = out
        }
        val scale = spec.horizonScale[0] + spec.horizonScale[1] * h
        val c = cos(p.th)
        val s = sin(p.th)
        val o = p.origin
        val logits = ArrayList<Double>(spec.K)
        val means = ArrayList<Point>(spec.K)
        val covs = ArrayList<Cov>(spec.K)
        for (k in 0 until spec.K) {
            val q = x.copyOfRange(6 * k, 6 * k + 6)
            logits.add(q[0])
            val mx = q[1] * scale
            val my = q[2] * scale
            val sx = spec.stdFloor + exp(min(3.0, max(-7.0, q[3]))) * scale
            val sy = spec.stdFloor + exp(min(3.0, max(-7.0, q[4]))) * scale
            val r = 0.95 * tanh(q[5])
            means.add(Point(o.x + c * mx - s * my, o.y + s * mx + c * my))
            val xx = sx * sx
            val yy = sy * sy
            val xy = r * sx * sy
            covs.add(
                Cov(
                    c * c * xx - 2 * c * s * xy + s * s * yy,
                    c * s * (xx - yy) + (c * c - s * s) * xy,
                    s * s * xx + 2 * c * s * xy + c * c * yy,
                ),
            )
        }
        val m = logits.max()
        val e = logits.map { exp(it - m) }
        val z = e.fold(0.0) { a, b -> a + b }
        return Prediction(e.map { it / z }, means, covs)
    }

    /**
     * history: spec.histN positions, spec.histStep s apart, oldest first.
     * accuracy: accuracyMeters of those positions. horizon: seconds ahead.
     * map, destination: optional, used by v2 models.
     */
    fun predict(
        history: List<Point>,
        accuracy: Double,
        horizon: Double,
        map: MapLayer? = null,
        destination: Point? = null,
    ): Prediction = predict(prepare(history, accuracy, map, destination), horizon)

    companion object {
        internal val jsonFormat = Json { ignoreUnknownKeys = true }

        internal fun silu(v: Double): Double = v / (1 + exp(-v))
    }
}

/**
 * Swift's `RandomNumberGenerator` with `Double.random(in: 0..<1, using:)`: a 64-bit source whose
 * unit values take the low 53 bits, exactly like the Swift standard library, so a seeded
 * generator gives the same doubles on both platforms.
 */
interface RandomSource {
    fun next(): ULong

    /** `Double.random(in: 0..<1, using: &self)`. */
    fun nextUnit(): Double = (next() and ((1uL shl 53) - 1uL)).toLong().toDouble() * (Math.ulp(1.0) / 2)
}

/** Swift's `SystemRandomNumberGenerator`. */
object SystemRandomSource : RandomSource {
    private val random = java.security.SecureRandom()
    override fun next(): ULong = random.nextLong().toULong()
}
