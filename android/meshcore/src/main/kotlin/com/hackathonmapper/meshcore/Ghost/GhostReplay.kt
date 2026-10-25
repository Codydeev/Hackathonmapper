package com.hackathonmapper.meshcore

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlinx.serialization.Serializable

/**
 * A scripted Ghost Mode run: observations and motion hints at given times, the true paths, and
 * what must hold along the way. The scenarios in ghost/fixtures/ are the regression tests and
 * can also drive a demo with no phones moving.
 */
@Serializable
data class GhostScenario(
    val name: String,
    val description: String,
    val freshFor: Double? = null,
    val maxHorizon: Double? = null,
    val events: List<Event>,
    /** True paths, [t, x, z] rows sorted by t, linearly interpolated. */
    val truth: Map<String, List<List<Double>>>? = null,
    val checks: List<Check>,
    /** Run until this time (default: the last event or check). */
    val end: Double? = null,
) {
    @Serializable
    data class Event(
        /** Local time the event reaches the tracker. */
        val t: Double,
        val id: String,
        val observe: Observation? = null,
        val motion: Motion? = null,
    )

    @Serializable
    data class Observation(
        val x: Double,
        val z: Double,
        val sigma: Double,
        val source: GhostObservation.Source,
        /** When the position was true relative to `t` (negative for a late relay); default 0. */
        val age: Double? = null,
        val vx: Double? = null,
        val vz: Double? = null,
        val velocitySigma: Double? = null,
    )

    @Serializable
    data class Motion(
        val stationary: Boolean,
        val speed: Double? = null,
        /** Radians clockwise from north. */
        val heading: Double? = null,
        val speedSigma: Double? = null,
        val headingSigma: Double? = null,
    )

    /** Requirements at time `t` for phone `id`; absent fields are not checked. */
    @Serializable
    data class Check(
        val t: Double,
        val id: String,
        val status: GhostStatus? = null,
        val basis: GhostBasis? = null,
        val lastObservedT: Double? = null,
        /** The true position (from `truth`) lies inside the 95% circle. */
        val truthInsideR95: Boolean? = null,
        val r95Min: Double? = null,
        val r95Max: Double? = null,
        val confidenceMax: Double? = null,
        /** A recovery happened at exactly `t` with this action / landing inside the 95% circle. */
        val recovery: GhostRecovery.Action? = null,
        val recoveryInsideR95: Boolean? = null,
        val note: String? = null,
    )
}

class GhostReplayResult(
    val name: String,
    val failures: List<String>,
    /** One sample per phone with a true path, every second. */
    val samples: List<Sample>,
    val recoveries: List<GhostRecovery>,
) {
    data class Sample(
        val t: Double,
        val id: String,
        val status: GhostStatus,
        val age: Double,
        val error: Double?,
        val r95: Double?,
    )

    /** Over the seconds a phone was a ghost with a known true position. */
    val ghostSeconds: Int get() = ghostSamples.size
    val ghostCoverageR95: Double?
        get() = if (ghostSamples.isEmpty()) null
        else ghostSamples.count { it.error!! <= it.r95!! }.toDouble() / ghostSamples.size.toDouble()
    val ghostMedianError: Double?
        get() {
            val e = ghostSamples.map { it.error!! }.sorted()
            return if (e.isEmpty()) null else e[e.size / 2]
        }
    private val ghostSamples: List<Sample>
        get() = samples.filter { it.status == GhostStatus.ghost && it.error != null && it.r95 != null }
}

object GhostReplay {
    /** Swift `JSONDecoder().decode`; errors surface as `SerializationException`. */
    fun load(data: ByteArray): GhostScenario = decodeMeshJson(GhostScenario.serializer(), data)

