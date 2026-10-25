// Route filter (port of ml/runtime/RouteFilter.swift, itself a port of route-filter.js): the route
// model's prediction, sharpened by signals that arrive after the Bluetooth link drops: Bluetooth
// readings of the lost phone and the lost phone's own pedometer and compass. The iOS app does not
// use it yet (ml/README.md), so on Android it lives with the tests that replay its golden cases
// (RouteFilterTests) instead of in the app.
//
//   val f = RouteFilter(routes, particles = 400)
//   val s = f.start(history = hist, accuracy = 12.0)         // when the link drops (t = 0)
//   f.advance(s, to = 30.0)                                  // seconds since then
//   f.observeBluetooth(s, listener = p, listenerAcc = 5.0, rssi = -78.0)
//   f.observeSteps(s, dx = dx, dy = dy, seconds = 10.0)      // pedometer displacement since the last call
//   val est = f.estimate(s)                                  // center, r95, cloud

package com.hackathonmapper.meshmapper

import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/** The same 32-bit generator as the JS (mulberry32), so both runtimes can replay identical cases. */
class Mulberry32(seed: UInt) {
    private var a: UInt = seed

    fun next(): Double {
        a += 0x6D2B79F5u
        var t = (a xor (a shr 15)) * (1u or a)
        t = (t + ((t xor (t shr 7)) * (61u or t))) xor t
        return (t xor (t shr 14)).toDouble() / 4_294_967_296.0
    }
}

class RouteFilter(routes: RouteModel, particles: Int = 400, seed: UInt = 1u) {
    data class Estimate(
        val center: MovementModel.Point,
        val r95: Double,
        val share: Double,
        val cloud: List<MovementModel.Point>,
    )

    /** Swift's `State` struct; `copyOf()` stands in for its value copies. */
    class State internal constructor(
        val n: Int,
        /** Log-normal pace curve for the walker's speed bin. */
        internal val l50: List<Double>,
        internal val sig: List<Double>,
    ) {
        var t = 0.0
            internal set
        internal var d = IntArray(n) { -1 }
        internal var at = DoubleArray(n)
        internal var z = DoubleArray(n)
        internal var walked = DoubleArray(n)
        internal var off = BooleanArray(n)
        internal var x = DoubleArray(n)
        internal var y = DoubleArray(n)
        internal var th = DoubleArray(n)
        internal var ax = DoubleArray(n)
        internal var ay = DoubleArray(n)
        internal var w = DoubleArray(n) { 1 / n.toDouble() }
        internal var pdr = false
        internal var bias = DoubleArray(0)
        internal var scale = DoubleArray(0)

        internal fun copyOf(): State {
            val s = State(n, l50, sig)
            s.t = t; s.d = d.copyOf(); s.at = at.copyOf(); s.z = z.copyOf(); s.walked = walked.copyOf()
            s.off = off.copyOf(); s.x = x.copyOf(); s.y = y.copyOf(); s.th = th.copyOf(); s.ax = ax.copyOf()
            s.ay = ay.copyOf(); s.w = w.copyOf(); s.pdr = pdr; s.bias = bias.copyOf(); s.scale = scale.copyOf()
            return s
        }
    }

    /** MeshCore BluetoothEstimator.RadioModel.outdoors (Swift: a tuple). */
    data class Radio(val p0: Double, val n: Double, val sigma: Double, val range: Double, val soft: Double)

    private object Pdr {
        const val biasDeg = 10.0
        const val scale = 0.08
        const val driftDeg = 0.4
        const val noise = 0.4
        const val onPathM = 6.0
        const val offPath = 0.08
    }

    companion object {
        const val step = 2.0
        const val paceTau = 120.0
        const val offTurn = 0.35
    }

    var radio = Radio(p0 = -59.0, n = 2.5, sigma = 5.0, range = 60.0, soft = 8.0)

    private val rm = routes
    private val count = particles
    private val rng = Mulberry32(seed)
    private val offRate = -ln(1 - RouteModel.interp(routes.offT, routes.offOn, 600.0)) / 600

    private fun rand(): Double = rng.next()

    private fun gauss(): Double {
        var u = 0.0
        while (u == 0.0) u = rand()
        return sqrt(-2 * ln(u)) * cos(2 * Math.PI * rand())
    }

    /** The pace curve for a speed bin: log-normal through the measured 10/50/90% quantiles. */
    private fun paceCurve(bin: Int): Pair<List<Double>, List<Double>> {
        fun row(q: String) = rm.q[q]!![bin].map { ln(max(it, 0.5)) }
        val l10 = row("q10")
        val l50 = row("q50")
        val l90 = row("q90")
        return Pair(l50, l10.zip(l90).map { (a, b) -> max(0.05, (b - a) / (2 * 1.2816)) })
    }

    /** Distance walked by time t at pace score z. */
    private fun distance(s: State, z: Double, t: Double): Double =
        if (t <= 0) 0.0 else exp(RouteModel.interp(rm.tGrid, s.l50, t) + RouteModel.interp(rm.tGrid, s.sig, t) * z)

