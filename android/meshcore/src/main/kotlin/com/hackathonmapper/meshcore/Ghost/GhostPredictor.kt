package com.hackathonmapper.meshcore

import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Ghost Mode behind the GhostCore contract: position estimates and this phone's motion in,
 * `Prediction` records out. A thin layer over `GhostTracker`, which does the work.
 *
 * - Estimates that are themselves predictions (`kind == .predicted`) are never taken in, so a
 *   prediction cannot confirm itself; nor are `.unavailable` ones or other frames.
 * - `.deadReckoning` estimates are skipped too: Ghost Mode does its own dead reckoning from
 *   `MotionObservation`, and taking both would count the same steps twice.
 * - `predict` returns null while the subject is live (a fresh estimate supersedes the prediction
 *   at once) and after `maxHorizon` (only the last observation is shown then).
 */
class GhostPredictor(
    val producerId: String,
    val frameId: String = GeoFrame.defaultFrameId,
    config: GhostTracker.Config = GhostTracker.Config(),
) : GhostPredictionEngine {
    val tracker: GhostTracker = GhostTracker(config)

    /** How long a published prediction may be used before a newer one replaces it, seconds. */
    var predictionMaxAge: Double = 10.0

    /** Points in `Prediction.cloud` (the contract allows 128). */
    var cloudPoints: Int = 64

    /**
     * A learned model's area, supplied by the app (the movement model lives in the app target):
     * called with the subject's track (oldest first, this phone's clock, x east / z north) and the
     * seconds since its last observation. Used once the track covers `learnedMinHistory`; null (or
     * a shorter track) falls back to the Kalman filter. Status, last observed and recovery stay
     * Ghost Mode's either way.
     */
    var learnedArea: ((track: List<GhostObservation>, horizon: Double) -> GhostLearnedArea?)? = null

    /** Held-out: the movement model without the map beat the Kalman filter with 60 s of history. */
    var learnedMinHistory: Double = 60.0

    /**
     * Folds in an estimate received at local time `receivedAt` (for this phone's own estimates,
     * the time it made them). The same estimate may come again; repeats change nothing.
     */
    override fun observe(estimate: PositionEstimate, receivedAt: Double) {
        ingest(estimate, receivedAt)
    }

    /** `observe`, returning the recovery check when the subject had been out of sight. */
    fun ingest(estimate: PositionEstimate, receivedAt: Double): GhostRecovery? {
        val o = GhostObservation(estimate, receivedAt = receivedAt, frameId = frameId) ?: return null
        return tracker.observe(estimate.subjectId, o)
    }

    /** This phone's own motion sensors. */
    override fun observe(motion: MotionObservation) {
        if (motion.frameId != frameId) return
        tracker.motion(motion.subjectId, GhostMotionHint(motion))
    }

    /**
     * The prediction for local time `now`, or null when there is nothing to predict: unknown,
     * live, or gone longer than `maxHorizon`.
     */
    override fun predict(subjectId: String, now: Double): Prediction? {
        val e = tracker.estimate(subjectId, now) ?: return null
        if (e.status != GhostStatus.ghost) return null
        val belief = e.belief ?: return null
        val r95 = e.r95 ?: return null
        val track = tracker.observations(subjectId)
        val used = track.takeLast(4)
        val inputs = used.mapIndexed { i, o ->
            ProvenanceInput(
                source = o.source.evidence, id = subjectId, age = max(0.0, now - o.t), used = true,
                reason = if (i == used.size - 1) "last observation" else "track",
            )
        }.toMutableList()
        if (e.basis == GhostBasis.deadReckoned) {
            inputs.add(ProvenanceInput(source = EvidenceSource.inertial, id = subjectId, used = true, reason = "steps and heading"))
        }
        val upstream = used.mapNotNull { it.provenance }
        val usesGNSS = used.any { it.source == GhostObservation.Source.gps }
        val provenance = Provenance.derived(
            producerId = producerId, algorithm = algorithm, inputs = inputs,
            from = upstream, usesGNSS = usesGNSS,
        )
        val last = e.lastObserved
        val lastPosition = Position(x = last.x, y = 0.0, z = last.z)
        val learnedArea = learnedArea
        val first = track.firstOrNull()
        if (e.basis != GhostBasis.deadReckoned && learnedArea != null && first != null &&
            last.t - first.t >= learnedMinHistory
        ) {
            val area = learnedArea(track, e.age)
            if (area != null && area.r95.isFinite() && area.r95 > 0) {
                val learned = Provenance.derived(
                    producerId = producerId, algorithm = area.algorithm, inputs = inputs,
                    from = upstream, usesGNSS = usesGNSS,
                )
                return Prediction(
                    subjectId = subjectId, timestamp = now, frameId = frameId, method = Prediction.Method.movementModel,
                    lastObservedAt = last.t, lastObservedPosition = lastPosition,
                    center = Position(x = area.center.x, y = 0.0, z = area.center.z),
                    uncertainty = PositionUncertainty(r95 = min(area.r95, GhostCoreContract.maxRadius)),
                    cloud = area.cloud?.take(GhostCoreContract.maxCloudPoints),
                    freshness = Freshness(maxAge = predictionMaxAge), provenance = learned,
                )
            }
        }
        val c = belief.core
        // Same dots every second of one gap, so the cloud grows instead of flickering.
        val seed = stableHash(subjectId) xor last.t.toRawBits().toULong()
        val cloud = if (cloudPoints > 0) {
            belief.samples(min(cloudPoints, GhostCoreContract.maxCloudPoints), seed).map { FloorVector(x = it.x, z = it.z) }
        } else {
            null
        }
        return Prediction(
            subjectId = subjectId, timestamp = now, frameId = frameId, method = Prediction.Method.kalman,
            lastObservedAt = last.t, lastObservedPosition = lastPosition, center = Position(x = c.x, y = 0.0, z = c.z),
            uncertainty = PositionUncertainty(
                r95 = min(r95, GhostCoreContract.maxRadius),
                covariance = FloorCovariance(xx = c.xx, xz = c.xz, zz = c.zz),
            ),
            cloud = cloud, freshness = Freshness(maxAge = predictionMaxAge), provenance = provenance,
        )
    }

    /** Status, last observation and the belief, for views (see `GhostEstimate.summary`). */
    fun estimate(subjectId: String, now: Double): GhostEstimate? = tracker.estimate(subjectId, now)

    fun forget(subjectId: String) {
        tracker.forget(subjectId)
    }

    companion object {
        const val algorithm = "kalman-ou@1"

        /** FNV-1a: `hashCode` is not stable across platforms (Swift's `hashValue` changes between launches). */
        internal fun stableHash(s: String): ULong {
            var h: ULong = 0xCBF2_9CE4_8422_2325uL
            for (b in s.encodeToByteArray()) h = (h xor b.toUByte().toULong()) * 0x0000_0100_0000_01B3uL
            return h
        }
    }
}