    fun run(s: GhostScenario, params: GhostMotionParams = GhostMotionParams.walking): GhostReplayResult {
        val config = GhostTracker.Config()
        config.params = params
        s.freshFor?.let { config.freshFor = it }
        s.maxHorizon?.let { config.maxHorizon = it }
        val tracker = GhostTracker(config)
        val events = s.events.withIndex()
            .sortedWith(compareBy<IndexedValue<GhostScenario.Event>>({ it.value.t }, { it.index }))
            .map { it.value }
        val end = s.end ?: max(events.lastOrNull()?.t ?: 0.0, s.checks.maxOfOrNull { it.t } ?: 0.0)
        val failures = mutableListOf<String>()
        val samples = mutableListOf<GhostReplayResult.Sample>()
        val recoveries = mutableListOf<GhostRecovery>()
        var next = 0
        val checks = ArrayDeque(s.checks.sortedBy { it.t })

        fun step(now: Double) {
            while (next < events.size && events[next].t <= now) {
                val e = events[next]
                next += 1
                e.observe?.let { o ->
                    val velocity = o.vx?.let { vx -> o.vz?.let { vz -> GhostVelocity(vx = vx, vz = vz, sigma = o.velocitySigma ?: 0.5) } }
                    val obs = GhostObservation(
                        t = e.t + (o.age ?: 0.0), x = o.x, z = o.z, sigma = o.sigma, source = o.source,
                        velocity = velocity,
                    )
                    tracker.observe(e.id, obs)?.let { recoveries.add(it) }
                }
                e.motion?.let { m ->
                    var velocity: GhostVelocity? = null
                    if (m.speed != null && m.heading != null) {
                        velocity = GhostVelocity.fromHeading(
                            speed = m.speed, heading = m.heading, speedSigma = m.speedSigma ?: 0.2,
                            headingSigma = m.headingSigma ?: 0.35,
                        )
                    }
                    tracker.motion(e.id, GhostMotionHint(t = e.t, stationary = m.stationary, velocity = velocity))
                }
            }
        }

        var now = 0.0
        while (now <= end + 1e-9) {
            step(now)
            while (true) {
                val c = checks.firstOrNull() ?: break
                if (!(c.t <= now + 1e-9)) break
                checks.removeFirst()
                failures += check(c, tracker, recoveries, s.truth)
            }
            for (id in (s.truth ?: emptyMap()).keys.sorted()) {
                val e = tracker.estimate(id, now) ?: continue
                val p = position(s.truth?.get(id), now) ?: continue
                val error = e.belief?.let { hypot(it.x - p.x, it.z - p.z) }
                samples.add(GhostReplayResult.Sample(t = now, id = id, status = e.status, age = e.age, error = error, r95 = e.r95))
            }
            now += 1
        }
        for (c in checks) failures.add("check at t=${c.t} for ${c.id} never ran (after end $end)")
        return GhostReplayResult(
            name = s.name, failures = failures.map { "${s.name}: $it" }, samples = samples,
            recoveries = recoveries,
        )
    }

    internal fun check(
        c: GhostScenario.Check,
        tracker: GhostTracker,
        recoveries: List<GhostRecovery>,
        truth: Map<String, List<List<Double>>>?,
    ): List<String> {
        val out = mutableListOf<String>()
        val at = "t=${c.t} ${c.id}${c.note?.let { " ($it)" } ?: ""}"
        if (c.recovery != null || c.recoveryInsideR95 != null) {
            val r = recoveries.lastOrNull { it.id == c.id && abs(it.t - c.t) < 1e-6 }
            if (r != null) {
                if (c.recovery != null && r.action != c.recovery) out.add("$at: recovery ${r.action}, want ${c.recovery}")
                if (c.recoveryInsideR95 != null && r.insideR95 != c.recoveryInsideR95) {
                    // Swift's String(describing:) of an Optional.
                    val got = r.insideR95?.let { "Optional($it)" } ?: "nil"
                    out.add("$at: recovery insideR95 $got, want ${c.recoveryInsideR95}")
                }
            } else {
                out.add("$at: no recovery")
            }
        }
        val e = tracker.estimate(c.id, c.t) ?: return out + (if (c.status != null) listOf("$at: no estimate") else emptyList())
        if (c.status != null && e.status != c.status) out.add("$at: status ${e.status}, want ${c.status}")
        if (c.basis != null && e.basis != c.basis) out.add("$at: basis ${e.basis}, want ${c.basis}")
        if (c.lastObservedT != null && abs(e.lastObserved.t - c.lastObservedT) > 1e-6) {
            out.add("$at: lastObserved.t ${e.lastObserved.t}, want ${c.lastObservedT}")
        }
        if (c.r95Min != null && (e.r95 ?: 0.0) < c.r95Min) out.add("$at: r95 ${e.r95 ?: 0.0} < ${c.r95Min}")
        if (c.r95Max != null && (e.r95 ?: Double.POSITIVE_INFINITY) > c.r95Max) {
            out.add("$at: r95 ${e.r95 ?: Double.POSITIVE_INFINITY} > ${c.r95Max}")
        }
        if (c.confidenceMax != null && e.confidence > c.confidenceMax) out.add("$at: confidence ${e.confidence} > ${c.confidenceMax}")
        if (c.truthInsideR95 != null) {
            val want = c.truthInsideR95
            val p = position(truth?.get(c.id), c.t)
            val b = e.belief
            val r = e.r95
            if (p != null && b != null && r != null) {
                val d = hypot(b.x - p.x, b.z - p.z)
                if ((d <= r) != want) out.add("$at: truth ${d.toInt()} m from centre, r95 ${r.toInt()} m, want inside=$want")
            } else {
                out.add("$at: no truth or no belief to compare")
            }
        }
        return out
    }

    /** Swift returns an `(x:, z:)` tuple; [FloorPoint] carries the same two fields. */
    internal fun position(path: List<List<Double>>?, t: Double): FloorPoint? {
        if (path == null) return null
        val first = path.firstOrNull() ?: return null
        val last = path.last()
        if (!(t >= first[0] && t <= last[0])) return null
        var i = 0
        while (i + 1 < path.size && path[i + 1][0] < t) i += 1
        val a = path[i]
        val b = path[min(i + 1, path.size - 1)]
        val f = if (b[0] > a[0]) (t - a[0]) / (b[0] - a[0]) else 0.0
        return FloorPoint(a[1] + f * (b[1] - a[1]), a[2] + f * (b[2] - a[2]))
    }
}
