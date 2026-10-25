package com.hackathonmapper.meshcore

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.sin
import kotlin.math.sqrt

// Places phones that have no position (positionSource "none") from the Bluetooth signal strength
// (RSSI) of the links they and their neighbours report, hop by hop from phones that do have one.
// The particle filter tested in the Luotsi prototype; GhostCore's baseline positioning engine
// (GhostCorePipeline.EstimatorPositioning, the "baseline" scenario run). The dashboard and the
// phone's Track view place phones with SignalMap instead; the TypeScript twin was retired with it.
//
// Each phone's belief is a weighted cloud of particles on the floor plane (x east, z north):
//   - anchor (GPS or manual position): a cloud around that position
//   - lost phone with history: last cloud, spread a little each second, kept from drifting by
//     the RSSI of every heard neighbour (sampled from that neighbour's own cloud, so uncertainty
//     grows with every hop) and by the phones it can NOT hear
//   - lost phone with no history: a ring around the first neighbour it hears. RSSI gives
//     distance, not direction: one neighbour leaves a ring, two leave two spots, three a point.
//
// Port of ios/MeshCore/Sources/MeshCore/BluetoothEstimator.swift.

// RadioModel and FloorPoint live in SignalMap.kt (one radio model for the app and the dashboard).

/** The estimator's name for the standard model: phones outdoors with some foliage. */
val RadioModel.Companion.outdoors: RadioModel get() = RadioModel.standard

/** Chance that one second of listening hears a phone `atDistance` metres away. */
fun RadioModel.hearProbability(atDistance: Double): Double = 1 / (1 + exp((atDistance - range) / soft))

/** One RSSI reading for the link between phones `a` and `b`. */
data class LinkMeasurement(
    val a: String,
    val b: String,
    val rssi: Double,
    /**
     * Mean UWB distance of the ends that measured one (wire v5), m; null for an RSSI-only link.
     * The particle filter ignores it; `SignalMapPositioning` uses it.
     */
    val uwb: Double? = null,
)

/** A phone with a position (GPS or manual). `accuracy` is its reported ~68 % radius. */
data class EstimatorAnchor(
    val id: String,
    val x: Double,
    val z: Double,
    val accuracy: Double?,
)

data class BluetoothEstimate(
    val x: Double,
    val z: Double,
    /** Radius around (x, z) holding 95 % of the belief. */
    val r95: Double,
    /** Ring or two separate spots: the centre is not a good guess. */
    val ambiguous: Boolean,
    /** Hops to the nearest anchor; null when not connected to one. */
    val hops: Int?,
    /** A sample of the particle cloud for drawing. */
    val cloud: List<FloorPoint>,
)

/**
 * Seeded PRNG (mulberry32) with a Gaussian helper, so estimates are repeatable in tests.
 * A Swift struct with mutating methods: copy with `copy()` where Swift copies the value.
 */
internal class SeededRandom(seed: UInt) {
    private var state: UInt = seed

    fun copy(): SeededRandom = SeededRandom(state)

    fun next(): Double {
        state += 0x6d2b79f5u
        var t = state
        t = (t xor (t shr 15)) * (t or 1u)
        t = t xor (t + ((t xor (t shr 7)) * (t or 61u)))
        return (t xor (t shr 14)).toDouble() / 4_294_967_296.0
    }

    fun gauss(): Double {
        val u = max(next(), 1e-12)
        val v = next()
        return sqrt(-2 * ln(u)) * cos(2 * PI * v)
    }
}

class BluetoothEstimator(options: Options = Options()) {
    /** A Swift struct of `var`s: a data class, so `copy()` gives the value copy. */
    data class Options(
        var particles: Int = 600,
        /** Neighbour particles averaged per likelihood. */
        var samples: Int = 6,
        /** Readings of the same link a second apart are strongly correlated. */
        var temper: Double = 0.15,
        /** Max weight of "I can't hear you, so I'm probably not next to you". */
        var silence: Double = 0.85,
        /** Cold-start phones: fraction re-drawn on rings each second... */
        var reset: Double = 0.03,
        /** ...during their first seconds only. */
        var resetFor: Int = 15,
        /** Weight of a neighbour no closer to an anchor and no surer than us. */
        var sideways: Double = 0.3,
        /** m per second a phone may move without us knowing (no step data). */
        var jitter: Double = 0.8,
        var cloudPoints: Int = 150,
        var radio: RadioModel = RadioModel.outdoors,
        var seed: UInt = 5u,
    )

    private class Anchor(val x: Double, val y: Double, val sigma: Double)

    private class Estimate(val x: Double, val y: Double, val r95: Double, val ambiguous: Boolean)

