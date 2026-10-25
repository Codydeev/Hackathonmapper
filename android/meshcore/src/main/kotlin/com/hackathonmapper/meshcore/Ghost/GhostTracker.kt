package com.hackathonmapper.meshcore

import kotlin.math.expm1
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Ghost Mode: what we can honestly say about each phone between the moments it is observed.
 *
 * While observations keep arriving a phone is `live`. When they stop it becomes a `ghost`: its
 * last observation stays as it was, and next to it a prediction that grows with time. After
 * `maxHorizon` it is `lost`: only the last observation is shown. When it is observed again the
 * prediction is checked against the observation (a `GhostRecovery`) and replaced by it.
 */
class GhostTracker(config: Config = Config()) {
    /** Swift struct with `var`s; the tracker keeps its own copy, like Swift's `let config`. */
    data class Config(
        var params: GhostMotionParams = GhostMotionParams.walking,
        /** Seconds an observation counts as current. */
        var freshFor: Double = 5.0,
        /** Seconds after the last observation when the prediction stops. */
        var maxHorizon: Double = 600.0,
        /**
         * Recovery further than this (squared Mahalanobis, 99.9% for 2 degrees of freedom; as a
         * level for heavy tails) from the prediction restarts the track at the observation
         * instead of blending the two.
         */
        var gate: Double = 13.82,
        /** `confidence` is the chance the phone is within this many metres of the centre. */
        var confidenceRadius: Double = 25.0,
        /** Recoveries the online calibration looks back over, and how many it needs to act. */
        var calibrationWindow: Int = 20,
        var calibrationMinimum: Int = 8,
        /**
         * Track kept per phone: the last `keepSeconds` (a learned model reads 60 s), at most
         * `keepObservations` points.
         */
        var keepSeconds: Double = 120.0,
        var keepObservations: Int = 256,
    )

    val config: Config = config.copy(params = config.params.copy())

    /** Process-noise multiplier from online calibration, 1 when predictions hold what they promise. */
    var inflation: Double = 1.0
        private set

    /** Most recent recoveries, oldest first (at most 100). */
    var recoveries: List<GhostRecovery> = emptyList()
        private set

    private val tracks: MutableMap<String, Track> = mutableMapOf()
    private val levels: MutableList<Double> = mutableListOf()

    private class Track(
        var filter: GhostKalman,
        val observations: MutableList<GhostObservation>,
        var lastHint: Double? = null,
    ) {
        val last: GhostObservation get() = observations[observations.size - 1]
    }

    val ids: List<String> get() = tracks.keys.sorted()

    fun lastObservation(id: String): GhostObservation? = tracks[id]?.last

    /** The observations behind the current estimate, oldest first. */
    fun observations(id: String): List<GhostObservation> = tracks[id]?.observations?.toList() ?: emptyList()

    /**
     * Folds in a trusted observation. Returns the recovery check if the phone was out of sight.
     * Observations older than or as old as the newest one already folded in are ignored (relays
     * deliver late copies); they return null and change nothing.
     */
    fun observe(id: String, o: GhostObservation): GhostRecovery? {
        if (!o.x.isFinite() || !o.z.isFinite() || !o.t.isFinite() || !o.sigma.isFinite()) return null
        val track = tracks[id]
        if (track == null) {
            val filter = GhostKalman(o, config.params)
            filter.inflation = inflation
            tracks[id] = Track(filter = filter, observations = mutableListOf(o))
            return null
        }
        if (!(o.t > track.last.t)) return null
        val gap = o.t - track.last.t
        var recovery: GhostRecovery? = null
        val predicted = track.filter.belief(o.t)
        val level = track.filter.innovationLevel(o)
        val restart = level > -expm1(-0.5 * config.gate)
        if (gap > config.freshFor) {
            val inside = gap <= config.maxHorizon
            val r95 = if (inside) predicted.circleRadius(0.95) else null
            val error = hypot(o.x - predicted.x, o.z - predicted.z)
            recovery = GhostRecovery(
                id = id, t = o.t, gap = gap, predictedX = predicted.x, predictedZ = predicted.z,
                predictedR95 = r95, observedX = o.x, observedZ = o.z, observedSource = o.source, error = error,
                level = if (inside) level else null,
                insideR95 = r95?.let { error <= it },
                action = if (restart || !inside) GhostRecovery.Action.restarted else GhostRecovery.Action.fused,
            )
        }
        if (restart || gap > config.maxHorizon) {
            track.filter = GhostKalman(o, config.params)
            track.filter.inflation = inflation
        } else {
            track.filter.update(o)
        }
        track.observations.add(o)
        track.observations.removeAll { o.t - it.t > config.keepSeconds }
        if (track.observations.size > config.keepObservations) {
            track.observations.subList(0, track.observations.size - config.keepObservations).clear()
        }
        if (recovery != null) {
            record(recovery)
        }
        return recovery
    }

