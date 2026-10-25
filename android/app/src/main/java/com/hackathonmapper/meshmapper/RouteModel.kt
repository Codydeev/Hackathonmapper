// Route model runtime for Android (port of RouteModel.swift): when a phone drops out of Bluetooth
// range, predicts which way the person went along the path network, as 2-4 routes with
// probabilities ("65% Straight on at the fork in 240 m"), where along each route they probably are
// after t seconds, and the chance they left the paths. A line-for-line port of route-model.js
// (checked against its golden cases). Needs MovementModel.kt for Point/TrackPoint. Plain Kotlin
// and kotlinx.serialization, no Android APIs.
//
//   val routes = RouteModel(model = routeModelBytes,       // route-model.json
//                           graph = graphBytes)             // graphs/hervanta.json
//   val pred = routes.predict(track = reports, now = lastHeard, accuracy = 12.0)   // once, when the link drops
//   val markers = routes.whereAlong(pred, seconds = now - lastHeard)               // any time after
//   // pred.routes[i].p, .text, .line; markers[i].point, .band; routes.toLatLon(p) for the map
//
// Positions are metres in the graph's frame, the same frame as the v2 map
// (MapLayer.toXY / RouteModel.toXY convert GPS coordinates).

package com.hackathonmapper.meshmapper

import com.hackathonmapper.meshcore.swiftRounded
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

class RouteModel(model: ByteArray, graph: ByteArray) {
    // Swift: `typealias Point = MovementModel.Point`; Kotlin has no nested type aliases, so the
    // code uses MovementModel.Point directly.

    data class Route(
        var p: Double,
        val text: String,
        val turn: String,
        val line: List<MovementModel.Point>,
        val cum: List<Double>,
    )

    data class Prediction(
        val routes: List<Route>,
        val offPath: Double,
        val offNow: Boolean,
        val bin: Int,
        val speed: Double,
    )

    data class Marker(
        val point: MovementModel.Point,
        val band: List<MovementModel.Point>,
        val atEnd: Boolean,
        val q10: Double,
        val q50: Double,
        val q90: Double,
    )

    /** Swift's `(lat: Double, lon: Double)` tuple. */
    data class LatLon(val lat: Double, val lon: Double)

    // Model tables (route-model.json).
    internal val vEdges: List<Double>
    internal val tGrid: List<Double>
    internal val q: Map<String, List<List<Double>>>
    internal val backMoving: Double
    internal val backStopped: Double
    internal val offT: List<Double>
    internal val offOn: List<Double>
    internal val offOff: List<Double>
    internal val minR: Double
    internal val accMul: Double
    internal val sigma0: Double
    internal val maxStarts: Int
    internal val minShare: Double
    internal val offPathM: Double
    internal val movedM: Double
    internal val prune: Double
    internal val maxLeaves: Int
    internal val horizon: Double
    internal val mergeMinShare: Double
    internal val maxRoutes: Int
    internal val parallelM: Double
    internal val probeM: Double

    // Graph (graphs/<area>.json).
    val lat0: Double
    val lon0: Double
    internal val names: List<String>
    internal val len: DoubleArray
    internal val nameIdx: IntArray
    internal val pts: List<List<MovementModel.Point>>
    internal val cum: List<DoubleArray>
    internal val turnOff: IntArray
    internal val turnTo: IntArray
    internal val turnP: DoubleArray

    internal data class Sample(val e: Int, val s: Double, val x: Double, val y: Double)

    /** Cell (i, j) packed into one key; samples kept in insertion order, like the Swift dictionary values. */
    private val grid = HashMap<Long, MutableList<Sample>>()

    internal class Node(
        val d: Int,
        val p: Double,
        val start: Double,
        val end: Double,
        val parent: Node?,
        val back: Boolean = false,
    ) {
        val children = mutableListOf<Node>()
    }