    private class Link(val to: String, val rssi: Double)

    private class Neighbour(val node: Node, val rssi: Double, val weight: Double)

    private class Node(val id: String, particles: Int) {
        var anchor: Anchor? = null
        var px = DoubleArray(particles)
        var py = DoubleArray(particles)
        var w = DoubleArray(particles) { 1 / particles.toDouble() }
        var cdf: DoubleArray? = null
        var ready = false
        var cold = false
        var coldAge = 0
        var est: Estimate? = null
        /** Infinity when not connected to an anchor, as in the TypeScript original. */
        var hops = Double.POSITIVE_INFINITY
        var links: MutableList<Link> = mutableListOf()
    }

    private val o: Options = options.copy()
    private val N: Int = options.particles
    private val rand = SeededRandom(seed = options.seed)
    /** Insertion order is kept, like the JavaScript Map, so a run is repeatable. */
    private var nodes: MutableMap<String, Node> = HashMap()
    private val order: MutableList<String> = mutableListOf()

    private val orderedNodes: List<Node> get() = order.mapNotNull { nodes[it] }

    /**
     * One second of evidence. `anchors` are phones with a position; `lost` are phones without one;
     * every other id is forgotten.
     */
    fun update(anchors: List<EstimatorAnchor>, lost: List<String>, measurements: List<LinkMeasurement>): Map<String, BluetoothEstimate> {
        val keep = (anchors.map { it.id } + lost).toSet()
        order.removeAll { !keep.contains(it) }
        nodes = HashMap(nodes.filterKeys { keep.contains(it) })
        for (id in anchors.map { it.id } + lost) {
            if (nodes[id] != null) continue
            nodes[id] = Node(id, N)
            order.add(id)
        }
        for (id in lost) nodes[id]?.anchor = null
        for (a in anchors) {
            // Accuracy is a ~68 % radius; never trust a fix to better than 2 m here.
            nodes[a.id]?.anchor = Anchor(a.x, a.z, max(2.0, a.accuracy ?: 5.0))
        }
        step(measurements)

        val out = HashMap<String, BluetoothEstimate>()
        for (id in lost) {
            val n = nodes[id] ?: continue
            if (!n.ready) continue
            val est = n.est ?: continue
            out[id] = BluetoothEstimate(
                x = est.x, z = est.y, r95 = est.r95, ambiguous = est.ambiguous,
                hops = if (n.hops.isFinite()) n.hops.toInt() else null, cloud = sampleCloud(n),
            )
        }
        return out
    }

    private fun g(): Double = rand.gauss()

    private fun buildCdf(n: Node) {
        val c = n.cdf ?: DoubleArray(N)
        var s = 0.0
        for (k in 0 until N) {
            s += n.w[k]
            c[k] = s
        }
        n.cdf = c
    }

    private fun pick(n: Node): Int {
        val cdf = n.cdf ?: return (rand.next() * N.toDouble()).toInt()
        val u = rand.next() * cdf[N - 1]
        var lo = 0
        var hi = N - 1
        while (lo < hi) {
            val mid = (lo + hi) shr 1
            if (cdf[mid] < u) lo = mid + 1 else hi = mid
        }
        return lo
    }

    private fun ringSample(n: Node, k: Int, nb: Node, rssi: Double) {
        val q = pick(nb)
        val d = o.radio.distance(rssi + o.radio.sigma * g())
        val th = rand.next() * 2 * PI
        n.px[k] = nb.px[q] + d * sin(th)
        n.py[k] = nb.py[q] + d * cos(th)
    }

    private fun summarize(n: Node) {
        var mx = 0.0
        var my = 0.0
        var sw = 0.0
        for (k in 0 until N) {
            mx += n.w[k] * n.px[k]
            my += n.w[k] * n.py[k]
            sw += n.w[k]
        }
        mx /= sw
        my /= sw
        val dist = DoubleArray(N)
        for (k in 0 until N) dist[k] = hypot(n.px[k] - mx, n.py[k] - my)
        val idx = (0 until N).sortedWith { l, r -> dist[l].compareTo(dist[r]) }
        var r95 = dist[idx[N - 1]]
        var acc = 0.0
        for (k in idx) {
            acc += n.w[k] / sw
            if (acc >= 0.95) {
                r95 = dist[k]
                break
            }
        }
        // A ring or two separate blobs has almost no weight near its centre.
        var core = 0.0
        for (k in 0 until N) if (dist[k] < 0.25 * r95) core += n.w[k] / sw
        n.est = Estimate(mx, my, r95, r95 > 15 && core < 0.05)
    }

