package com.hackathonmapper.meshcore

import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.expm1
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.sin
import kotlin.math.sqrt
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * A trusted position of one phone at one moment, in the shared floor frame (x east, z north,
 * metres). Only measurements go in here: never feed a Ghost Mode prediction back as an
 * observation, or the prediction would end up confirming itself.
 */
@Serializable
data class GhostObservation(
    /**
     * When the position was true, in seconds on THIS phone's clock. For a relayed report use
     * local receipt time minus its age at handoff; never subtract two phones' clocks.
     */
    val t: Double,
    val x: Double,
    val z: Double,
    /** Standard deviation of the position along each axis, metres (about the 68% radius). */
    val sigma: Double,
    val source: Source,
    /** Velocity measured with the position (GPS Doppler speed and course), if any. */
    val velocity: GhostVelocity? = null,
    /** Where the position came from, carried into the provenance of predictions made from it. */
    val provenance: Provenance? = null,
    /** The source said its belief is a ring or several spots: the position is not a good single guess. */
    val ambiguous: Boolean = false,
) {
    @Serializable
    enum class Source(val rawValue: String) {
        @SerialName("gps") gps("gps"),
        @SerialName("bluetooth") bluetooth("bluetooth"),
        @SerialName("uwb") uwb("uwb"),
        @SerialName("manual") manual("manual");
    }

    /** Holds the `init?(_:receivedAt:frameId:)` extension from GhostPredictor.kt. */
    companion object
}

/** Velocity in m/s along x (east) and z (north), with its standard deviation per axis. */
@Serializable
data class GhostVelocity(
    val vx: Double,
    val vz: Double,
    val sigma: Double,
) {
    companion object {
        /**
         * From a speed and a compass heading (radians clockwise from north), e.g. Location's
         * `speed` and `bearing`. The spread is split along and across the direction of travel and
         * returned as the larger of the two, so it never claims more than it knows.
         */
        fun fromHeading(speed: Double, heading: Double, speedSigma: Double, headingSigma: Double): GhostVelocity {
            val across = speed * headingSigma
            return GhostVelocity(vx = speed * sin(heading), vz = speed * cos(heading), sigma = max(speedSigma, across))
        }
    }
}

/**
 * What the phone's own motion sensors say, while its position is unknown. Only the phone that
 * carries the sensors has these; a lost peer's sensors cannot reach anyone.
 */
@Serializable
data class GhostMotionHint(
    val t: Double,
    /** Accelerometer says the phone is at rest (no steps, little variance). */
    val stationary: Boolean,
    /** Walking velocity from steps (pedometer pace) and heading (compass), if both are known. */
    val velocity: GhostVelocity? = null,
) {
    /** Holds the `init(_ m: MotionObservation)` extension from GhostPredictor.kt. */
    companion object
}

/**
 * How Ghost Mode models walking. Fitted on training walks by `ghost/heldout` (never on the
 * held-out Hervanta walks it is scored on); see ghost/README.md for the numbers.
 *
 * Swift struct with `var`s: copy before mutating a shared instance. `walking` returns a fresh
 * instance on every read so `val p = GhostMotionParams.walking; p.x = …` cannot change it.
 */
