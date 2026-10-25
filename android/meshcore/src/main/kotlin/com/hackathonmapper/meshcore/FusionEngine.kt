package com.hackathonmapper.meshcore

import kotlin.math.max
import kotlin.math.sqrt

/** The latest raw RSSI sample of an anchor this phone hears directly. */
data class AnchorSighting(
    val anchorId: String,
    val position: Position,
    /** The anchor's own reported accuracy; null means unknown. */
    val positionAccuracy: Double?,
    val rssi: Double,
    /** When the sample was taken, on the same monotonic clock as the motion samples. */
    val sampleTime: TimeInterval,
)

/** How one anchor's BLE range looks before and after motion filtering. */
data class AnchorRange(
    val anchorId: String,
    /** Range read from the motion-filtered RSSI alone, meters. */
    val rssiDistance: Double,
    /** Range from the fused position, meters; null while not tracking. */
    val fusedDistance: Double?,
    /** Remaining RSSI spread after motion filtering, dB. */
    val sigmaDB: Double,
    /** Samples averaged since the phone stopped; 0 while walking. */
    val stillSamples: Int,
    /** Samples dropped as jumps the walked distance cannot explain. */
    val droppedSamples: Int,
    val lastResult: PositionFilter.UpdateResult?,
)

/**
 * Fuses pedestrian dead reckoning (smooth, but drifts) with BLE RSSI to anchors (bounded, but
 * noisy). Motion data limits the BLE range errors in four ways: it averages RSSI while the phone
 * stands still, drops samples implying a range change the steps cannot explain, accounts for
 * smoothing lag while walking, and spaces filter updates so correlated shadowing isn't counted
 * twice. In turn the anchors bound the dead-reckoning drift, including slow gyro heading drift.
 * Each phone's radio offset is estimated, and anchors' offsets come from `calibration`.
 *
 * A Swift struct with mutating methods: use `copy()` where Swift would copy the value. The
 * `deadReckoning` and `filter` getters return the engine's own objects; treat them as read-only.
 */
class FusionEngine() {
    private class AnchorTrack(walkedAtSample: Double) {
        var rssi = MotionAwareRSSI()
        var walkedAtSample: Double = walkedAtSample
        var walkedAtFeed: Double? = null
        var fedStillCount = 0
        var lastResult: PositionFilter.UpdateResult? = null

        fun copy(): AnchorTrack {
            val other = AnchorTrack(walkedAtSample)
            other.rssi = rssi.copy()
            other.walkedAtFeed = walkedAtFeed
            other.fedStillCount = fedStillCount
            other.lastResult = lastResult
            return other
        }
    }

    var deadReckoning = PedestrianDeadReckoning()
        private set
    var filter: PositionFilter? = null
        private set
    var calibration = PathLossCalibration.uncalibrated
        private set
    /** RSSI-only fix; shown separately, never published as a measurement. */
    var lastFix: RangeFix? = null
        private set
    var ranges: List<AnchorRange> = emptyList()
        private set
    var acceptedUpdates = 0
        private set
    var rejectedUpdates = 0
        private set
    var recoveries = 0
        private set
    var walkedDistance = 0.0
        private set
    /** This phone's height in the frame, for the vertical part of anchor ranges. */
    var ownHeight = 0.0
    private var receiverOffsetDB = 0.0
    private var lastStep: Step? = null
    private var lastStepInterval: TimeInterval? = null
    private var tracks: Map<String, AnchorTrack> = emptyMap()
    private var lastUpdateTime: TimeInterval? = null
    private var rejectedEpochs = 0

    /** An independent deep copy, as Swift's value semantics would give. */
    fun copy(): FusionEngine {
        val other = FusionEngine()
        other.deadReckoning = deadReckoning.copy()
        other.filter = filter?.copy()
        other.calibration = calibration
        other.lastFix = lastFix
        other.ranges = ranges
        other.acceptedUpdates = acceptedUpdates
        other.rejectedUpdates = rejectedUpdates
        other.recoveries = recoveries
        other.walkedDistance = walkedDistance
        other.ownHeight = ownHeight
        other.receiverOffsetDB = receiverOffsetDB
        other.lastStep = lastStep
        other.lastStepInterval = lastStepInterval
        other.tracks = tracks.mapValues { it.value.copy() }
        other.lastUpdateTime = lastUpdateTime
        other.rejectedEpochs = rejectedEpochs
        return other
    }

    val isTracking: Boolean get() = filter != null