    init {
        fun obj(a: JsonElement?): JsonObject = a as? JsonObject ?: JsonObject(emptyMap())
        fun num(a: JsonElement?): Double = (a as? JsonPrimitive)?.doubleOrNull ?: 0.0
        fun nums(a: JsonElement?): List<Double> = (a as? JsonArray)?.map { num(it) } ?: emptyList()
        val m = obj(Json.parseToJsonElement(model.decodeToString()))
        val speed = obj(m["speed"])
        vEdges = nums(speed["vEdges"]); tGrid = nums(speed["t"])
        val qq = mutableMapOf<String, List<List<Double>>>()
        for ((k, v) in obj(speed["q"])) qq[k] = ((v as? JsonArray) ?: JsonArray(emptyList())).map { nums(it) }
        q = qq
        val back = obj(m["back"]); backMoving = num(back["moving"]); backStopped = num(back["stopped"])
        val off = obj(m["offPath"]); offT = nums(off["t"]); offOn = nums(off["on"]); offOff = nums(off["off"])
        val loc = obj(m["locate"])
        minR = num(loc["minR"]); accMul = num(loc["accMul"]); sigma0 = num(loc["sigma0"]); maxStarts = num(loc["maxStarts"]).toInt()
        minShare = num(loc["minShare"]); offPathM = num(loc["offPathM"]); movedM = num(loc["movedM"])
        val ro = obj(m["rollout"]); prune = num(ro["prune"]); maxLeaves = num(ro["maxLeaves"]).toInt(); horizon = num(ro["horizon"])
        val me = obj(m["merge"])
        mergeMinShare = num(me["minShare"]); maxRoutes = num(me["maxRoutes"]).toInt(); parallelM = num(me["parallelM"]); probeM = num(me["probeM"])

        val g = obj(Json.parseToJsonElement(graph.decodeToString()))
        lat0 = num(g["lat0"]); lon0 = num(g["lon0"])
        names = (g["names"] as? JsonArray)?.map { (it as? JsonPrimitive)?.content ?: "" } ?: emptyList()
        turnOff = nums(g["turnOff"]).map { it.toInt() }.toIntArray()
        turnTo = nums(g["turnTo"]).map { it.toInt() }.toIntArray()
        turnP = nums(g["turnP"]).toDoubleArray()
        val lenList = ArrayList<Double>()
        val nameList = ArrayList<Int>()
        val ptsList = ArrayList<List<MovementModel.Point>>()
        val cumList = ArrayList<DoubleArray>()
        for (element in (g["edges"] as? JsonArray) ?: JsonArray(emptyList())) {
            val ed = element as? JsonArray ?: continue
            val l = num(ed[2])
            lenList.add(l); nameList.add(num(ed[4]).toInt())
            val f = nums(ed[6])
            val p = ArrayList<MovementModel.Point>(f.size / 2)
            var i = 0
            while (i + 1 < f.size) {
                p.add(MovementModel.Point(f[i], f[i + 1])); i += 2
            }
            val c = ArrayList<Double>(p.size)
            c.add(0.0)
            for (k in 1 until max(1, p.size)) c.add(c[k - 1] + hypot(p[k].x - p[k - 1].x, p[k].y - p[k - 1].y))
            val scale = if (c[c.size - 1] > 0) l / c[c.size - 1] else 1.0
            val scaled = DoubleArray(c.size) { c[it] * scale }
            scaled[scaled.size - 1] = l // exact, so every runtime agrees on the end
            ptsList.add(p); cumList.add(scaled)
        }
        len = lenList.toDoubleArray(); nameIdx = nameList.toIntArray(); pts = ptsList; cum = cumList
        for (e in len.indices) {
            val l = len[e]
            val n = max(2, ceil(l / 5).toInt() + 1)
            for (k in 0 until n) {
                val s = l * k.toDouble() / (n - 1).toDouble()
                val p = at(2 * e, s)
                grid.getOrPut(cellKey(floor(p.x / cell).toInt(), floor(p.y / cell).toInt())) { mutableListOf() }
                    .add(Sample(e, s, p.x, p.y))
            }
        }
    }

    // MARK: Frame

    fun toXY(lat: Double, lon: Double): MovementModel.Point {
        val r = 6371000.0
        val rad = Math.PI / 180
        return MovementModel.Point(r * cos(lat0 * rad) * (lon - lon0) * rad, r * (lat - lat0) * rad)
    }

    fun toLatLon(p: MovementModel.Point): LatLon {
        val r = 6371000.0
        val deg = 180 / Math.PI
        return LatLon(lat0 + p.y / r * deg, lon0 + p.x / (r * cos(lat0 / deg)) * deg)
    }

    /** The same 31 positions, 2 s apart, that MovementModel.history makes. */
    fun history(track: List<MovementModel.TrackPoint>, now: Double): List<MovementModel.Point> {
        require(track.isNotEmpty())
        val out = ArrayList<MovementModel.Point>(31)
        var j = 0
        for (i in 30 downTo 0) {
            val t = now - i.toDouble() * 2
            while (j < track.size - 1 && track[j + 1].t <= t) j += 1
            val a = track[j]
            val b = track[min(j + 1, track.size - 1)]
            if (t <= a.t || j == track.size - 1) {
                out.add(MovementModel.Point(a.x, a.y))
            } else if (t >= b.t) {
                out.add(MovementModel.Point(b.x, b.y))
            } else {
                val f = (t - a.t) / (b.t - a.t)
                out.add(MovementModel.Point(a.x + f * (b.x - a.x), a.y + f * (b.y - a.y)))
            }
        }
        return out
    }