@Serializable
data class GhostMotionParams(
    var kind: Kind,
    /**
     * Per-axis standard deviation of walking velocity, m/s (mean-reverting), or the
     * acceleration noise density, m/s^1.5 (constant velocity).
     */
    var motionNoise: Double,
    /** Seconds over which a velocity is forgotten (mean-reverting only). */
    var persistence: Double,
    /** Multipliers on the sigma a source reports: sources tend to over- or understate it. */
    var gpsSigmaScale: Double,
    var radioSigmaScale: Double,
    /** Floor on any observation's sigma, metres. */
    var minSigma: Double = 1.0,
    /** Prior per-axis velocity spread when a track starts, m/s. */
    var initialSpeedSigma: Double,
    /** Multiplier on the sigma of an `ambiguous` observation, on top of its source's scale. */
    var ambiguousSigmaScale: Double = 1.0,
    /**
     * Predictions are never sharper than the last position as the filter trusts it (reported
     * sigma times the source's scale, when that is larger) instead of as the source reported it.
     */
    var floorAtTrustedSigma: Boolean = false,
    /**
     * Dead reckoning drifts with distance walked, not with time: step length and compass errors
     * persist. Per-axis spread added per metre walked on motion sensors since the last position.
     */
    var deadReckoningDrift: Double = 0.15,
    /**
     * Variance multipliers by seconds since the last position, so the 95% circle holds 95% of
     * training walks (split conformal), one table per kind of source; interpolated in log time.
     * Empty means 1. Not applied while motion sensors carry the estimate (the drift covers that).
     */
    var gpsCalibration: List<HorizonScale> = emptyList(),
    var radioCalibration: List<HorizonScale> = emptyList(),
) {
    @Serializable
    enum class Kind(val rawValue: String) {
        /** Velocity random walk (white acceleration): the textbook constant-velocity filter. */
        @SerialName("constantVelocity") constantVelocity("constantVelocity"),
        /**
         * Velocity that is forgotten over `persistence` seconds (Ornstein–Uhlenbeck): people
         * turn and stop, so long gaps grow like a random walk instead of quadratically.
         */
        @SerialName("meanReverting") meanReverting("meanReverting");
    }

    @Serializable
    data class HorizonScale(
        val horizon: Double,
        val variance: Double,
    )

    internal fun calibration(source: GhostObservation.Source, h: Double): Double {
        val table = if (source == GhostObservation.Source.gps) gpsCalibration else radioCalibration
        val first = table.firstOrNull() ?: return 1.0
        val last = table.last()
        if (h <= first.horizon) return 1 + (first.variance - 1) * max(0.0, h) / first.horizon
        if (h >= last.horizon) return last.variance
        val i = table.indexOfFirst { it.horizon >= h }
        val a = table[i - 1]
        val b = table[i]
        val f = ln(h / a.horizon) / ln(b.horizon / a.horizon)
        return a.variance + f * (b.variance - a.variance)
    }

    internal fun sigma(o: GhostObservation): Double {
        val scale = (if (o.source == GhostObservation.Source.gps) gpsSigmaScale else radioSigmaScale) *
            (if (o.ambiguous) ambiguousSigmaScale else 1.0)
        return max(minSigma, o.sigma * scale)
    }

    /** The spread a prediction from `o` may never go below. */
    internal fun floorSigma(o: GhostObservation): Double =
        if (floorAtTrustedSigma) max(o.sigma, sigma(o)) else o.sigma

    companion object {
        /**
         * Fitted by `ghost/heldout/run.sh` on walks from the eight training areas, never on the
         * held-out Hervanta walks (ghost/results/params.json). The calibration tables are each
         * horizon's multiplier for the hardest training area.
         */
        val walking: GhostMotionParams
            get() {
                val p = GhostMotionParams(
                    kind = Kind.meanReverting, motionNoise = 0.749, persistence = 78.9, gpsSigmaScale = 0.228,
                    radioSigmaScale = 1.221, initialSpeedSigma = 0.749,
                )
                p.gpsCalibration = listOf(
                    HorizonScale(horizon = 5.0, variance = 0.709), HorizonScale(horizon = 10.0, variance = 2.292),
                    HorizonScale(horizon = 30.0, variance = 2.213), HorizonScale(horizon = 60.0, variance = 1.214),
                    HorizonScale(horizon = 120.0, variance = 0.934), HorizonScale(horizon = 180.0, variance = 0.948),
                )
                p.radioCalibration = listOf(
                    HorizonScale(horizon = 5.0, variance = 0.834), HorizonScale(horizon = 10.0, variance = 0.984),
                    HorizonScale(horizon = 30.0, variance = 1.798), HorizonScale(horizon = 60.0, variance = 1.231),
                    HorizonScale(horizon = 120.0, variance = 1.061), HorizonScale(horizon = 180.0, variance = 1.034),
                )
                p.floorAtTrustedSigma = true
                p.ambiguousSigmaScale = 2.0
                return p
            }
    }
}

/**
 * Kalman filter over [x, z, vx, vz]. Feed it observations in time order, ask it where the phone
 * probably is at any later time.
 *
 * A Swift struct with mutating methods: wherever Swift copies it (`var b = a`), call [copy].
 */
