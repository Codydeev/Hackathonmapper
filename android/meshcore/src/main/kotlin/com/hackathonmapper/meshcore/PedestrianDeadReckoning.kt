package com.hackathonmapper.meshcore

import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * One device-motion sample in device coordinates, in Core Motion's convention: `gravity` and
 * `userAcceleration` in g, `rotationRate` in rad/s (bias corrected). `time` is seconds on a
 * monotonic clock. Android sensor values must be converted first (see PORTING.md, "Sensors").
 */
data class MotionSample(
    val time: TimeInterval,
    val gravity: Vector3,
    val userAcceleration: Vector3,
    val rotationRate: Vector3,
)

data class Step(
    val time: TimeInterval,
    val length: Double,
    /** Frame heading in radians: 0 faces +z, positive turns toward +x (clockwise seen from above). */
    val heading: Double,
) {
    /** Displacement in the frame's floor plane. */
    val dx: Double get() = length * sin(heading)
    val dz: Double get() = length * cos(heading)
}

/**
 * Pedestrian dead reckoning from device motion. Steps are peaks of the vertical acceleration,
 * stride length follows their swing (Weinberg), and heading integrates the gyro rate about
 * gravity, so it works whether the phone is held flat or upright. Heading is relative: align it
 * with the frame once (`alignHeading`); it drifts slowly after that and must never be presented
 * as a measured position on its own.
 *
 * A Swift struct with mutating methods: use `copy()` where Swift would copy the value.
 */
class PedestrianDeadReckoning(var configuration: Configuration = Configuration()) {
    data class Configuration(
        /** Weinberg constant: stride = K · (peak-to-peak vertical acceleration in m/s²)^¼. */
        var strideConstant: Double = 0.47,
        var strideRange: ClosedFloatingPointRange<Double> = 0.25..1.2,
        /** Minimum filtered vertical acceleration of a step peak, m/s². */
        var peakThreshold: Double = 1.2,
        var minStepInterval: TimeInterval = 0.28,
        /** A longer pause ends a walk; the next peak starts a new one. */
        var maxStepInterval: TimeInterval = 2.0,
        var smoothingCutoffHz: Double = 3.0,
    )

    var heading: Double = 0.0
        private set
    var stepCount = 0
        private set
    var lastStep: Step? = null
        private set
    private var lastStepInterval: TimeInterval? = null
    private var lastSampleTime: TimeInterval? = null
    private var filtered = 0.0
    private var previous = 0.0
    private var rising = false
    private var swingMin = 0.0
    private var swingMax = 0.0
    private var headingSin = 0.0
    private var headingCos = 0.0

    /** An independent copy, as Swift's value semantics would give. */
    fun copy(): PedestrianDeadReckoning {
        val other = PedestrianDeadReckoning(configuration.copy())
        other.heading = heading
        other.stepCount = stepCount
        other.lastStep = lastStep
        other.lastStepInterval = lastStepInterval
        other.lastSampleTime = lastSampleTime
        other.filtered = filtered
        other.previous = previous
        other.rising = rising
        other.swingMin = swingMin
        other.swingMax = swingMax
        other.headingSin = headingSin
        other.headingCos = headingCos
        return other
    }

    /** Sets the current frame heading, for example 0 while the user faces +z. */
    fun alignHeading(value: Double) {
        heading = normalizedAngle(value)
        headingSin = 0.0
        headingCos = 0.0
    }

    fun isWalking(time: TimeInterval): Boolean {
        val lastStep = lastStep ?: return false
        return time - lastStep.time <= configuration.maxStepInterval
    }

    /** Walking speed from the latest step; 0 once the phone stops stepping. */
    fun speed(time: TimeInterval): Double {
        val lastStep = lastStep
        val lastStepInterval = lastStepInterval
        if (!isWalking(time) || lastStep == null || lastStepInterval == null) return 0.0
        return lastStep.length / max(lastStepInterval, configuration.minStepInterval)
    }

    /** Feeds one sample; returns a step when one completes. */
    fun process(sample: MotionSample): Step? {
        val gravityLength = sample.gravity.length
        if (!(gravityLength > 0.1)) return null
        val down = sample.gravity.scaled(1 / gravityLength)
        val vertical = -sample.userAcceleration.dot(down) * standardGravity

        val last = lastSampleTime
        if (last == null || !(sample.time - last > 0) || !(sample.time - last < 0.5)) {
            // First sample or a gap in the feed: restart the filters without integrating across it.
            lastSampleTime = sample.time
            filtered = vertical
            previous = vertical
            rising = false
            swingMin = vertical
            swingMax = vertical
            return null
        }
        val dt = sample.time - last
        lastSampleTime = sample.time

        // The rotation rate about "up" is counterclockwise seen from above; heading turns clockwise.
        heading = normalizedAngle(heading + sample.rotationRate.dot(down) * dt)
        headingSin += sin(heading)
        headingCos += cos(heading)

        val alpha = 1 - exp(-2 * Math.PI * configuration.smoothingCutoffHz * dt)
        filtered += alpha * (vertical - filtered)
        swingMin = min(swingMin, filtered)
        swingMax = max(swingMax, filtered)
        // Swift: `defer { previous = filtered }`.
        try {
            // A step is a local maximum of the filtered vertical acceleration above the threshold.
            val wasRising = rising
            rising = filtered > previous
            if (!(wasRising && !rising && previous >= configuration.peakThreshold)) return null
            val interval = lastStep?.let { sample.time - it.time } ?: Double.POSITIVE_INFINITY
            if (!(interval >= configuration.minStepInterval)) return null

            val swing = max(0.0, swingMax - swingMin)
            val range = configuration.strideRange
            val length = min(range.endInclusive, max(range.start, configuration.strideConstant * swing.pow(0.25)))
            val stepHeading = if (headingSin == 0.0 && headingCos == 0.0) heading else atan2(headingSin, headingCos)
            val step = Step(time = sample.time, length = length, heading = stepHeading)
            lastStepInterval = if (interval <= configuration.maxStepInterval) interval else null
            lastStep = step
            stepCount += 1
            swingMin = filtered
            swingMax = filtered
            headingSin = 0.0
            headingCos = 0.0
            return step
        } finally {
            previous = filtered
        }
    }

    companion object {
        const val standardGravity = 9.80665
    }
}
