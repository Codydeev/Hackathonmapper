package com.hackathonmapper.meshcore

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

// Signal map: lays phones out on the floor plane so that their distances match the Bluetooth
// ranges measured between them (RSSI turned into meters with the shared radio model). Phones that
// report a position (GPS, UWB, manual, fused) pull the layout towards it with their own accuracy,
// so one solver serves both views:
//   - relative: no placed phone in the group; distances are right, orientation is arbitrary.
//   - pinned: the placed phones don't fix the group's rotation; distances are right, directions not.
//   - world: the placed phones fix the rotation; the layout is in the shared frame.
// Distances read off any view therefore agree with the radio, instead of being the difference of
// two absolute positions that each carry GPS error.
//
// Line-by-line port of ios/MeshCore/Sources/MeshCore/SignalMap.swift (itself a port of
// website/shared/signalmap.ts), so a phone and the dashboard draw the same map; SignalMapTests
// replays the golden cases (signalmap-golden.json).

/**
 * Log-distance radio model: RSSI = p0 - 10 n log10(d). The single model for every RSSI distance,
 * mirrored by `RADIO_MODEL` in website/shared/contract.ts. Keep the two identical.
 * Immutable (Swift value type): change a field with `copy(...)`.
 */
@Serializable
data class RadioModel(
    /** dBm received at 1 m. */
    val p0: Double,
    /** Path-loss exponent. */
    val n: Double,
    /** dB spread of a smoothed RSSI reading, including phone-model differences. */
    val sigma: Double,
    /** m at which half of the one-second windows still hear the phone. */
    val range: Double,
    /** m over which reception fades out. */
    val soft: Double,
) {
    fun expectedRSSI(d: Double): Double = p0 - 10 * n * log10(max(0.5, d))
    fun distance(rssi: Double): Double = 10.0.pow((p0 - rssi) / (10 * n))

    companion object {
        /** Real phones. Short-range distances from it were checked to about a meter on the Track tab. */
        val standard = RadioModel(p0 = -59.0, n = 2.5, sigma = 5.0, range = 60.0, soft = 8.0)
    }
}

/** A point on the floor plane of the shared frame, meters. */
@Serializable
data class FloorPoint(val x: Double, val z: Double)

@Serializable
data class SignalLink(
    val a: String,
    val b: String,
    /** Mean RSSI of the link in dBm (both directions averaged by the caller). */
    val rssi: Double,
)

@Serializable
data class SignalPrior(
    val id: String,
    val x: Double,
    val z: Double,
    /** Reported 95 % radius in meters; null when unknown. */
    val r95: Double?,
)

@Serializable
enum class SignalFrame(val rawValue: String) {
    @SerialName("world") world("world"),
    @SerialName("pinned") pinned("pinned"),
    @SerialName("relative") relative("relative"),
}

@Serializable
data class SignalNode(
    val id: String,
    var x: Double,
    var z: Double,
    /** False for a phone with neither a link nor a position of its own: it has no place yet. */
    var placed: Boolean,
    /** 95 % radius around (x, z); for a ring, around `ringCenter`. */
    var r95: Double,
    var hasPrior: Boolean,
    /** Index of the connected group, in order of each group's smallest id. */
    var component: Int,
    var frame: SignalFrame,
    var degree: Int,
    /** Direction unknown: the phone is somewhere on a circle of `ringRadius` around `ringCenter`. */
    var ringCenter: String?,
    var ringRadius: Double?,
    /** Links to the nearest phone with a position; null when the group has none. */
    var hops: Int?,
)

@Serializable
data class SignalEdge(
    val a: String,
    val b: String,
    val rssi: Double,
    /** Distance from RSSI, m. */
    val measured: Double,
    /** One-sigma error of `measured`, m. */
    val sigma: Double,
    /** Distance in the solved layout, m. */
    val layout: Double,
)

@Serializable
data class SignalMapResult(
    val nodes: List<SignalNode>,
    val links: List<SignalEdge>,
    /** The radio model after calibration from links between precisely placed phones. */
    val radio: RadioModel,
)