    // MARK: Geometry

    internal fun at(d: Int, s: Double): MovementModel.Point {
        val e = d shr 1
        val c = cum[e]
        val p = pts[e]
        val l = len[e]
        val u = if (d and 1 == 1) l - s else s
        if (u <= 0) return p[0]
        if (u >= c[c.size - 1]) return p[p.size - 1]
        var i = 1
        while (c[i] < u) i += 1
        val f = (u - c[i - 1]) / max(1e-9, c[i] - c[i - 1])
        return MovementModel.Point(p[i - 1].x + f * (p[i].x - p[i - 1].x), p[i - 1].y + f * (p[i].y - p[i - 1].y))
    }

    internal fun piece(d: Int, s0: Double, s1: Double): List<MovementModel.Point> {
        val e = d shr 1
        val l = len[e]
        val out = mutableListOf(at(d, s0))
        var inner = cum[e].mapIndexed { offset, element -> Pair(if (d and 1 == 1) l - element else element, offset) }
            .filter { it.first > s0 + 1e-6 && it.first < s1 - 1e-6 }
        if (d and 1 == 1) inner = inner.reversed()
        for ((_, i) in inner) out.add(pts[e][i])
        out.add(at(d, s1))
        return out
    }

    internal fun headingOut(d: Int): Double {
        val a = at(d, 0.0)
        val b = at(d, min(25.0, len[d shr 1]))
        return atan2(b.y - a.y, b.x - a.x)
    }

    internal fun headingIn(d: Int): Double {
        val l = len[d shr 1]
        val a = at(d, max(0.0, l - 25))
        val b = at(d, l)
        return atan2(b.y - a.y, b.x - a.x)
    }

    internal data class Near(val e: Int, val dist: Double, val s: Double)

    /** Edges with a sample point within r, nearest distance and offset, in first-found order. */
    internal fun near(p: MovementModel.Point, r: Double): List<Near> {
        val order = mutableListOf<Int>()
        val best = HashMap<Int, DoubleArray>()
        val c0 = floor((p.x - r) / cell).toInt()
        val c1 = floor((p.x + r) / cell).toInt()
        val r0 = floor((p.y - r) / cell).toInt()
        val r1 = floor((p.y + r) / cell).toInt()
        for (i in c0..c1) {
            for (j in r0..r1) {
                for (smp in grid[cellKey(i, j)] ?: continue) {
                    val dist = hypot(smp.x - p.x, smp.y - p.y)
                    if (dist > r) continue
                    val old = best[smp.e]
                    if (old != null) {
                        if (dist < old[0]) best[smp.e] = doubleArrayOf(dist, smp.s)
                    } else {
                        order.add(smp.e)
                        best[smp.e] = doubleArrayOf(dist, smp.s)
                    }
                }
            }
        }
        return order.map { Near(it, best[it]!![0], best[it]!![1]) }
    }

    internal fun nearestDist(p: MovementModel.Point, r: Double): Double =
        near(p, r).minOfOrNull { it.dist } ?: Double.POSITIVE_INFINITY

    // MARK: Tables

    internal fun speedBin(v: Double): Int {
        var b = 0
        while (b < vEdges.size && v >= vEdges[b]) b += 1
        return b
    }

    internal fun distAt(which: String, bin: Int, t: Double): Double = interp(tGrid, q[which]!![bin], t)

    // MARK: Prediction

    internal data class Start(val d: Int, val s: Double, val p: Double, val back: Boolean)

    internal data class Located(val starts: List<Start>, val offNow: Boolean, val moved: Boolean, val th: Double)

    private data class Candidate(val e: Int, val s: Double, val w: Double)