class GhostKalman private constructor(
    params: GhostMotionParams,
    t: Double,
    s: DoubleArray,
    p: DoubleArray,
    observedAt: Double,
    observedSource: GhostObservation.Source,
    observedSigma: Double,
) {
    /** Swift's `(vx: Double, vz: Double)` tuple. */
    data class Velocity(val vx: Double, val vz: Double)

    var params: GhostMotionParams = params
        private set

    /** Time of the state below. */
    var t: Double = t
        private set

    /** State [x, z, vx, vz] and its covariance, row major 4 x 4. */
    internal var s: DoubleArray = s
        private set
    internal var p: DoubleArray = p
        private set

    /**
     * Multiplier on the process noise; the tracker raises it when recoveries land outside the
     * predicted area more often than promised.
     */
    var inflation: Double = 1.0

    /** Metres walked on motion sensors alone since the last position (see `deadReckoningDrift`). */
    var deadReckoned: Double = 0.0
        private set

    /** The last position folded in: when, from what, and its reported sigma. */
    var observedAt: Double = observedAt
        private set
    var observedSource: GhostObservation.Source = observedSource
        private set
    private var observedSigma: Double = observedSigma

    /** Motion sensors have spoken since the last position. */
    private var hinted = false

    constructor(o: GhostObservation, params: GhostMotionParams) : this(
        params = params,
        t = o.t,
        s = doubleArrayOf(o.x, o.z, 0.0, 0.0),
        p = initialCovariance(params.sigma(o), params.initialSpeedSigma * params.initialSpeedSigma),
        observedAt = o.t,
        observedSource = o.source,
        observedSigma = params.floorSigma(o),
    ) {
        o.velocity?.let { updateVelocity(it) }
    }

    /** A value copy, like assigning the Swift struct. */
    fun copy(): GhostKalman {
        val c = GhostKalman(params, t, s.copyOf(), p.copyOf(), observedAt, observedSource, observedSigma)
        c.inflation = inflation
        c.deadReckoned = deadReckoned
        c.hinted = hinted
        return c
    }

    /** Position belief at `time` (never before the last update). */
    fun position(time: Double): GhostGaussian {
        val copy = copy()
        copy.advance(time)
        return copy.positionNow
    }

    val positionNow: GhostGaussian
        get() {
            val drift = params.deadReckoningDrift * deadReckoned
            return GhostGaussian(x = s[0], z = s[1], xx = p[0] + drift * drift, xz = p[1], zz = p[5] + drift * drift)
        }

    val velocityNow: Velocity get() = Velocity(s[2], s[3])

    /**
     * What to show for `time`: the filter's belief, calibrated for the time since the last
     * position, and never sharper than that position was.
     */
    fun belief(time: Double): GhostBelief {
        val core = position(time)
        val m = if (hinted) 1.0 else params.calibration(observedSource, max(0.0, time - observedAt))
        // Floor first so the calibration scales exactly what it was fitted on, then again so a
        // multiplier below 1 cannot undercut the observation.
        val floor = observedSigma * observedSigma
        return GhostBelief(
            core = GhostGaussian(
                x = core.x, z = core.z, xx = max(max(core.xx, floor) * m, floor),
                xz = core.xz * m, zz = max(max(core.zz, floor) * m, floor),
            ),
        )
    }

    /**
     * Mass of the smallest predicted ellipse that reaches the observation, allowing for its own
     * error: near 0 where expected, near 1 far out; uniform when the filter is calibrated.
     */
    fun innovationLevel(o: GhostObservation): Double {
        val g = belief(o.t).core.copy()
        val r = params.sigma(o)
        g.xx += r * r
        g.zz += r * r
        return g.level(o.x, o.z)
    }

    /**
     * Belief about where the next observation will land: the position belief plus that
     * observation's own error.
     */
    fun innovation(o: GhostObservation): GhostGaussian {
        val g = position(o.t)
        val r = params.sigma(o)
        g.xx += r * r
        g.zz += r * r
        return g
    }

    /** Moves the state forward; times in the past are ignored (the filter never runs backwards). */
    fun advance(time: Double) {
        val dt = time - t
        if (!(dt > 0)) return
        val tr = transition(dt)
        val a = tr[0]
        val b = tr[1]
        val qpp = tr[2]
        val qpv = tr[3]
        val qvv = tr[4]
        val q = inflation
        // State: position gains b * velocity, velocity decays by a.
        s = doubleArrayOf(s[0] + b * s[2], s[1] + b * s[3], a * s[2], a * s[3])
        // P = F P F' + Q, F = [[I, bI], [0, aI]].
        val f = DoubleArray(16)
        f[0] = 1.0; f[5] = 1.0; f[2] = b; f[7] = b; f[10] = a; f[15] = a
        p = mul(mul(f, p), transpose(f))
        p[0] += q * qpp; p[5] += q * qpp
        p[2] += q * qpv; p[8] += q * qpv; p[7] += q * qpv; p[13] += q * qpv
        p[10] += q * qvv; p[15] += q * qvv
        t = time
    }

    /**
     * Advances to the observation and folds it in. Returns the squared Mahalanobis distance of
     * the observation from where the filter expected it (chi-square with 2 degrees of freedom
     * when the filter is right).
     */
    fun update(o: GhostObservation): Double {
        advance(o.t)
        val r = params.sigma(o)
        // The drift is not in P, so it joins the position spread for this update only.
        val drift = params.deadReckoningDrift * deadReckoned
        p[0] += drift * drift
        p[5] += drift * drift
        deadReckoned = 0.0
        hinted = false
        observedAt = o.t
        observedSource = o.source
        observedSigma = params.floorSigma(o)
        val d2 = updatePosition(o.x, o.z, r * r)
        o.velocity?.let { updateVelocity(it) }
        return d2
    }

    /** Folds in a velocity measurement (GPS Doppler or steps + compass) at the current time. */
    fun updateVelocity(v: GhostVelocity) {
        val r2 = max(v.sigma, 0.05) * max(v.sigma, 0.05)
        update(intArrayOf(2, 3), doubleArrayOf(v.vx, v.vz), r2)
    }

    /** Motion sensors at time `hint.t`: at rest pins the velocity to zero, steps + heading give it. */
    fun apply(hint: GhostMotionHint) {
        val walked = if (hint.stationary) 0.0 else hint.velocity?.let { hypot(it.vx, it.vz) * max(0.0, hint.t - t) } ?: 0.0
        deadReckoned += walked
        hinted = true
        advance(hint.t)
        if (hint.stationary) {
            update(intArrayOf(2, 3), doubleArrayOf(0.0, 0.0), 0.15 * 0.15)
        } else {
            hint.velocity?.let { updateVelocity(it) }
        }
    }

    private fun updatePosition(x: Double, z: Double, r2: Double): Double =
        update(intArrayOf(0, 1), doubleArrayOf(x, z), r2)

    /** Standard update for a measurement of two state entries with isotropic noise `r2`. */
    private fun update(rows: IntArray, values: DoubleArray, r2: Double): Double {
        val i = rows[0]
        val j = rows[1]
        val y0 = values[0] - s[i]
        val y1 = values[1] - s[j]
        val s00 = p[i * 4 + i] + r2
        val s01 = p[i * 4 + j]
        val s11 = p[j * 4 + j] + r2
        val det = max(s00 * s11 - s01 * s01, 1e-12)
        val inv00 = s11 / det
        val inv01 = -s01 / det
        val inv11 = s00 / det
        val d2 = y0 * (inv00 * y0 + inv01 * y1) + y1 * (inv01 * y0 + inv11 * y1)
        // K = P H' S^-1, a 4 x 2 matrix.
        val k = DoubleArray(8)
        for (r in 0 until 4) {
            val pi = p[r * 4 + i]
            val pj = p[r * 4 + j]
            k[r * 2] = pi * inv00 + pj * inv01
            k[r * 2 + 1] = pi * inv01 + pj * inv11
        }
        val ns = s.copyOf()
        for (r in 0 until 4) ns[r] += k[r * 2] * y0 + k[r * 2 + 1] * y1
        s = ns
        // Joseph form keeps P symmetric and positive: (I - KH) P (I - KH)' + K R K'.
        val ikh = DoubleArray(16)
        for (r in 0 until 4) {
            ikh[r * 4 + r] = 1.0
            ikh[r * 4 + i] -= k[r * 2]
            ikh[r * 4 + j] -= k[r * 2 + 1]
        }
        val np = mul(mul(ikh, p), transpose(ikh))
        for (r in 0 until 4) {
            for (c in 0 until 4) np[r * 4 + c] += r2 * (k[r * 2] * k[c * 2] + k[r * 2 + 1] * k[c * 2 + 1])
        }
        p = np
        return d2
    }

    /**
     * Per-axis transition over `dt`: position += b * v, v *= a, and the process noise block
     * [[qpp, qpv], [qpv, qvv]] for one axis. Returns [a, b, qpp, qpv, qvv].
     */
    private fun transition(dt: Double): DoubleArray = when (params.kind) {
        GhostMotionParams.Kind.constantVelocity -> {
            val q = params.motionNoise * params.motionNoise
            doubleArrayOf(1.0, dt, q * dt * dt * dt / 3, q * dt * dt / 2, q * dt)
        }
        GhostMotionParams.Kind.meanReverting -> {
            val tau = params.persistence
            val s2 = params.motionNoise * params.motionNoise
            val u = dt / tau
            val oneMinusA = -expm1(-u)
            // Integrated Ornstein-Uhlenbeck: var of the travelled distance is
            // s2 tau^2 (2u - 3 + 4e^-u - e^-2u); its series avoids cancellation for small u.
            val core = if (u < 1e-2) u * u * u * (2.0 / 3 - u / 2 + 7 * u * u / 30)
            else 2 * u - 3 + 4 * exp(-u) - exp(-2 * u)
            doubleArrayOf(
                1 - oneMinusA, tau * oneMinusA, s2 * tau * tau * core,
                s2 * tau * oneMinusA * oneMinusA, s2 * -expm1(-2 * u),
            )
        }
    }

    override fun equals(other: Any?): Boolean {
        if (other !is GhostKalman) return false
        return params == other.params && t == other.t && doublesEqual(s, other.s) && doublesEqual(p, other.p) &&
            inflation == other.inflation && deadReckoned == other.deadReckoned && observedAt == other.observedAt &&
            observedSource == other.observedSource && observedSigma == other.observedSigma && hinted == other.hinted
    }

    override fun hashCode(): Int {
        var result = params.hashCode()
        result = 31 * result + (t + 0.0).hashCode()
        result = 31 * result + s.map { it + 0.0 }.hashCode()
        result = 31 * result + p.map { it + 0.0 }.hashCode()
        result = 31 * result + observedSource.hashCode()
        return result
    }

    companion object {
        private fun initialCovariance(r: Double, v0: Double): DoubleArray = doubleArrayOf(
            r * r, 0.0, 0.0, 0.0,
            0.0, r * r, 0.0, 0.0,
            0.0, 0.0, v0, 0.0,
            0.0, 0.0, 0.0, v0,
        )

        /** Element-wise Swift `==` (0.0 equals -0.0, NaN never equal). */
        private fun doublesEqual(a: DoubleArray, b: DoubleArray): Boolean =
            a.size == b.size && a.indices.all { a[it] == b[it] }

        private fun mul(a: DoubleArray, b: DoubleArray): DoubleArray {
            val c = DoubleArray(16)
            for (r in 0 until 4) {
                for (k in 0 until 4) {
                    val v = a[r * 4 + k]
                    if (v == 0.0) continue
                    for (col in 0 until 4) c[r * 4 + col] += v * b[k * 4 + col]
                }
            }
            return c
        }

        private fun transpose(a: DoubleArray): DoubleArray {
            val c = a.copyOf()
            for (r in 0 until 4) for (col in 0 until 4) c[col * 4 + r] = a[r * 4 + col]
            return c
        }
    }
}