    fun start(history: List<MovementModel.Point>, accuracy: Double): State {
        val hist = history
        val n = hist.size
        val last = hist[n - 1]
        val first = hist[0]
        val v = hypot(last.x - first.x, last.y - first.y) / ((n - 1).toDouble() * 2)
        val loc = rm.locate(hist, accuracy)
        val total = loc.starts.fold(0.0) { a, s -> a + s.p }
        val pace = paceCurve(rm.speedBin(v))
        val s = State(count, pace.first, pace.second)
        val offShare = if (loc.offNow || loc.starts.isEmpty()) (if (loc.starts.isEmpty()) 1.0 else 0.6) else 0.0
        for (i in 0 until s.n) {
            s.z[i] = gauss()
            if (rand() < offShare) {
                s.off[i] = true; s.d[i] = -1
                s.x[i] = last.x + 3 * gauss(); s.y[i] = last.y + 3 * gauss()
                s.th[i] = if (loc.moved) loc.th + 0.3 * gauss() else 2 * Math.PI * rand()
            } else {
                var u = rand() * total
                var k = 0
                while (k < loc.starts.size - 1 && u > loc.starts[k].p) {
                    u -= loc.starts[k].p; k += 1
                }
                s.d[i] = loc.starts[k].d; s.at[i] = loc.starts[k].s
                val p = rm.at(s.d[i], s.at[i])
                s.x[i] = p.x; s.y[i] = p.y
            }
            s.ax[i] = s.x[i]; s.ay[i] = s.y[i]
        }
        return s
    }

    private fun move(s: State, i: Int, distance: Double) {
        if (s.off[i]) {
            s.th[i] += offTurn * gauss()
            s.x[i] += distance * cos(s.th[i]); s.y[i] += distance * sin(s.th[i])
            return
        }
        var d = s.d[i]
        var at = s.at[i]
        var dist = distance
        var guardCount = 0
        while (dist > 0 && guardCount < 50) {
            guardCount += 1
            val rem = rm.len[d shr 1] - at
            if (dist < rem) {
                at += dist; dist = 0.0; break
            }
            dist -= rem
            val o0 = rm.turnOff[d]
            val o1 = rm.turnOff[d + 1]
            if (o0 == o1) {
                at = rm.len[d shr 1]; break
            }
            var u = rand()
            var k = o0
            while (k < o1 - 1 && u > rm.turnP[k]) {
                u -= rm.turnP[k]; k += 1
            }
            d = rm.turnTo[k]; at = 0.0
        }
        s.d[i] = d; s.at[i] = at
        val p = rm.at(d, at)
        s.x[i] = p.x; s.y[i] = p.y
    }

    /** Propagate to t seconds since the link dropped. Once the lost phone's steps are known, the steps move the particles. */
    fun advance(s: State, to: Double) {
        val t = to
        if (s.pdr) {
            s.t = max(s.t, t); return
        }
        val rho = exp(-step / paceTau)
        val k = sqrt(1 - rho * rho)
        while (s.t < t - 1e-9) {
            val t1 = min(t, s.t + step)
            val dt = t1 - s.t
            for (i in 0 until s.n) {
                s.z[i] = rho * s.z[i] + k * gauss()
                val target = distance(s, s.z[i], t1)
                val stepLength = target - s.walked[i]
                if (!s.off[i] && rand() < offRate * dt) {
                    s.off[i] = true; s.th[i] = 2 * Math.PI * rand()
                }
                if (stepLength > 0) {
                    move(s, i, stepLength); s.walked[i] = target
                }
            }
            s.t = t1
        }
    }

    private fun normalize(s: State) {
        val sum = s.w.fold(0.0) { a, b -> a + b }
        if (!(sum > 0)) {
            s.w = DoubleArray(s.n) { 1 / s.n.toDouble() }; return
        }
        var ess = 0.0
        for (i in 0 until s.n) {
            s.w[i] /= sum; ess += s.w[i] * s.w[i]
        }
        if (1 / ess < s.n.toDouble() / 2) resample(s)
    }

    /** Systematic resampling; copies keep their pace with a little jitter. */
    private fun resample(s: State) {
        val old = s.copyOf()
        var c = s.w[0]
        var j = 0
        val u0 = rand() / s.n.toDouble()
        for (i in 0 until s.n) {
            val u = u0 + i.toDouble() / s.n.toDouble()
            while (u > c && j < s.n - 1) {
                j += 1; c += old.w[j]
            }
            s.d[i] = old.d[j]; s.at[i] = old.at[j]; s.z[i] = old.z[j]; s.walked[i] = old.walked[j]; s.off[i] = old.off[j]
            s.x[i] = old.x[j]; s.y[i] = old.y[j]; s.th[i] = old.th[j]; s.ax[i] = old.ax[j]; s.ay[i] = old.ay[j]
            if (s.pdr) {
                s.bias[i] = old.bias[j]; s.scale[i] = old.scale[j]
            }
            s.z[i] += 0.1 * gauss()
            if (s.pdr) {
                s.bias[i] += 0.01 * gauss(); s.scale[i] += 0.005 * gauss()
            }
        }
        s.w = DoubleArray(s.n) { 1 / s.n.toDouble() }
    }

