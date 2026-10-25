package com.hackathonmapper.meshcore

import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Extended Kalman filter over this phone's floor position (x, z), its radio's RSSI offset (dB) and
 * the gyro heading's offset from the frame (radians).
 *
 * Steps move the estimate and grow its uncertainty; each anchor's RSSI corrects it in the dB
 * domain, where fading is roughly Gaussian. Because uncertainty only grows as fast as the phone
 * walks, an RSSI value implying a jump the steps cannot explain fails the innovation gate. The
 * offsets absorb errors that differ between devices and sensors: a radio reading a few dB hot or
 * cold, and gyro heading that slowly drifts away from the frame over minutes of walking.
 *
 * A Swift struct with mutating methods: use `copy()` where Swift would copy the value.
 */
class PositionFilter private constructor(
    private val s: DoubleArray,
    private val p: Array<DoubleArray>,
) {
    enum class UpdateResult {
        accepted, rejected, skipped
    }

    constructor(
        x: Double,
        z: Double,
        positionSigma: Double,
        receiverOffsetDB: Double = 0.0,
        offsetSigmaDB: Double = 4.0,
        headingSigma: Double = 0.2,
    ) : this(
        doubleArrayOf(x, z, receiverOffsetDB, 0.0),
        diagonal(
            doubleArrayOf(
                positionSigma * positionSigma, positionSigma * positionSigma,
                offsetSigmaDB * offsetSigmaDB, headingSigma * headingSigma,
            ),
        ),
    )

    /** x, z (meters), receiver offset (dB), heading offset (radians). A snapshot copy. */
    val state: List<Double> get() = s.toList()
    /** A snapshot copy of the covariance. */
    val covariance: List<List<Double>> get() = p.map { it.toList() }

    val x: Double get() = s[0]
    val z: Double get() = s[1]
    val receiverOffsetDB: Double get() = s[2]
    /** Added to the dead-reckoning heading to get the frame heading. */
    val headingOffset: Double get() = s[3]
    /** One-sigma radial position error, meters. */
    val accuracy: Double get() = sqrt(max(0.0, p[0][0] + p[1][1]))
    /**
     * Radius holding the position 95 % of the time, what `accuracyMeters` means on the wire:
     * 2.4477 per-axis sigmas, and `accuracy` is √2 per-axis sigmas.
     */
    val r95: Double get() = accuracy * SignalMap.r95PerSigma / sqrt(2.0)
    val receiverOffsetSigmaDB: Double get() = sqrt(max(0.0, p[2][2]))
    val headingOffsetSigma: Double get() = sqrt(max(0.0, p[3][3]))

    /** An independent copy, as Swift's value semantics would give. */
    fun copy(): PositionFilter = PositionFilter(s.copyOf(), Array(size) { p[it].copyOf() })

    /** Restarts the position; the learned offsets are kept. */
    fun reset(x: Double, z: Double, positionSigma: Double) {
        s[0] = x
        s[1] = z
        for (i in 0 until size) {
            for (j in 0 until 2) {
                p[i][j] = 0.0
                p[j][i] = 0.0
            }
        }
        p[0][0] = positionSigma * positionSigma
        p[1][1] = positionSigma * positionSigma
    }

    /** Restarts the heading offset, after the user re-aligned the heading with the frame. */
    fun resetHeading(sigma: Double) {
        s[3] = 0.0
        for (i in 0 until size) {
            p[i][3] = 0.0
            p[3][i] = 0.0
        }
        p[3][3] = sigma * sigma
    }

    /**
     * Moves by a step of `length` meters at dead-reckoning `heading`. Stride error runs along the
     * step, per-step heading noise across it, and `headingDrift` (radians) is gyro drift per step.
     */
    fun predict(length: Double, heading: Double, alongSigma: Double, crossSigma: Double, headingDrift: Double) {
        val theta = heading + s[3]
        val dx = length * sin(theta)
        val dz = length * cos(theta)
        s[0] += dx
        s[1] += dz

        // P = F P Fᵀ, where F is the identity except for the step's dependence on the heading offset.
        val f = Array(size) { i -> DoubleArray(size) { j -> if (i == j) 1.0 else 0.0 } }
        f[0][3] = dz
        f[1][3] = -dx
        val fp = Array(size) { i ->
            DoubleArray(size) { j ->
                var sum = 0.0
                for (k in 0 until size) sum += f[i][k] * p[k][j]
                sum
            }
        }
        val fpf = Array(size) { i ->
            DoubleArray(size) { j ->
                var sum = 0.0
                for (k in 0 until size) sum += fp[i][k] * f[j][k]
                sum
            }
        }
        for (i in 0 until size) fpf[i].copyInto(p[i])

        val ux = sin(theta)
        val uz = cos(theta)
        val along = alongSigma * alongSigma
        val cross = crossSigma * crossSigma
        // Q = R · diag(along, cross) · Rᵀ with R = [[ux, uz], [uz, -ux]].
        p[0][0] += along * ux * ux + cross * uz * uz
        p[1][1] += along * uz * uz + cross * ux * ux
        p[0][1] += (along - cross) * ux * uz
        p[1][0] += (along - cross) * ux * uz
        p[3][3] += headingDrift * headingDrift
    }

    /** Random-walk noise for movement the step detector misses and slow radio drift. */
    fun addProcessNoise(seconds: Double, positionVariancePerSecond: Double, offsetVariancePerSecond: Double) {
        val dt = max(0.0, seconds)
        p[0][0] += positionVariancePerSecond * dt
        p[1][1] += positionVariancePerSecond * dt
        p[2][2] += offsetVariancePerSecond * dt
    }

    /** The range from this phone to an anchor, including the height difference. */
    fun distance(anchorX: Double, anchorZ: Double, verticalOffset: Double): Double {
        val dx = s[0] - anchorX
        val dz = s[1] - anchorZ
        return sqrt(dx * dx + dz * dz + verticalOffset * verticalOffset)
    }

    /**
     * Corrects with one anchor's RSSI. `rssi` must already exclude the anchor's own radio offset.
     * `gate` is the largest accepted squared innovation in standard deviations.
     */
    fun update(
        rssi: Double,
        sigmaDB: Double,
        anchorX: Double,
        anchorZ: Double,
        verticalOffset: Double,
        anchorSigma: Double,
        model: PathLossModel,
        gate: Double = 9.0,
    ): UpdateResult {
        val dx = s[0] - anchorX
        val dz = s[1] - anchorZ
        val horizontal = sqrt(dx * dx + dz * dz)
        // The bearing to an anchor is undefined on top of it.
        if (!(horizontal > 0.05 && rssi.isFinite())) return UpdateResult.skipped
        val distance = sqrt(horizontal * horizontal + verticalOffset * verticalOffset)
        val predicted = model.predictedRSSI(distance) + s[2]
        // d rssi / d x = -(10 n / ln 10) · dx / d²; flat inside the model's minimum distance.
        val slope = if (distance > PathLossModel.minDistance) -model.dBPerLogDistance / (distance * distance) else 0.0
        val h = doubleArrayOf(slope * dx, slope * dz, 1.0, 0.0)
        val anchorDB = model.dBPerLogDistance * anchorSigma / max(distance, PathLossModel.minDistance)
        val noise = sigmaDB * sigmaDB + anchorDB * anchorDB

        val ph = DoubleArray(size) { i ->
            var sum = 0.0
            for (k in 0 until size) sum += p[i][k] * h[k]
            sum
        }
        var hph = 0.0
        for (k in 0 until size) hph += h[k] * ph[k]
        val sValue = hph + noise
        val innovation = rssi - predicted
        if (!(sValue > 0 && innovation * innovation / sValue <= gate)) return UpdateResult.rejected
        apply(ph, sValue, innovation)
        return UpdateResult.accepted
    }

    /** Corrects with a known position, for example standing next to an anchor. */
    fun observePosition(x: Double, z: Double, sigma: Double) {
        val noise = sigma * sigma
        for ((axis, target) in listOf(Pair(0, x), Pair(1, z))) {
            val ph = DoubleArray(size) { p[it][axis] }
            apply(ph, p[axis][axis] + noise, target - s[axis])
        }
    }

    private fun apply(ph: DoubleArray, sValue: Double, innovation: Double) {
        val gain = DoubleArray(size) { ph[it] / sValue }
        for (i in 0 until size) s[i] += gain[i] * innovation
        s[3] = normalizedAngle(s[3])
        for (i in 0 until size) {
            for (j in 0 until size) p[i][j] -= gain[i] * ph[j]
        }
        // Keep the covariance symmetric despite rounding.
        for (i in 0 until size) {
            for (j in i + 1 until size) {
                val mean = (p[i][j] + p[j][i]) / 2
                p[i][j] = mean
                p[j][i] = mean
            }
        }
    }

    companion object {
        internal const val size = 4

        private fun diagonal(variances: DoubleArray): Array<DoubleArray> =
            Array(size) { i -> DoubleArray(size) { j -> if (i == j) variances[i] else 0.0 } }
    }
}