/**
 * The plain baseline: keep going at the velocity of the last `window` seconds, with a spread
 * that grows from the last fix's error, a velocity error times the gap, and a random-walk term.
 */
@Serializable
data class GhostConstantVelocity(
    /** Seconds of track the velocity is averaged over. */
    var window: Double,
    /** Multiplier on the last observation's sigma for the starting spread. */
    var startScale: Double,
    /** Velocity error per axis, m/s: spread grows by this times the gap. */
    var velocitySigma: Double,
    /** Random-walk diffusion, m²/s: spread² also grows by this times the gap. */
    var diffusion: Double,
) {
    /** `track` is oldest first. Returns null for an empty track. */
    fun predict(track: List<GhostObservation>, time: Double): GhostGaussian? {
        val last = track.lastOrNull() ?: return null
        var vx = 0.0
        var vz = 0.0
        val ref = track.lastOrNull { last.t - it.t >= window - 1e-6 } ?: (if (track.size > 1) track.first() else null)
        if (ref != null && last.t - ref.t > 0) {
            vx = (last.x - ref.x) / (last.t - ref.t)
            vz = (last.z - ref.z) / (last.t - ref.t)
        }
        val h = max(0.0, time - last.t)
        val s0 = startScale * last.sigma
        val var2 = s0 * s0 + velocitySigma * velocitySigma * h * h + diffusion * h
        return GhostGaussian.isotropic(x = last.x + vx * h, z = last.z + vz * h, sigma = sqrt(var2))
    }

    companion object {
        /**
         * Fitted by `ghost/heldout/run.sh` on mesh-quality history from the training areas
         * (ghost/results/params.json). A fresh instance on every read (Swift value semantics).
         */
        val walking: GhostConstantVelocity
            get() = GhostConstantVelocity(window = 30.0, startScale = 1.13, velocitySigma = 0.86, diffusion = 0.8)
    }
}