/** Where a real-world map may draw a phone, consistent with the signal map. */
data class WorldPlacement(
    /** Best guess; its distance to the ring centre (and to linked phones) is the measured one. */
    val x: Double,
    val z: Double,
    /** 95 % radius around (x, z), meters; for a ring it covers the whole ring. */
    val r95: Double,
    /** Direction unknown: the phone is somewhere on a ring of `ringRadius` around (ringX, ringZ). */
    val ambiguous: Boolean,
    val ringX: Double?,
    val ringZ: Double?,
    val ringRadius: Double?,
)

object SignalMap {
    const val sweeps = 300
    const val tolerance = 1e-6
    const val minDistance = 0.3
    const val maxDistance = 500.0
    const val minPriorSigma = 0.3
    /** Assumed 95 % radius of a position reported without accuracy. */
    const val defaultPriorR95 = 5.0
    const val calibrationMaxR95 = 3.0
    const val maxR95 = 1000.0
    /** A group counts as anchored in the world when its rotation is known to about 20 degrees. */
    const val maxWorldRotationSigma = 0.35
    /**
     * Bluetooth links older than this (report age plus `ageMs`) are not used; mirrors
     * `ESTIMATE_LINK_MAX_AGE_MS`. Reports can spend a few seconds relaying through the mesh.
     */
    const val linkMaxAge: TimeInterval = 6.0
    /** 95 % radius of a 2-D Gaussian per unit of its per-axis sigma: sqrt(-2 ln 0.05). */
    const val r95PerSigma = 2.4477468306808166

    private const val sqrtHalf = 0.7071067811865476
    /** Deterministic directions for first placement; no trigonometry, so both ports agree exactly. */
    private val directions: List<Pair<Double, Double>> = listOf(
        Pair(0.0, 1.0), Pair(sqrtHalf, sqrtHalf), Pair(1.0, 0.0), Pair(sqrtHalf, -sqrtHalf),
        Pair(0.0, -1.0), Pair(-sqrtHalf, -sqrtHalf), Pair(-1.0, 0.0), Pair(-sqrtHalf, sqrtHalf),
    )

    /** Median distance for an RSSI, clamped to the range the model can mean anything over. */
    fun range(rssi: Double, radio: RadioModel): Double {
        val d = 10.0.pow((radio.p0 - rssi) / (10 * radio.n))
        return min(maxDistance, max(minDistance, d))
    }

    /** One-sigma error of a range: RSSI spread is log-normal, so it grows in proportion to distance. */
    fun rangeSigma(distance: Double, radio: RadioModel): Double =
        distance * ln(10.0) * radio.sigma / (10 * radio.n)

    fun priorSigma(r95: Double?): Double = max(minPriorSigma, (r95 ?: defaultPriorR95) / r95PerSigma)

    /**
     * Fits p0 and n from links whose two ends both report a precise position (known distance),
     * with priors that keep a fit from few links close to `radio`.
     */
    fun calibrate(radio: RadioModel, links: List<SignalLink>, priors: Map<String, SignalPrior>): RadioModel {
        val p0Weight = 1.0 / 36 // prior sigma 6 dB
        val nWeight = 1.0 / 2.25 // prior sigma 1.5
        val w = 1 / (radio.sigma * radio.sigma)
        var s1 = 0.0
        var sx = 0.0
        var sxx = 0.0
        var sy = 0.0
        var sxy = 0.0
        var count = 0
        for (link in links) {
            val a = priors[link.a] ?: continue
            val b = priors[link.b] ?: continue
            val ar = a.r95 ?: continue
            val br = b.r95 ?: continue
            if (!(ar <= calibrationMaxR95 && br <= calibrationMaxR95)) continue
            val dx = a.x - b.x
            val dz = a.z - b.z
            val distance = sqrt(dx * dx + dz * dz)
            if (distance < 0.5) continue
            val x = -10 * log10(distance)
            s1 += w
            sx += w * x
            sxx += w * x * x
            sy += w * link.rssi
            sxy += w * x * link.rssi
            count += 1
        }
        if (count <= 0) return radio
        val a11 = s1 + p0Weight
        val a12 = sx
        val a22 = sxx + nWeight
        val b1 = sy + p0Weight * radio.p0
        val b2 = sxy + nWeight * radio.n
        val det = a11 * a22 - a12 * a12
        if (!(det > 0)) return radio
        val p0 = (b1 * a22 - a12 * b2) / det
        val n = (a11 * b2 - a12 * b1) / det
        return radio.copy(p0 = min(-20.0, max(-100.0, p0)), n = min(5.0, max(1.5, n)))
    }