    private fun resample(n: Node) {
        val nx = DoubleArray(N)
        val ny = DoubleArray(N)
        val sum = n.w.fold(0.0) { s, v -> s + v }
        val stepSize = sum / N.toDouble()
        var u = rand.next() * stepSize
        var c = n.w[0]
        var i = 0
        for (k in 0 until N) {
            while (u > c && i < N - 1) {
                i += 1
                c += n.w[i]
            }
            nx[k] = n.px[i] + 0.5 * g()
            ny[k] = n.py[i] + 0.5 * g()
            u += stepSize
        }
        n.px = nx
        n.py = ny
        n.w = DoubleArray(N) { 1 / N.toDouble() }
    }

    private fun sampleCloud(n: Node): List<FloorPoint> =
        (0 until o.cloudPoints).map {
            val k = pick(n)
            FloorPoint(x = n.px[k], z = n.py[k])
        }

    private fun step(measurements: List<LinkMeasurement>) {
        val radio = o.radio
        val all = orderedNodes
        for (n in all) n.links = mutableListOf()
        for (m in measurements) {
            val a = nodes[m.a] ?: continue
            val b = nodes[m.b] ?: continue
            if (a === b) continue
            a.links.add(Link(b.id, m.rssi))
            b.links.add(Link(a.id, m.rssi))
        }

        // Anchors: a cloud around their position.
        for (n in all) {
            val anchor = n.anchor ?: continue
            for (k in 0 until N) {
                n.px[k] = anchor.x + anchor.sigma * g()
                n.py[k] = anchor.y + anchor.sigma * g()
            }
            n.w = DoubleArray(N) { 1 / N.toDouble() }
            n.cdf = null
            n.ready = true
            n.cold = false
        }

        // Hop count from the nearest anchor.
        for (n in all) n.hops = if (n.anchor == null) Double.POSITIVE_INFINITY else 0.0
        val queue = ArrayDeque(all.filter { it.anchor != null })
        while (queue.isNotEmpty()) {
            val n = queue.removeFirst()
            for (l in n.links) {
                val m = nodes[l.to] ?: continue
                if (m.hops > n.hops + 1) {
                    m.hops = n.hops + 1
                    queue.addLast(m)
                }
            }
        }

        // Lost phones, closest to an anchor first so information flows outward (stable order).
        val lost = all.withIndex()
            .filter { it.value.anchor == null }
            .sortedWith { l, r ->
                if (l.value.hops != r.value.hops) l.value.hops.compareTo(r.value.hops) else l.index.compareTo(r.index)
            }
            .map { it.value }
        val logw = DoubleArray(N)
        for (n in lost) {
            if (n.ready) {
                for (k in 0 until N) {
                    n.px[k] += o.jitter * g()
                    n.py[k] += o.jitter * g()
                }
            }

            val known = n.links.filter { nodes[it.to]?.ready == true }
            if (!n.ready) {
                if (known.isEmpty()) continue
                val first = known.drop(1).fold(known[0]) { a, b ->
                    if (nodes[a.to]!!.hops <= nodes[b.to]!!.hops) a else b
                }
                val source = nodes[first.to]!!
                for (k in 0 until N) ringSample(n, k, source, first.rssi)
                n.w = DoubleArray(N) { 1 / N.toDouble() }
                n.ready = true
                n.cold = true
                n.coldAge = 0
            } else if (n.cold && known.isNotEmpty()) {
                n.coldAge += 1
                if (n.coldAge < o.resetFor) {
                    val resets = swiftRounded(o.reset * N.toDouble()).toInt()
                    for (r in 0 until resets) {
                        val l = known[(rand.next() * known.size.toDouble()).toInt()]
                        val k = (rand.next() * N.toDouble()).toInt()
                        ringSample(n, k, nodes[l.to]!!, l.rssi)
                        n.w[k] = 1 / N.toDouble()
                    }
                }
            }

            // Weigh: every heard neighbour, and every settled phone we cannot hear.
            val heard = n.links.map { it.to }.toSet()
            val silent = all.filter { m ->
                m !== n && m.ready && !heard.contains(m.id) && (m.est?.let { it.r95 < 2 * radio.range } ?: false)
            }
            if (known.isNotEmpty() || silent.isNotEmpty()) {
                val neighbours = known.map { l ->
                    val nb = nodes[l.to]!!
                    var upstream = nb.hops < n.hops
                    val nbEst = nb.est
                    val nEst = n.est
                    if (!upstream && nbEst != null && nEst != null) upstream = nbEst.r95 < 0.7 * nEst.r95
                    Neighbour(nb, l.rssi, if (upstream) 1.0 else o.sideways)
                }
                for (k in 0 until N) {
                    var lw = 0.0
                    for (neighbour in neighbours) {
                        val nb = neighbour.node
                        var p = 0.0
                        for (s in 0 until o.samples) {
                            val q = pick(nb)
                            val d = hypot(n.px[k] - nb.px[q], n.py[k] - nb.py[q])
                            val z = (neighbour.rssi - radio.expectedRSSI(d)) / radio.sigma
                            p += exp(-0.5 * z * z)
                        }
                        lw += neighbour.weight * ln(p / o.samples.toDouble() + 1e-12)
                    }
                    for (m in silent) {
                        var p = 0.0
                        for (s in 0 until o.samples) {
                            val q = pick(m)
                            p += 1 - o.silence * radio.hearProbability(hypot(n.px[k] - m.px[q], n.py[k] - m.py[q]))
                        }
                        lw += ln(p / o.samples.toDouble())
                    }
                    logw[k] = ln(n.w[k] + 1e-300) + o.temper * lw
                }
                val maxLog = logw.maxOrNull() ?: 0.0
                var sum = 0.0
                for (k in 0 until N) {
                    n.w[k] = exp(logw[k] - maxLog)
                    sum += n.w[k]
                }
                var ess = 0.0
                for (k in 0 until N) {
                    n.w[k] /= sum
                    ess += n.w[k] * n.w[k]
                }
                if (1 / ess < N.toDouble() / 2) resample(n)
            }
            buildCdf(n)
            summarize(n)
            val est = n.est
            if (n.cold && est != null && est.r95 < 20) n.cold = false // ring resolved: stop re-seeding
        }
        for (n in all) if (n.anchor != null) summarize(n)
    }