    private fun hearProb(d: Double): Double = 1 / (1 + exp((d - radio.range) / radio.soft))

    /** A phone at `listener` (± listenerAcc m) heard the lost phone at `rssi` dBm. */
    fun observeBluetooth(s: State, listener: MovementModel.Point, listenerAcc: Double = 5.0, rssi: Double, sigmaDb: Double? = null) {
        val sigma = sigmaDb ?: radio.sigma
        for (i in 0 until s.n) {
            val d = max(0.5, hypot(s.x[i] - listener.x, s.y[i] - listener.y))
            val expected = radio.p0 - 10 * radio.n * log10(d)
            val sens = 10 * radio.n / (ln(10.0) * max(d, 1.0))
            val v = sigma * sigma + Math.pow(sens * listenerAcc, 2.0)
            s.w[i] *= exp(-Math.pow(rssi - expected, 2.0) / (2 * v)) / sqrt(v) * hearProb(d)
        }
        normalize(s)
    }

    /** The lost phone's own pedometer and compass: displacement summed over the last `seconds`. */
    fun observeSteps(s: State, dx: Double, dy: Double, seconds: Double = 10.0) {
        if (!s.pdr) {
            s.pdr = true
            s.bias = DoubleArray(s.n) { Pdr.biasDeg * Math.PI / 180 * gauss() }
            s.scale = DoubleArray(s.n) { 1 + Pdr.scale * gauss() }
        }
        val drift = Pdr.driftDeg * Math.PI / 180 * sqrt(seconds)
        for (i in 0 until s.n) {
            s.bias[i] += drift * gauss()
            val c = cos(s.bias[i])
            val sn = sin(s.bias[i])
            val k = s.scale[i]
            s.x[i] += k * (c * dx - sn * dy) + Pdr.noise * gauss()
            s.y[i] += k * (sn * dx + c * dy) + Pdr.noise * gauss()
            val d = min(rm.nearestDist(MovementModel.Point(s.x[i], s.y[i]), 3 * Pdr.onPathM), 3 * Pdr.onPathM)
            s.w[i] *= exp(-(d * d) / (2 * Pdr.onPathM * Pdr.onPathM)) + Pdr.offPath
        }
        normalize(s)
    }

    /** Best single position: the heaviest 25 m neighbourhood, its weighted centre, and the radius holding 95% of the weight. */
    fun estimate(s: State, cloudSize: Int = 80): Estimate {
        val cell = 12.0
        val cells = LinkedHashMap<Pair<Int, Int>, Double>()
        for (i in 0 until s.n) {
            val key = Pair(floor(s.x[i] / cell).toInt(), floor(s.y[i] / cell).toInt())
            cells[key] = (cells[key] ?: 0.0) + s.w[i]
        }
        var best = MovementModel.Point(0.0, 0.0)
        var bestW = -1.0
        for (key in cells.keys) {
            var w = 0.0
            for (da in -1..1) for (db in -1..1) w += cells[Pair(key.first + da, key.second + db)] ?: 0.0
            if (w > bestW) {
                bestW = w; best = MovementModel.Point((key.first + 0.5) * cell, (key.second + 0.5) * cell)
            }
        }
        var cx = 0.0
        var cy = 0.0
        var cw = 0.0
        for (i in 0 until s.n) {
            if (hypot(s.x[i] - best.x, s.y[i] - best.y) > 25) continue
            cx += s.w[i] * s.x[i]; cy += s.w[i] * s.y[i]; cw += s.w[i]
        }
        val center = if (cw > 0) MovementModel.Point(cx / cw, cy / cw) else best
        val dist = DoubleArray(s.n) { hypot(s.x[it] - center.x, s.y[it] - center.y) }
        val order2 = (0 until s.n).sortedWith(compareBy<Int> { dist[it] }.thenBy { it })
        var acc = 0.0
        var r95 = order2.lastOrNull()?.let { dist[it] } ?: 0.0
        for (i in order2) {
            acc += s.w[i]
            if (acc >= 0.95) {
                r95 = dist[i]; break
            }
        }
        val cloud = ArrayList<MovementModel.Point>(cloudSize)
        for (k in 0 until cloudSize) {
            var u = (k + 0.5) / cloudSize.toDouble()
            var i = 0
            while (i < s.n - 1 && u > s.w[i]) {
                u -= s.w[i]; i += 1
            }
            cloud.add(MovementModel.Point(s.x[i], s.y[i]))
        }
        return Estimate(center, r95, cw, cloud)
    }
}