    private class Adjacent(val other: String, val distance: Double, val weight: Double)

    private class Pair2(val a: String, val b: String, var sum: Double, var count: Int)

    /** A layout position; replaced, never mutated (Swift tuple). */
    private class Point(val x: Double, val z: Double)

    fun solve(
        ids: List<String>,
        links: List<SignalLink>,
        priors: List<SignalPrior>,
        radio: RadioModel,
        previous: Map<String, FloorPoint>? = null,
        calibrate: Boolean = false,
    ): SignalMapResult {
        val rawLinks = links
        val rawPriors = priors
        val inputRadio = radio
        val shouldCalibrate = calibrate

        val sortedIds = ids.toSet().sorted()
        val index = HashMap<String, Int>()
        for ((i, id) in sortedIds.withIndex()) index[id] = i
        val priorById = HashMap<String, SignalPrior>()
        for (prior in rawPriors) if (index[prior.id] != null) priorById[prior.id] = prior

        // One link per pair; duplicates are averaged.
        val pairs = HashMap<String, Pair2>()
        for (link in rawLinks) {
            if (!(link.a != link.b && index[link.a] != null && index[link.b] != null && link.rssi.isFinite())) continue
            val a: String
            val b: String
            if (link.a < link.b) { a = link.a; b = link.b } else { a = link.b; b = link.a }
            val key = a + "\n" + b
            val pair = pairs.getOrPut(key) { Pair2(a, b, 0.0, 0) }
            pair.sum += link.rssi
            pair.count += 1
        }
        val mergedLinks = pairs.keys.sorted().map { key ->
            val pair = pairs[key]!!
            SignalLink(a = pair.a, b = pair.b, rssi = pair.sum / pair.count.toDouble())
        }

        val solvedRadio = if (shouldCalibrate) SignalMap.calibrate(inputRadio, mergedLinks, priorById) else inputRadio

        val adjacency = HashMap<String, MutableList<Adjacent>>()
        for (id in sortedIds) adjacency[id] = mutableListOf()
        for (link in mergedLinks) {
            val distance = range(link.rssi, solvedRadio)
            val sigma = rangeSigma(distance, solvedRadio)
            val weight = 1 / (sigma * sigma)
            adjacency[link.a]!!.add(Adjacent(link.b, distance, weight))
            adjacency[link.b]!!.add(Adjacent(link.a, distance, weight))
        }
        for (id in sortedIds) adjacency[id]!!.sortWith { l, r -> l.other.compareTo(r.other) }

        // Connected groups, numbered in order of their smallest id.
        val component = HashMap<String, Int>()
        val groups = mutableListOf<List<String>>()
        for (id in sortedIds) {
            if (component[id] != null) continue
            val group = mutableListOf<String>()
            val queue = ArrayDeque(listOf(id))
            component[id] = groups.size
            while (queue.isNotEmpty()) {
                val u = queue.removeFirst()
                group.add(u)
                for (edge in adjacency[u]!!) {
                    if (component[edge.other] != null) continue
                    component[edge.other] = groups.size
                    queue.addLast(edge.other)
                }
            }
            groups.add(group.sorted())
        }

        // Start from the last layout, then reported positions, then spread out from placed phones.
        val position = HashMap<String, Point>()
        for (id in sortedIds) {
            val last = previous?.get(id)
            val prior = priorById[id]
            if (last != null && last.x.isFinite() && last.z.isFinite()) {
                position[id] = Point(last.x, last.z)
            } else if (prior != null) {
                position[id] = Point(prior.x, prior.z)
            }
        }
        var placements = 0
        for (group in groups) {
            val queue = ArrayDeque(group.filter { position[it] != null })
            if (queue.isEmpty()) {
                position[group[0]] = Point(0.0, 0.0)
                queue.addLast(group[0])
            }
            while (queue.isNotEmpty()) {
                val u = queue.removeFirst()
                val from = position[u]!!
                for (edge in adjacency[u]!!) {
                    if (position[edge.other] != null) continue
                    val (dx, dz) = directions[placements % directions.size]
                    placements += 1
                    position[edge.other] = Point(from.x + edge.distance * dx, from.z + edge.distance * dz)
                    queue.addLast(edge.other)
                }
            }
        }

        // Stress majorization, one phone at a time: move each phone to the weighted mean of where
        // its links and its own reported position say it should be.
        for (sweep in 0 until sweeps) {
            var maxMove = 0.0
            for (id in sortedIds) {
                val p = position[id]!!
                var sumX = 0.0
                var sumZ = 0.0
                var total = 0.0
                val prior = priorById[id]
                if (prior != null) {
                    val sigma = priorSigma(prior.r95)
                    val lambda = 1 / (sigma * sigma)
                    sumX += lambda * prior.x
                    sumZ += lambda * prior.z
                    total += lambda
                }
                for (edge in adjacency[id]!!) {
                    val q = position[edge.other]!!
                    val dx = p.x - q.x
                    val dz = p.z - q.z
                    val dist = sqrt(dx * dx + dz * dz)
                    var ux: Double
                    var uz: Double
                    if (dist < 1e-9) {
                        val direction = directions[(index[id]!! + index[edge.other]!!) % directions.size]
                        ux = direction.first
                        uz = direction.second
                    } else {
                        ux = dx / dist
                        uz = dz / dist
                    }
                    sumX += edge.weight * (q.x + edge.distance * ux)
                    sumZ += edge.weight * (q.z + edge.distance * uz)
                    total += edge.weight
                }
                if (total == 0.0) continue
                val x = sumX / total
                val z = sumZ / total
                maxMove = max(maxMove, max(abs(x - p.x), abs(z - p.z)))
                position[id] = Point(x, z)
            }
            if (maxMove < tolerance) break
        }

        // The most precise placed phone of each group: the point the group turns about.
        val pins: List<String?> = groups.map { group ->
            var best: String? = null
            for (id in group) {
                val prior = priorById[id] ?: continue
                val current = best
                if (current != null && priorSigma(prior.r95) >= priorSigma(priorById[current]!!.r95)) continue
                best = id
            }
            best
        }
        // How well the other placed phones fix the group's rotation about the pin: each pulls with
        // its precision times its squared distance from the pin.
        val rotationSigma: List<Double> = groups.indices.map { c ->
            val pin = pins[c] ?: return@map Double.POSITIVE_INFINITY
            val center = position[pin]!!
            var information = 0.0
            for (id in groups[c]) {
                if (id == pin) continue
                val prior = priorById[id] ?: continue
                val sigma = priorSigma(prior.r95)
                val p = position[id]!!
                val dx = p.x - center.x
                val dz = p.z - center.z
                information += (dx * dx + dz * dz) / (sigma * sigma)
            }
            if (information > 0) 1 / sqrt(information) else Double.POSITIVE_INFINITY
        }
        val frames: List<SignalFrame> = groups.indices.map { c ->
            if (pins[c] == null) SignalFrame.relative
            else if (rotationSigma[c] < maxWorldRotationSigma) SignalFrame.world else SignalFrame.pinned
        }

        // Hops from the nearest placed phone.
        val hops = HashMap<String, Int>()
        val hopQueue = ArrayDeque(sortedIds.filter { priorById[it] != null })
        for (id in hopQueue) hops[id] = 0
        while (hopQueue.isNotEmpty()) {
            val u = hopQueue.removeFirst()
            for (edge in adjacency[u]!!) {
                if (hops[edge.other] != null) continue
                hops[edge.other] = hops[u]!! + 1
                hopQueue.addLast(edge.other)
            }
        }

        val nodes: List<SignalNode> = sortedIds.map { id ->
            val p = position[id]!!
            val c = component[id]!!
            val frame = frames[c]
            val edges = adjacency[id]!!
            val prior = priorById[id]
            val node = SignalNode(
                id = id, x = p.x, z = p.z, placed = true, r95 = 0.0, hasPrior = prior != null, component = c,
                frame = frame, degree = edges.size, ringCenter = null, ringRadius = null, hops = hops[id],
            )
            if (prior == null && edges.isEmpty()) {
                node.placed = false
                node.r95 = maxR95
                return@map node
            }
            if (prior == null && edges.size == 1) {
                // One link gives a distance, not a direction.
                val edge = edges[0]
                node.ringCenter = edge.other
                node.ringRadius = edge.distance
                node.r95 = min(maxR95, edge.distance + 1.96 * rangeSigma(edge.distance, solvedRadio))
                return@map node
            }
            // Local uncertainty from the information each link and the prior give.
            var a = 0.0
            var b = 0.0
            var d = 0.0
            if (prior != null) {
                val sigma = priorSigma(prior.r95)
                a += 1 / (sigma * sigma)
                d += 1 / (sigma * sigma)
            }
            for (edge in edges) {
                val q = position[edge.other]!!
                val dx = p.x - q.x
                val dz = p.z - q.z
                val dist = sqrt(dx * dx + dz * dz)
                if (dist < 1e-9) continue
                val ux = dx / dist
                val uz = dz / dist
                a += edge.weight * ux * ux
                b += edge.weight * ux * uz
                d += edge.weight * uz * uz
            }
            val det = a * d - b * b
            var r95 = if (det > 1e-12 * (a + d) * (a + d)) r95PerSigma * sqrt((a + d) / det / 2) else maxR95
            val pin = pins[c]
            if (pin != null && id != pin) {
                val q = position[pin]!!
                val dx = p.x - q.x
                val dz = p.z - q.z
                val fromPin = sqrt(dx * dx + dz * dz)
                if (frame == SignalFrame.pinned) {
                    // The group can still turn about its pin: the distance is known, the direction is not.
                    node.ringCenter = pin
                    node.ringRadius = fromPin
                    r95 += fromPin
                } else {
                    // Anchored, but the remaining rotation error grows with distance from the pin.
                    val across = r95PerSigma * fromPin * rotationSigma[c]
                    r95 = sqrt(r95 * r95 + across * across)
                }
            }
            node.r95 = min(maxR95, r95)
            node
        }

        val edges: List<SignalEdge> = mergedLinks.map { link ->
            val p = position[link.a]!!
            val q = position[link.b]!!
            val dx = p.x - q.x
            val dz = p.z - q.z
            val measured = range(link.rssi, solvedRadio)
            SignalEdge(
                a = link.a, b = link.b, rssi = link.rssi, measured = measured,
                sigma = rangeSigma(measured, solvedRadio), layout = sqrt(dx * dx + dz * dz),
            )
        }

        return SignalMapResult(nodes = nodes, links = edges, radio = solvedRadio)
    }