    /** Starts tracking at a known point, facing `heading` (0 faces +z). */
    fun start(x: Double, z: Double, heading: Double, positionSigma: Double = 0.5) {
        deadReckoning.alignHeading(heading)
        filter = PositionFilter(
            x = x, z = z, positionSigma = positionSigma, receiverOffsetDB = receiverOffsetDB,
            headingSigma = alignedHeadingSigma,
        )
        rejectedEpochs = 0
    }

    /** Frame heading of the last step direction: dead reckoning plus the estimated offset. */
    val heading: Double get() = normalizedAngle(deadReckoning.heading + (filter?.headingOffset ?: 0.0))

    /** Starts tracking at the RSSI-only fix; false if there is none. */
    fun startFromFix(heading: Double): Boolean {
        val lastFix = lastFix ?: return false
        start(x = lastFix.x, z = lastFix.z, heading = heading, positionSigma = max(lastFix.accuracy, 1.5))
        return true
    }

    fun alignHeading(heading: Double) {
        deadReckoning.alignHeading(heading)
        filter?.resetHeading(sigma = alignedHeadingSigma)
    }

    fun stop() {
        filter?.let { receiverOffsetDB = it.receiverOffsetDB }
        filter = null
    }

    /** Corrects with a known position, such as standing next to an anchor. */
    fun observePosition(x: Double, z: Double, sigma: Double) {
        filter?.observePosition(x = x, z = z, sigma = sigma)
        rejectedEpochs = 0
    }

    fun setCalibration(calibration: PathLossCalibration) {
        this.calibration = calibration
    }

    fun isWalking(time: TimeInterval): Boolean {
        val lastStep = lastStep ?: return false
        return time - lastStep.time <= walkingTimeout
    }

    fun speed(time: TimeInterval): Double {
        val lastStep = lastStep
        val lastStepInterval = lastStepInterval
        if (!isWalking(time) || lastStep == null || lastStepInterval == null) return 0.0
        return lastStep.length / max(lastStepInterval, 0.3)
    }

    /** Feeds a motion sample; returns the step it completed, if any. */
    fun process(sample: MotionSample): Step? {
        val step = deadReckoning.process(sample) ?: return null
        apply(step)
        return step
    }

    /** Moves the estimate by a step. */
    fun apply(step: Step) {
        val lastStep = lastStep
        if (lastStep != null) {
            val interval = step.time - lastStep.time
            lastStepInterval = if (interval <= walkingTimeout) interval else null
        }
        this.lastStep = step
        walkedDistance += step.length
        filter?.predict(
            length = step.length, heading = step.heading, alongSigma = 0.05 + 0.1 * step.length,
            crossSigma = step.length * headingSigmaPerStep, headingDrift = headingDriftPerStep,
        )
    }