    data class Input(
        val anchors: List<EstimatorAnchor>,
        val lost: List<String>,
        val measurements: List<LinkMeasurement>,
    )

    companion object {
        private class PairSum(
            val a: String,
            val b: String,
            var sum: Double,
            var count: Int,
            var uwbSum: Double,
            var uwbCount: Int,
        )

        /**
         * Estimator input from the latest mesh reports, built as the dashboard builds it: fresh
         * reports with a GPS or manual position are anchors, fresh `none` reports are lost phones,
         * and each pair of phones gets one RSSI, the mean of what either end reported recently.
         * Times are seconds since the Unix epoch (Swift `Date`).
         */
        fun input(
            reports: List<DeviceUpdate>,
            receivedAt: Map<String, Double>,
            now: Double,
            reportMaxAge: TimeInterval,
            linkMaxAge: TimeInterval,
        ): Input {
            val fresh = reports
                .filter { update -> receivedAt[update.id]?.let { now - it <= reportMaxAge } ?: false }
                .sortedWith { l, r -> l.id.compareTo(r.id) }
            val anchors = mutableListOf<EstimatorAnchor>()
            val lost = mutableListOf<String>()
            for (update in fresh) {
                if (update.positionSource == PositionSource.none) {
                    lost.add(update.id)
                } else {
                    // A missing source comes from an older build and means manual.
                    anchors.add(
                        EstimatorAnchor(
                            id = update.id, x = update.position.x, z = update.position.z,
                            accuracy = update.accuracyMeters,
                        ),
                    )
                }
            }

            val pairs = HashMap<String, PairSum>()
            for (update in fresh) {
                val reportAge = now - (receivedAt[update.id] ?: now)
                for (neighbor in update.neighbors ?: emptyList()) {
                    val rssi = neighbor.rssi ?: continue
                    if (!(reportAge + (neighbor.ageMs ?: 0).toDouble() / 1000 <= linkMaxAge)) continue
                    val a: String
                    val b: String
                    if (update.id < neighbor.id) { a = update.id; b = neighbor.id } else { a = neighbor.id; b = update.id }
                    val key = a + "\n" + b
                    val pair = pairs.getOrPut(key) { PairSum(a, b, 0.0, 0, 0.0, 0) }
                    pair.sum += rssi.toDouble()
                    pair.count += 1
                    val uwb = neighbor.uwbDistanceM
                    if (uwb != null && uwb.isFinite() && uwb >= 0) {
                        pair.uwbSum += uwb
                        pair.uwbCount += 1
                    }
                }
            }
            val measurements = pairs.keys.sorted().mapNotNull { key ->
                pairs[key]?.let {
                    LinkMeasurement(
                        a = it.a, b = it.b, rssi = it.sum / it.count.toDouble(),
                        uwb = if (it.uwbCount > 0) it.uwbSum / it.uwbCount.toDouble() else null,
                    )
                }
            }
            return Input(anchors = anchors, lost = lost, measurements = measurements)
        }
    }
}