    internal fun locate(hist: List<MovementModel.Point>, acc: Double): Located {
        val n = hist.size
        val last = hist[n - 1]
        val recent = hist.takeLast(10).map { nearestDist(it, 3 * offPathM) }.sorted()
        val offNow = recent[recent.size shr 1] > offPathM
        val bigR = max(minR, accMul * acc)
        val sig2 = acc * acc + sigma0 * sigma0
        var cands = near(last, bigR).map { Candidate(it.e, it.s, exp(-it.dist * it.dist / (2 * sig2))) }
        if (cands.isEmpty()) {
            cands = near(last, 4 * bigR).map { Candidate(it.e, it.s, exp(-it.dist * it.dist / (2 * sig2 * 16))) }
        }
        // Stable: ties keep their first-found order, like the Swift offset tie-break.
        cands = cands.sortedByDescending { it.w }
        val tot = cands.fold(0.0) { a, c -> a + c.w }
        cands = cands.filterIndexed { offset, c -> offset < maxStarts && c.w / tot >= minShare }
        val t2 = cands.fold(0.0) { a, c -> a + c.w }
        val backPt = hist[n - 1]
        val from = hist[max(0, n - 11)]
        val moved = hypot(backPt.x - from.x, backPt.y - from.y) >= movedM
        val th = atan2(backPt.y - from.y, backPt.x - from.x)
        val pBack = if (moved) backMoving else backStopped
        val starts = mutableListOf<Start>()
        for (c in cands) {
            val share = c.w / t2
            val le = len[c.e]
            val a = at(2 * c.e, max(0.0, c.s - 5))
            val b = at(2 * c.e, min(le, c.s + 5))
            val tangent = atan2(b.y - a.y, b.x - a.x)
            val fwdAligned = !moved || cos(th - tangent) >= 0
            val pFwd = if (moved) (if (fwdAligned) 1 - pBack else pBack) else 0.5
            starts.add(Start(2 * c.e, c.s, share * pFwd, moved && !fwdAligned))
            starts.add(Start(2 * c.e + 1, le - c.s, share * (1 - pFwd), moved && fwdAligned))
        }
        return Located(starts.filter { it.p > 0 }, offNow, moved, th)
    }

    internal fun rollout(starts: List<Start>, dmax: Double): Node {
        val root = Node(-1, 1.0, 0.0, 0.0, null)
        val heap = ArrayList<Node>() // sorted by p, ties in insertion order; removeLast takes the most likely
        fun push(x: Node) {
            var lo = 0
            var hi = heap.size
            while (lo < hi) {
                val mid = (lo + hi) shr 1
                if (heap[mid].p <= x.p) lo = mid + 1 else hi = mid
            }
            heap.add(lo, x)
        }
        for (s in starts) {
            val node = Node(s.d, s.p, s.s, len[s.d shr 1] - s.s, root, s.back)
            root.children.add(node)
            push(node)
        }
        var leaves = starts.size
        while (heap.isNotEmpty()) {
            val x = heap.removeAt(heap.size - 1)
            if (x.end >= dmax || leaves >= maxLeaves) continue
            var added = 0
            for (k in turnOff[x.d] until turnOff[x.d + 1]) {
                val p = x.p * turnP[k]
                if (p < prune) continue
                val d = turnTo[k]
                val c = Node(d, p, 0.0, x.end + len[d shr 1], x)
                x.children.add(c)
                push(c)
                added += 1
            }
            if (added > 0) leaves += added - 1
        }
        return root
    }

    internal class Cluster(val members: MutableList<Node>, var p: Double, val probe: MovementModel.Point)

    internal fun probePoint(x: Node): MovementModel.Point {
        val l = len[x.d shr 1] - x.start
        return at(x.d, x.start + min(l, probeM))
    }

    internal fun clusters(children: List<Node>): List<Cluster> {
        val out = mutableListOf<Cluster>()
        val sorted = children.sortedByDescending { it.p }
        for (c in sorted) {
            val pc = probePoint(c)
            val i = out.indexOfFirst { hypot(it.probe.x - pc.x, it.probe.y - pc.y) < parallelM }
            if (i >= 0) {
                out[i].members.add(c); out[i].p += c.p
            } else {
                out.add(Cluster(mutableListOf(c), c.p, pc))
            }
        }
        return out
    }

    internal class Group(val anchors: List<Node>, var fork: Node?, var via: Node?) {
        /** Insertion-ordered identity set (Swift: `[ObjectIdentifier: Node]`). */
        val excluded = LinkedHashSet<Node>()
    }

    private class Fork(val at: Node, val clusters: List<Cluster>, val dist: Double)

    internal class Merged(val mass: Double, val chain: List<Node>, val fork: Node?, val via: Node?)

