package com.hackathonmapper.meshcore

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

/**
 * Log-distance path loss: `rssi = referenceRSSI - 10·n·log10(d / 1 m)` plus device offsets.
 * Indoors the spread around it (`sigmaDB`) is several dB, so a single RSSI value is a rough
 * range at best; the estimator only uses it together with motion.
 * Immutable (Swift value type): change a field with `copy(...)`.
 */
data class PathLossModel(
    /** Median RSSI at 1 m, dBm. */
    val referenceRSSI: Double,
    val exponent: Double,
    /** Shadowing and multipath spread around the model, dB (log-normal fading). */
    val sigmaDB: Double,
) {
    fun predictedRSSI(distance: Double): Double = referenceRSSI - 10 * exponent * log10(max(distance, minDistance))

    /** Median distance for an RSSI value, meters. */
    fun distance(rssi: Double): Double = max(minDistance, 10.0.pow((referenceRSSI - rssi) / (10 * exponent)))

    /** dB per unit of ln(distance): an RSSI error of `e` dB scales distance by exp(e / dBPerLog). */
    val dBPerLogDistance: Double get() = 10 * exponent / ln(10.0)

    companion object {
        /** The shared radio model (`RadioModel.standard`), so fusion and the signal map read RSSI alike. */
        val default = PathLossModel(
            referenceRSSI = RadioModel.standard.p0, exponent = RadioModel.standard.n,
            sigmaDB = RadioModel.standard.sigma,
        )
        /** Closer than this the model is meaningless (near field, antenna pattern). */
        const val minDistance = 0.5
    }
}

/** RSSI an anchor reported for its direct link to another anchor; both positions are known. */
data class AnchorLinkObservation(
    val observer: String,
    val target: String,
    val distance: Double,
    val rssi: Double,
)

/**
 * The room's path-loss model plus a per-device radio offset, fitted from anchor-to-anchor links
 * whose true distances are known. Phone models, cases and grips differ by several dB; a link
 * a→b sees about half of each end's combined TX+RX offset, `rssi_ab ≈ model(d) + (o_a + o_b) / 2`.
 * Priors keep the fit sane with few links: offsets shrink toward 0 dB and the model toward
 * `PathLossModel.default`.
 * Immutable (Swift value type): change a field with `copy(...)`.
 */
data class PathLossCalibration(
    val model: PathLossModel,
    val deviceOffsets: Map<String, Double>,
    val linkCount: Int,
) {
    /** The part of every link RSSI contributed by this device's radio (half its offset), dB. */
    fun linkOffset(id: String): Double = (deviceOffsets[id] ?: 0.0) / 2

    companion object {
        val uncalibrated = PathLossCalibration(model = PathLossModel.default, deviceOffsets = emptyMap(), linkCount = 0)

        fun fit(
            links: List<AnchorLinkObservation>,
            prior: PathLossModel = PathLossModel.default,
            referenceSigmaDB: Double = 6.0,
            exponentSigma: Double = 0.6,
            offsetSigmaDB: Double = 4.0,
        ): PathLossCalibration {
            val usable = links.filter {
                it.observer != it.target && it.distance >= PathLossModel.minDistance && it.distance.isFinite() &&
                    it.rssi >= -127.0 && it.rssi <= 20.0
            }
            if (usable.isEmpty()) return PathLossCalibration(model = prior, deviceOffsets = emptyMap(), linkCount = 0)

            // Unknowns: referenceRSSI, exponent, then one offset per device. Ridge priors make the
            // normal equations well posed even when offsets and the reference level are confounded.
            val devices = usable.flatMap { listOf(it.observer, it.target) }.toSet().sorted()
            val index = HashMap<String, Int>()
            for ((i, device) in devices.withIndex()) index[device] = i + 2
            val count = devices.size + 2
            val normal = Array(count) { DoubleArray(count) }
            val rhs = DoubleArray(count)
            val weight = 1 / (prior.sigmaDB * prior.sigmaDB)

            for (link in usable) {
                val row = DoubleArray(count)
                row[0] = 1.0
                row[1] = -10 * log10(link.distance)
                row[index[link.observer]!!] += 0.5
                row[index[link.target]!!] += 0.5
                for (i in 0 until count) {
                    if (row[i] == 0.0) continue
                    for (j in 0 until count) {
                        if (row[j] == 0.0) continue
                        normal[i][j] += weight * row[i] * row[j]
                    }
                    rhs[i] += weight * row[i] * link.rssi
                }
            }
            val priorWeights = listOf(1 / (referenceSigmaDB * referenceSigmaDB), 1 / (exponentSigma * exponentSigma)) +
                List(devices.size) { 1 / (offsetSigmaDB * offsetSigmaDB) }
            val priorMeans = listOf(prior.referenceRSSI, prior.exponent) + List(devices.size) { 0.0 }
            for (i in 0 until count) {
                normal[i][i] += priorWeights[i]
                rhs[i] += priorWeights[i] * priorMeans[i]
            }
            val solution = solveLinearSystem(normal.map { it.toList() }, rhs.toList())
                ?: return PathLossCalibration(model = prior, deviceOffsets = emptyMap(), linkCount = 0)

            var model = PathLossModel(
                referenceRSSI = min(-20.0, max(-100.0, solution[0])),
                exponent = min(5.0, max(1.5, solution[1])),
                sigmaDB = prior.sigmaDB,
            )
            val offsets = HashMap<String, Double>()
            for (device in devices) offsets[device] = solution[index[device]!!]
            // With enough links the residual spread replaces the assumed one; never below 3 dB.
            if (usable.size >= 6) {
                val squares = usable.map { link ->
                    val predicted = model.predictedRSSI(link.distance) +
                        (offsets[link.observer]!! + offsets[link.target]!!) / 2
                    (link.rssi - predicted) * (link.rssi - predicted)
                }
                val rms = sqrt(squares.fold(0.0) { sum, value -> sum + value } / usable.size.toDouble())
                model = model.copy(sigmaDB = min(12.0, max(3.0, rms)))
            }
            return PathLossCalibration(model = model, deviceOffsets = offsets, linkCount = usable.size)
        }
    }
}