    /** Feeds the latest RSSI sample of every anchor heard directly; call about once per second. */
    fun update(sightings: List<AnchorSighting>, time: TimeInterval) {
        val elapsed = lastUpdateTime?.let { max(0.0, time - it) } ?: 0.0
        lastUpdateTime = time
        val walking = isWalking(time)
        filter?.addProcessNoise(
            seconds = elapsed, positionVariancePerSecond = if (walking) 0.02 else 0.005,
            offsetVariancePerSecond = 0.01,
        )

        val model = calibration.model
        val currentSpeed = speed(time)
        val heard = sightings.map { it.anchorId }.toSet()
        val tracks = HashMap(this.tracks.filter { heard.contains(it.key) })
        val inputs = mutableListOf<RangeInput>()
        val newRanges = mutableListOf<AnchorRange>()
        var accepted = 0
        var rejected = 0

        // Strongest first: near anchors constrain the position best. (Stable, like Swift's sort.)
        for (sighting in sightings.sortedByDescending { it.rssi }) {
            val id = sighting.anchorId
            val anchorOffset = calibration.linkOffset(id)
            val receiverOffset = filter?.receiverOffsetDB ?: receiverOffsetDB
            val vertical = sighting.position.y - ownHeight
            val current = filter?.distance(anchorX = sighting.position.x, anchorZ = sighting.position.z, verticalOffset = vertical)
                ?: model.distance(sighting.rssi - anchorOffset - receiverOffset)

            // Swift copies the struct out of the dictionary and stores it back on every path.
            val track = tracks[id]?.copy() ?: AnchorTrack(walkedAtSample = walkedDistance)
            if (sighting.sampleTime > (track.rssi.lastSampleTime ?: Double.NEGATIVE_INFINITY)) {
                track.rssi.record(
                    rssi = sighting.rssi, time = sighting.sampleTime, moving = isWalking(sighting.sampleTime),
                    walked = walkedDistance - track.walkedAtSample, distance = current, model = model,
                )
                track.walkedAtSample = walkedDistance
            }
            val estimate = track.rssi.estimate(time = time, speed = currentSpeed, distance = current, model = model)
            if (estimate == null) {
                tracks[id] = track
                continue
            }
            val corrected = estimate.rssi - anchorOffset
            val sigmaDB = max(estimate.sigmaDB, minUpdateSigmaDB)
            val anchorSigma = sighting.positionAccuracy ?: defaultAnchorSigma

            // Shadowing stays correlated until the phone moves a meter or two. Feeding the same
            // averaged value every second would count it as new evidence, so while still feed
            // again only each time the number of averaged samples doubles.
            val still = track.rssi.stillSampleCount
            val due: Boolean
            if (still > 0) {
                due = still >= max(1, track.fedStillCount * 2)
                if (due) track.fedStillCount = still
            } else {
                due = track.walkedAtFeed?.let { walkedDistance - it >= decorrelationDistance } ?: true
                track.fedStillCount = 0
            }
            val currentFilter = filter
            if (due && currentFilter != null) {
                val result = currentFilter.update(
                    rssi = corrected, sigmaDB = sigmaDB, anchorX = sighting.position.x,
                    anchorZ = sighting.position.z, verticalOffset = vertical,
                    anchorSigma = anchorSigma, model = model,
                )
                track.lastResult = result
                track.walkedAtFeed = walkedDistance
                if (result == PositionFilter.UpdateResult.accepted) accepted += 1
                if (result == PositionFilter.UpdateResult.rejected) rejected += 1
            }
            tracks[id] = track

            val anchorDB = model.dBPerLogDistance * anchorSigma / max(current, PathLossModel.minDistance)
            inputs.add(
                RangeInput(
                    anchorX = sighting.position.x, anchorZ = sighting.position.z, verticalOffset = vertical,
                    rssi = corrected - receiverOffset,
                    sigmaDB = sqrt(sigmaDB * sigmaDB + anchorDB * anchorDB),
                ),
            )
            newRanges.add(
                AnchorRange(
                    anchorId = id,
                    rssiDistance = model.distance(corrected - receiverOffset),
                    fusedDistance = filter?.distance(anchorX = sighting.position.x, anchorZ = sighting.position.z, verticalOffset = vertical),
                    sigmaDB = estimate.sigmaDB,
                    stillSamples = still,
                    droppedSamples = track.rssi.droppedSamples,
                    lastResult = track.lastResult,
                ),
            )
        }
        this.tracks = tracks

        ranges = newRanges
        acceptedUpdates += accepted
        rejectedUpdates += rejected
        lastFix = RangeSolver.solve(inputs, model = model)

        if (filter == null) return
        if (accepted > 0) {
            rejectedEpochs = 0
        } else if (rejected >= 2) {
            rejectedEpochs += 1
        }
        // Every anchor has disagreed for several seconds: the estimate has drifted away
        // (for example a missed turn). Restart at the RSSI fix, keeping the radio offset.
        val fix = lastFix
        if (rejectedEpochs >= recoveryEpochs && fix != null) {
            filter?.reset(x = fix.x, z = fix.z, positionSigma = max(fix.accuracy, 1.5))
            recoveries += 1
            rejectedEpochs = 0
        }
    }

    companion object {
        /** Assumed accuracy of an anchor's position when it reports none, meters. */
        const val defaultAnchorSigma = 0.5
        /** Random heading error per step, radians. */
        const val headingSigmaPerStep = 0.08
        /** Gyro heading drift per step, radians. */
        const val headingDriftPerStep = 0.03
        /** Heading uncertainty right after the user aligned with the frame, radians. */
        const val alignedHeadingSigma = 0.2
        /** Shadowing decorrelates over roughly this much movement, meters. */
        const val decorrelationDistance = 2.0
        /**
         * Least RSSI spread trusted in one update, dB: static shadowing and path-loss model error are
         * biases that averaging does not remove. Lower values made simulated walks overconfident.
         */
        const val minUpdateSigmaDB = 8.0
        /** Seconds in a row in which every anchor disagrees before restarting at the RSSI fix. */
        const val recoveryEpochs = 5
        const val walkingTimeout: TimeInterval = 2.0
    }
}