    internal fun merge(root: Node, total: Double): List<Merged> {
        val groups = mutableListOf(Group(listOf(root), null, null))
        fun live(x: Node, g: Group): List<Node> = x.children.filter { it !in g.excluded }
        fun firstFork(g: Group): Fork? {
            var x: Node? = heaviest(g.anchors)
            while (x != null) {
                val y: Node = x
                val cl = clusters(live(y, g)).filter { it.p >= mergeMinShare * total }
                if (cl.size >= 2) return Fork(y, cl, if (y === root) 0.0 else y.end)
                val kids = live(y, g)
                x = if (kids.isEmpty()) null else heaviest(kids)
            }
            return null
        }
        while (groups.size < maxRoutes) {
            var bestGroup: Group? = null
            var bestFork: Fork? = null
            for (g in groups) {
                val f = firstFork(g) ?: continue
                if (bestFork == null || f.dist < bestFork.dist) {
                    bestGroup = g; bestFork = f
                }
            }
            val g = bestGroup ?: break
            val f = bestFork ?: break
            val stay = f.clusters[0]
            if (g.via == null && f.at !== root) {
                g.fork = f.at; g.via = stay.members[0]
            }
            var split = 0
            for (c in f.clusters.drop(1)) {
                if (groups.size >= maxRoutes) break
                for (m in c.members) g.excluded.add(m)
                groups.add(Group(c.members.toList(), f.at, c.members[0]))
                split += 1
            }
            if (split == 0) break
        }
        return groups.mapNotNull { g ->
            val mass = g.anchors.fold(0.0) { a, n -> a + n.p } - g.excluded.fold(0.0) { a, n -> a + n.p }
            var x: Node? = heaviest(g.anchors)
            val chain = ArrayList<Node>()
            var y = x
            while (y != null && y !== root) {
                chain.add(0, y); y = y.parent
            }
            while (x != null) {
                val kids = live(x, g)
                x = if (kids.isEmpty()) null else heaviest(kids)
                if (x != null) chain.add(x)
            }
            if (chain.isEmpty() || mass <= 0) null else Merged(mass, chain, g.fork, g.via)
        }
    }

    internal fun pointAlong(line: List<MovementModel.Point>, cum: List<Double>, s: Double): MovementModel.Point {
        if (s <= 0) return line[0]
        if (s >= cum[cum.size - 1]) return line[line.size - 1]
        var i = 1
        while (cum[i] < s) i += 1
        val f = (s - cum[i - 1]) / max(1e-9, cum[i] - cum[i - 1])
        return MovementModel.Point(line[i - 1].x + f * (line[i].x - line[i - 1].x), line[i - 1].y + f * (line[i].y - line[i - 1].y))
    }

    internal fun describe(
        chain: List<Node>,
        fork: Node?,
        via: Node?,
        line: List<MovementModel.Point>,
        cum: List<Double>,
        heading: Double,
        moved: Boolean,
    ): Pair<String, String> {
        var name: String? = null
        for (x in chain) {
            val k = nameIdx[x.d shr 1]
            if (k >= 0) {
                name = names[k]; break
            }
        }
        val along = name?.let { " · $it" } ?: ""
        if (chain[0].back && (fork == null || fork.d == -1)) return Pair("back", "Turned back$along")
        if (fork == null || via == null || fork.d == -1) {
            if (cum.size < 2) return Pair("along", "Along this path$along")
            val p = pointAlong(line, cum, min(60.0, cum[cum.size - 1]))
            val o = line[0]
            if (!moved) {
                val deg = ((90 - atan2(p.y - o.y, p.x - o.x) * 180 / Math.PI) + 360) % 360
                val compass = listOf("north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest")[
                    swiftRounded(deg / 45).toInt() % 8,
                ]
                return Pair("along", "Heading $compass$along")
            }
            val a = wrap(atan2(p.y - o.y, p.x - o.x) - heading)
            val deg = abs(a) * 180 / Math.PI
            val side = if (a > 0) "left" else "right"
            val words = if (deg < 30) "Ahead" else if (deg < 150) "Off to the $side" else "Back the way they came"
            return Pair(if (deg < 30) "along" else if (deg < 150) side else "back", "$words$along")
        }
        val a = wrap(headingOut(via.d) - headingIn(fork.d))
        val deg = abs(a) * 180 / Math.PI
        val side = if (a > 0) "left" else "right"
        val turn = if (deg < 15) "straight" else if (deg < 45) "slight $side" else if (deg <= 145) side else "back"
        val words = mapOf(
            "straight" to "Straight on", "slight left" to "Bear left", "slight right" to "Bear right",
            "left" to "Left", "right" to "Right", "back" to "Back",
        )[turn]!!
        val dist = max(0, swiftRounded(fork.end / 10).toInt() * 10)
        return Pair(turn, "$words at the fork in $dist m$along")
    }