    /**
     * The phone's own motion sensors while it has no position. Hints older than the last
     * update are ignored.
     */
    fun motion(id: String, hint: GhostMotionHint) {
        val track = tracks[id] ?: return
        if (!(hint.t >= track.filter.t)) return
        track.filter.apply(hint)
        track.lastHint = hint.t
    }

    fun forget(id: String) {
        tracks.remove(id)
    }

    fun reset() {
        tracks.clear()
        recoveries = emptyList()
        levels.clear()
        inflation = 1.0
    }

    /** What to show for one phone at local time `now`. */
    fun estimate(id: String, now: Double): GhostEstimate? {
        val track = tracks[id] ?: return null
        val last = track.last
        // A clock that runs behind the observation must not make the age negative.
        val age = max(0.0, now - last.t)
        val status = if (age <= config.freshFor) GhostStatus.live else (if (age <= config.maxHorizon) GhostStatus.ghost else GhostStatus.lost)
        if (status == GhostStatus.lost) {
            return GhostEstimate(
                id = id, t = now, status = GhostStatus.lost, basis = GhostBasis.extrapolated, lastObserved = last,
                age = age, belief = null, r50 = null, r90 = null, r95 = null, confidence = 0.0,
            )
        }
        val belief = track.filter.belief(max(now, last.t))
        val hint = track.lastHint
        val basis = if (status == GhostStatus.live) {
            GhostBasis.observed
        } else if (hint != null && hint > last.t && now - hint <= config.freshFor) {
            GhostBasis.deadReckoned
        } else {
            GhostBasis.extrapolated
        }
        return GhostEstimate(
            id = id, t = now, status = status, basis = basis, lastObserved = last, age = age, belief = belief,
            r50 = belief.circleRadius(0.5), r90 = belief.circleRadius(0.9),
            r95 = belief.circleRadius(0.95), confidence = belief.mass(config.confidenceRadius),
        )
    }

    fun estimates(now: Double): List<GhostEstimate> = ids.mapNotNull { estimate(it, now) }

    /** How recoveries compared with the predicted areas so far. */
    val calibration: GhostCalibration
        get() {
            val n = levels.size.toDouble()
            return GhostCalibration(
                count = levels.size,
                coverage50 = if (levels.isEmpty()) null else levels.count { it <= 0.5 }.toDouble() / n,
                coverage90 = if (levels.isEmpty()) null else levels.count { it <= 0.9 }.toDouble() / n,
                inflation = inflation,
            )
        }

    /**
     * Keeps the last recoveries and widens (or, slowly, narrows) future predictions when the
     * 90% area held the phone clearly less (or more) often than 90% of the time.
     */
    private fun record(recovery: GhostRecovery) {
        val list = recoveries + recovery
        recoveries = if (list.size > 100) list.drop(1) else list
        val level = recovery.level ?: return
        levels.add(level)
        if (levels.size > config.calibrationWindow) levels.removeAt(0)
        if (levels.size < config.calibrationMinimum) return
        val c = calibration.coverage90 ?: return
        if (c < 0.8) {
            inflation = min(4.0, inflation * 1.25)
        } else if (c > 0.97) {
            inflation = max(1.0, inflation / 1.1)
        } else {
            return
        }
        for (track in tracks.values) track.filter.inflation = inflation
    }
}