    /**
     * A node's spot on a real-world map: its layout position, which keeps every Bluetooth
     * distance, plus the ring around its centre when only the distance is known. A relative
     * group has no place in the world (show it on the signal map instead).
     */
    fun placeInWorld(node: SignalNode, nodes: Map<String, SignalNode>, depth: Int = 0): WorldPlacement? {
        if (!(node.placed && node.frame != SignalFrame.relative && depth <= 4)) return null
        val ringCenter = node.ringCenter
        val ringRadius = node.ringRadius
        if (ringCenter != null && ringRadius != null) {
            val center = nodes[ringCenter] ?: return null
            val placed = placeInWorld(center, nodes, depth + 1) ?: return null
            return WorldPlacement(
                x = node.x, z = node.z,
                r95 = min(maxR95, ringRadius + node.r95 + (if (placed.ambiguous) placed.r95 else 0.0)),
                ambiguous = true, ringX = placed.x, ringZ = placed.z, ringRadius = ringRadius,
            )
        }
        return WorldPlacement(x = node.x, z = node.z, r95 = node.r95, ambiguous = false, ringX = null, ringZ = null, ringRadius = null)
    }

    /** Points on a placement's ring, for maps that draw clouds; empty when the spot is known. */
    fun ringPoints(placement: WorldPlacement, count: Int = 24): List<FloorPoint> {
        val radius = placement.ringRadius
        val cx = placement.ringX
        val cz = placement.ringZ
        if (!placement.ambiguous || radius == null || cx == null || cz == null) return emptyList()
        return (0 until count).map { k ->
            val angle = 2 * Math.PI * k.toDouble() / count.toDouble()
            FloorPoint(x = cx + radius * sin(angle), z = cz + radius * cos(angle))
        }
    }
}