    /** hist: 31 positions, 2 s apart, oldest first. accuracy: accuracyMeters. */
    fun predictRoutes(history: List<MovementModel.Point>, accuracy: Double): Prediction {
        val hist = history
        val n = hist.size
        val last = hist[n - 1]
        val first = hist[0]
        val v = hypot(last.x - first.x, last.y - first.y) / ((n - 1).toDouble() * 2)
        val bin = speedBin(v)
        val dmax = distAt("q90", bin, horizon) + 30
        val loc = locate(hist, accuracy)
        val pOff = interp(offT, if (loc.offNow) offOff else offOn, horizon)
        if (loc.starts.isEmpty()) return Prediction(emptyList(), 1.0, true, bin, v)
        val root = rollout(loc.starts, dmax)
        val total = loc.starts.fold(0.0) { a, s -> a + s.p }
        var routes: List<Route> = merge(root, total).map { r ->
            val line = ArrayList<MovementModel.Point>()
            val cum = ArrayList<Double>()
            var dist = 0.0
            for (x in r.chain) {
                for (p in piece(x.d, x.start, len[x.d shr 1])) {
                    val q = line.lastOrNull()
                    if (q != null) dist += hypot(p.x - q.x, p.y - q.y)
                    line.add(p); cum.add(dist)
                }
            }
            val (turn, text) = describe(r.chain, r.fork, r.via, line, cum, loc.th, loc.moved)
            Route(r.mass / total * (1 - pOff), text, turn, line, cum)
        }
        routes = routes.sortedByDescending { it.p }
        // Standing at a junction can give the same route twice: merge routes within 20 m all the way.
        var out = mutableListOf<Route>()
        for (r in routes) {
            val twin = out.indexOfFirst { o ->
                val l = min(o.cum[o.cum.size - 1], r.cum[r.cum.size - 1])
                var s = 0.0
                var same = true
                while (s <= l) {
                    val a = pointAlong(o.line, o.cum, s)
                    val b = pointAlong(r.line, r.cum, s)
                    if (hypot(a.x - b.x, a.y - b.y) > 20) {
                        same = false; break
                    }
                    s += 25
                }
                same
            }
            if (twin >= 0) out[twin].p += r.p else out.add(r.copy())
        }
        out = out.sortedByDescending { it.p }.toMutableList()
        return Prediction(out, pOff, loc.offNow, bin, v)
    }

    /** Same input as MovementModel: the lost person's reports, oldest first, and when they were last heard. */
    fun predict(track: List<MovementModel.TrackPoint>, now: Double, accuracy: Double): Prediction =
        predictRoutes(history(track, now), accuracy)

    /** Where along each route they probably are `seconds` after the link dropped. */
    fun whereAlong(pred: Prediction, seconds: Double): List<Marker> {
        val t = seconds
        val q10 = distAt("q10", pred.bin, t)
        val q50 = distAt("q50", pred.bin, t)
        val q90 = distAt("q90", pred.bin, t)
        return pred.routes.map { r ->
            val band = mutableListOf(pointAlong(r.line, r.cum, q10))
            for ((i, c) in r.cum.withIndex()) if (c > q10 && c < q90) band.add(r.line[i])
            band.add(pointAlong(r.line, r.cum, q90))
            Marker(pointAlong(r.line, r.cum, q50), band, q50 >= r.cum[r.cum.size - 1], q10, q50, q90)
        }
    }

    companion object {
        internal const val cell = 30.0

        private fun cellKey(i: Int, j: Int): Long = (i.toLong() shl 32) or (j.toLong() and 0xffffffffL)

        internal fun wrap(a: Double): Double =
            ((a + Math.PI) % (2 * Math.PI) + 2 * Math.PI) % (2 * Math.PI) - Math.PI

        internal fun interp(xs: List<Double>, ys: List<Double>, x: Double): Double {
            if (x <= xs[0]) return ys[0]
            for (i in 1 until xs.size) {
                if (x <= xs[i]) return ys[i - 1] + (x - xs[i - 1]) / (xs[i] - xs[i - 1]) * (ys[i] - ys[i - 1])
            }
            return ys[ys.size - 1]
        }

        internal fun heaviest(xs: List<Node>): Node = xs.drop(1).fold(xs[0]) { a, b -> if (b.p > a.p) b else a }
    }
}