@Serializable
enum class GhostStatus(val rawValue: String) {
    /** Observed within `freshFor`: the position shown is a measurement. */
    @SerialName("live") live("live"),
    /** Not observed lately: last observation plus a prediction, never a live position. */
    @SerialName("ghost") ghost("ghost"),
    /** Gone longer than `maxHorizon`: only the last observation. */
    @SerialName("lost") lost("lost");
}

@Serializable
enum class GhostBasis(val rawValue: String) {
    @SerialName("observed") observed("observed"),
    /** Motion model only: nothing new is known about this phone since `lastObserved`. */
    @SerialName("extrapolated") extrapolated("extrapolated"),
    /** The phone's own steps and compass carried the estimate forward. */
    @SerialName("deadReckoned") deadReckoned("deadReckoned");
}

data class GhostEstimate(
    val id: String,
    /** The local time this estimate is for. */
    val t: Double,
    val status: GhostStatus,
    val basis: GhostBasis,
    /** Always shown as it was measured, with its own time and source. */
    val lastObserved: GhostObservation,
    /** Seconds since `lastObserved`. */
    val age: Double,
    /** Where the phone probably is now; null when lost. */
    val belief: GhostBelief?,
    /** Radii of circles around the belief's centre holding 50, 90 and 95% of it, metres. */
    val r50: Double?,
    val r90: Double?,
    val r95: Double?,
    /** Chance the phone is within `Config.confidenceRadius` of the centre. */
    val confidence: Double,
) {
    val isPrediction: Boolean get() = status != GhostStatus.live

    /** One line for people, e.g. "Predicted: last seen 1 min 12 s ago (Bluetooth), 95% within 64 m". */
    val summary: String
        get() {
            val seen = "last seen ${duration(age)} ago (${lastObserved.source.label})"
            return when (status) {
                GhostStatus.live -> "Observed (${lastObserved.source.label})"
                GhostStatus.ghost -> {
                    val how = if (basis == GhostBasis.deadReckoned) "Dead reckoning" else "Predicted"
                    "$how: $seen, 95% within ${swiftRounded(r95 ?: 0.0).toInt()} m"
                }
                GhostStatus.lost -> "Lost: $seen"
            }
        }

    companion object {
        internal fun duration(seconds: Double): String {
            val s = swiftRounded(seconds).toInt()
            return if (s < 60) "$s s" else (if (s % 60 == 0) "${s / 60} min" else "${s / 60} min ${s % 60} s")
        }
    }
}

/** A prediction checked against the observation that ended a gap. */
@Serializable
data class GhostRecovery(
    val id: String,
    val t: Double,
    /** Seconds without observations. */
    val gap: Double,
    val predictedX: Double,
    val predictedZ: Double,
    val predictedR95: Double? = null,
    val observedX: Double,
    val observedZ: Double,
    val observedSource: GhostObservation.Source,
    /** Metres from the predicted centre to the observation. */
    val error: Double,
    /**
     * Mass of the smallest predicted ellipse reaching the observation, allowing for the
     * observation's own error; uniform on 0...1 when predictions are calibrated. Null after
     * `maxHorizon`, when there was no prediction.
     */
    val level: Double? = null,
    /** The observation fell inside the 95% circle shown on the map. */
    val insideR95: Boolean? = null,
    val action: Action,
) {
    @Serializable
    enum class Action(val rawValue: String) {
        /** The observation was where the prediction allowed: blended in. */
        @SerialName("fused") fused("fused"),
        /** Too far from the prediction (or the gap was too long): the track starts again there. */
        @SerialName("restarted") restarted("restarted");
    }
}

data class GhostCalibration(
    val count: Int,
    /** Share of recoveries inside the predicted 50% / 90% areas. */
    val coverage50: Double?,
    val coverage90: Double?,
    val inflation: Double,
)

internal val GhostObservation.Source.label: String
    get() = when (this) {
        GhostObservation.Source.gps -> "GPS"
        GhostObservation.Source.bluetooth -> "Bluetooth"
        GhostObservation.Source.uwb -> "UWB"
        GhostObservation.Source.manual -> "set by hand"
    }