/** A learned model's prediction for one subject, from `GhostPredictor.learnedArea`. */
data class GhostLearnedArea(
    val center: FloorVector,
    /** Metres around `center` holding 95% of the model's belief. */
    val r95: Double,
    val cloud: List<FloorVector>? = null,
    /** "name@version" for the provenance, e.g. "movement-model-v2-nomap@1". */
    val algorithm: String,
)

/**
 * Swift `GhostObservation.init?(_ e: PositionEstimate, receivedAt:, frameId:)`: the estimate as an
 * observation at local time `receivedAt - ageAtHandoff`, or null when Ghost Mode must not use it
 * (see `GhostPredictor`).
 */
operator fun GhostObservation.Companion.invoke(e: PositionEstimate, receivedAt: Double, frameId: String): GhostObservation? {
    if (e.frameId != frameId) return null
    val p = e.position ?: return null
    if (!p.x.isFinite() || !p.z.isFinite()) return null
    if (e.kind !in listOf(PositionEstimate.Kind.measured, PositionEstimate.Kind.estimated, PositionEstimate.Kind.declared)) return null
    if (e.method == PositionEstimate.Method.deadReckoning) return null
    if (!e.uncertainty.r95.isFinite() || !(e.uncertainty.r95 > 0)) return null
    val source = when (e.source) {
        EvidenceSource.gnss -> GhostObservation.Source.gps
        EvidenceSource.uwb -> GhostObservation.Source.uwb
        EvidenceSource.manual -> GhostObservation.Source.manual
        else -> GhostObservation.Source.bluetooth
    }
    val velocity = e.velocity?.let { GhostVelocity(vx = it.x, vz = it.z, sigma = 0.5) }
    return GhostObservation(
        t = receivedAt - e.freshness.ageAtHandoff, x = p.x, z = p.z,
        sigma = e.uncertainty.r95 / PositionUncertainty.sigmaTo95, source = source, velocity = velocity,
        provenance = e.provenance, ambiguous = e.uncertainty.ambiguous,
    )
}

internal val GhostObservation.Source.evidence: EvidenceSource
    get() = when (this) {
        GhostObservation.Source.gps -> EvidenceSource.gnss
        GhostObservation.Source.bluetooth -> EvidenceSource.bluetooth
        GhostObservation.Source.uwb -> EvidenceSource.uwb
        GhostObservation.Source.manual -> EvidenceSource.manual
    }

/**
 * Swift `GhostMotionHint.init(_ m: MotionObservation)`: velocity from the interval's displacement,
 * its spread from the displacement's 95% radius and the heading's sigma (across the direction of
 * travel).
 */
operator fun GhostMotionHint.Companion.invoke(m: MotionObservation): GhostMotionHint {
    var velocity: GhostVelocity? = null
    val d = m.displacement
    if (!m.stationary && d != null && m.interval > 0) {
        val vx = d.x / m.interval
        val vz = d.z / m.interval
        val speed = sqrt(vx * vx + vz * vz)
        val r95 = m.uncertainty.displacementR95 ?: (0.3 * d.length + 0.5)
        val along = r95 / PositionUncertainty.sigmaTo95 / m.interval
        velocity = GhostVelocity(vx = vx, vz = vz, sigma = max(along, speed * (m.uncertainty.headingSigma ?: 0.3)))
    }
    return GhostMotionHint(t = m.timestamp, stationary = m.stationary, velocity = velocity)
}