/**
 * Per-anchor RSSI smoothing driven by the accelerometer, which bounds how much the range to an
 * anchor can really have changed:
 * - Standing still, every sample since the phone stopped is averaged, so fast fading averages
 *   out (down to `staticFloorDB`, shadowing that does not change without movement).
 * - A sample that jumps further than the walked distance can explain is fading or a body in
 *   the way, and is dropped, unless `maxConsecutiveOutliers` in a row agree (the room changed).
 * - Walking, a short window keeps the lag small and the remaining lag is reported as
 *   extra uncertainty.
 *
 * A Swift struct with mutating methods: use `copy()` where Swift would copy the value.
 */
class MotionAwareRSSI() {
    /** Smoothed RSSI and its spread (Swift returns the tuple `(rssi:, sigmaDB:)`). */
    data class Estimate(val rssi: Double, val sigmaDB: Double)

    var value: Double? = null
        private set
    var lastSampleTime: TimeInterval? = null
        private set
    var droppedSamples = 0
        private set
    private var stillSum = 0.0
    private var stillCount = 0
    private var consecutiveOutliers = 0

    /** Samples averaged since the phone stopped; 0 while walking. */
    val stillSampleCount: Int get() = stillCount

    /** An independent copy, as Swift's value semantics would give. */
    fun copy(): MotionAwareRSSI {
        val other = MotionAwareRSSI()
        other.value = value
        other.lastSampleTime = lastSampleTime
        other.droppedSamples = droppedSamples
        other.stillSum = stillSum
        other.stillCount = stillCount
        other.consecutiveOutliers = consecutiveOutliers
        return other
    }

    /**
     * Records a sample taken at `time`; repeated calls with the same sample are ignored.
     * `walked` is the distance stepped since the previous sample, `distance` the current range
     * estimate. Returns false if the sample was dropped as an outlier.
     */
    fun record(
        rssi: Double,
        time: TimeInterval,
        moving: Boolean,
        walked: Double = 0.0,
        distance: Double = 1.0,
        model: PathLossModel = PathLossModel.default,
    ): Boolean {
        if (!(rssi.isFinite() && time > (lastSampleTime ?: Double.NEGATIVE_INFINITY))) return false
        val current = value
        if (current != null && abs(rssi - current) > allowedChange(walked, distance, model)) {
            consecutiveOutliers += 1
            if (consecutiveOutliers < maxConsecutiveOutliers) {
                droppedSamples += 1
                lastSampleTime = time
                return false
            }
            // The environment changed for good: start over from the new level.
            value = null
            stillSum = 0.0
            stillCount = 0
        }
        consecutiveOutliers = 0
        if (moving) {
            stillSum = 0.0
            stillCount = 0
            val previousValue = value
            val previousTime = lastSampleTime
            if (previousValue != null && previousTime != null) {
                val alpha = 1 - exp(-(time - previousTime) / walkingTimeConstant)
                value = previousValue + alpha * (rssi - previousValue)
            } else {
                value = rssi
            }
        } else {
            stillSum += rssi
            stillCount += 1
            value = stillSum / stillCount.toDouble()
        }
        lastSampleTime = time
        return true
    }

    /** Smoothed RSSI and its spread, or null when there is no recent sample. */
    fun estimate(time: TimeInterval, speed: Double, distance: Double, model: PathLossModel): Estimate? {
        val value = value ?: return null
        val lastSampleTime = lastSampleTime ?: return null
        if (!(time - lastSampleTime <= maxSampleAge)) return null
        if (stillCount > 0) {
            val averaged = sampleSigmaDB / sqrt(stillCount.toDouble())
            val floor = min(staticFloorDB, model.sigmaDB)
            return Estimate(value, sqrt(averaged * averaged + floor * floor))
        }
        // The smoothed value trails a walking phone by about one time constant of travel.
        val lag = speed * walkingTimeConstant + speed * (time - lastSampleTime)
        val lagDB = model.dBPerLogDistance * lag / max(distance, 1.0)
        return Estimate(value, sqrt(model.sigmaDB * model.sigmaDB + lagDB * lagDB))
    }

    companion object {
        /** Smoothing time constant while walking, seconds. */
        const val walkingTimeConstant: TimeInterval = 1.5
        /** Shadowing that averaging cannot remove while standing still, dB. */
        const val staticFloorDB = 4.0
        /** Typical spread of single samples, dB. */
        const val sampleSigmaDB = 5.0
        /** Samples older than this are not a current measurement. */
        const val maxSampleAge: TimeInterval = 5.0
        const val maxConsecutiveOutliers = 3

        /**
         * Largest RSSI change, dB, that `walked` meters of movement plus sample noise can explain
         * at about `distance` meters from the anchor.
         */
        fun allowedChange(walked: Double, distance: Double, model: PathLossModel): Double {
            val near = max(distance - walked, PathLossModel.minDistance)
            val far = max(distance + walked, near)
            return 2.5 * sampleSigmaDB + model.dBPerLogDistance * ln(far / near)
        }
    }
}
