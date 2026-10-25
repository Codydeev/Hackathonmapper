package com.hackathonmapper.meshcore

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.math.BigDecimal
import java.math.RoundingMode
import java.text.BreakIterator
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

// GNSS integrity: judges, fix by fix, how far a GNSS position can be believed. It looks at the fix
// itself (reported accuracy, age, timestamps, speed and acceleration between fixes, jumps away
// from where we expected to be) and at evidence from outside the receiver: inertial motion (steps
// and compass, or the motion sensors), peers heard over Bluetooth, surveyed anchors, and positions
// estimated without this phone's GNSS. Grown from the Luotsi trust engine (gps-katoaa
// js/engine.js): one confident objection is enough to stop believing a fix, and trust comes back
// only slowly.
//
// This is anomaly detection, not spoofing detection. A fix that fails these checks can come from
// multipath, a receiver fault, jamming, a wrong inertial or peer input, or spoofing; phone data
// cannot tell them apart, so an assessment lists possible causes and never confirms spoofing.
// Peers whose positions come from their own GNSS share its errors (one spoofer, one jammer or one
// ionosphere covers them all), so their agreement never verifies a fix: only evidence that does
// not depend on any GNSS receiver can make a fix `trusted`.
//
// All inputs share one clock in seconds (e.g. currentTime()) and the floor plane of the shared
// frame (x east, z north, meters). Same inputs, same assessments: nothing is random.
//
// Port of ios/MeshCore/Sources/MeshCore/GNSSIntegrity.swift.

/** One GNSS fix as the app received it. */
data class GNSSFix(
    /** When the receiver computed the fix (Location.time), seconds. */
    val time: Double,
    val position: FloorPoint,
    /**
     * Reported horizontal accuracy, meters: a ~68 % radius (Location.accuracy).
     * Negative means the fix has no valid position.
     */
    val accuracy: Double,
    /** Reported ground speed (Doppler), m/s; null or negative when the receiver gave none. */
    val speed: Double? = null,
    /** Course over ground, degrees clockwise from north; null or negative when unknown. */
    val course: Double? = null,
    /** Reported 1-sigma speed accuracy, m/s. */
    val speedAccuracy: Double? = null,
) {
    /** Swift's `(x: Double, z: Double)` velocity tuple. */
    data class Velocity(val x: Double, val z: Double)

    /** 1-sigma error per axis. A 68 % radius of a circular normal error is 1.515 sigma. */
    val sigma: Double get() = accuracy / 1.515

    /**
     * Reported velocity (east, north), m/s. A receiver that is barely moving often reports no
     * course; below 0.5 m/s that counts as standing still.
     */
    val velocity: Velocity?
        get() {
            val speed = speed ?: return null
            if (!(speed >= 0 && speed.isFinite())) return null
            val course = course
            if (course == null || !(course >= 0 && course.isFinite())) return if (speed < 0.5) Velocity(0.0, 0.0) else null
            val radians = course * PI / 180
            return Velocity(speed * sin(radians), speed * cos(radians))
        }

    internal val isValid: Boolean
        get() = time.isFinite() && position.x.isFinite() && position.z.isFinite() && accuracy.isFinite() && accuracy >= 0
}

/**
 * Displacement measured without GNSS (pedestrian dead reckoning or the motion sensors) between
 * `start` and `end`, in the shared frame.
 */
data class InertialDisplacement(
    val start: Double,
    val end: Double,
    val dx: Double,
    val dz: Double,
    /**
     * 1-sigma random error of this increment per axis, meters. Heading and step-length bias,
     * which do not average out, are allowed for by `GNSSIntegrityEngine.Options`.
     */
    val sigma: Double,
    /** The phone was at rest (no steps, low acceleration variance) for the whole interval. */
    val stationary: Boolean = false,
)

/** Whether a piece of evidence is independent of GNSS. */
@Serializable
enum class EvidenceOrigin(val rawValue: String) {
    /**
     * A surveyed or hand-placed point (fixed beacon, landmark the user confirmed), or a position
     * derived only from ranging to such points.
     */
    @SerialName("surveyed") surveyed("surveyed"),

    /**
     * Comes, directly or through Bluetooth estimates, from some phone's GNSS. Shares GNSS
     * common-mode errors, so it can object to a fix but never verify one.
     */
    @SerialName("gnssDerived") gnssDerived("gnssDerived"),
}

/**
 * A peer heard directly over Bluetooth. Being heard bounds how far apart the two phones can be;
 * it says nothing about direction, so it can only catch a fix that is too far from the peer.
 */
data class PeerProximity(
    val time: Double,
    val peerId: String,
    /** Where the peer is, by its own report. */
    val peerPosition: FloorPoint,
    /** 1-sigma per axis of the peer's position, meters. */
    val peerSigma: Double,
    val origin: EvidenceOrigin,
    /** Largest plausible distance to the peer given that it was heard, meters. */
    val maxRange: Double,
) {
    companion object {
        /**
         * Upper bound on the distance to a phone heard at `rssi`: where the signal would arrive
         * `margin` standard deviations weaker than it did, capped where reception has all but faded.
         * RSSI is too noisy for a range, but generous enough for a bound.
         */
        fun maxRange(rssi: Double, radio: RadioModel = RadioModel.outdoors, margin: Double = 2.5): Double =
            min(radio.distance(rssi - margin * radio.sigma), radio.range + 4 * radio.soft)
    }
}

/**
 * This phone's position estimated without its own GNSS (the positioning engine, a landmark the
 * user confirmed).
 */
data class PositionEvidence(
    val time: Double,
    val position: FloorPoint,
    /** 1-sigma per axis, meters. */
    val sigma: Double,
    val origin: EvidenceOrigin,
    /** What it was computed from (anchor and peer IDs), for the evidence trail. */
    val sources: List<String> = emptyList(),
    /**
     * Computed from other phones (Bluetooth ranges, their anchors), rather than from this phone's
     * own sensors alone (dead reckoning from a declared spot, a landmark the user confirmed).
     */
    val fromPeers: Boolean = true,
)

@Serializable
enum class GNSSIntegrityStatus(val rawValue: String) {
    /** No anomaly, and at least one check independent of GNSS agrees. */
    @SerialName("trusted") trusted("trusted"),

    /** No anomaly, but poor reported accuracy or an aging fix. */
    @SerialName("degraded") degraded("degraded"),

    /** Anomaly evidence: use only with inflated uncertainty, prefer other sources. */
    @SerialName("suspect") suspect("suspect"),

    /** Strong anomaly: do not use as a position or as an anchor for others. */
    @SerialName("rejected") rejected("rejected"),

    /** No fix, an invalid one, or one too old to use. */
    @SerialName("unavailable") unavailable("unavailable"),

    /**
     * Self-consistent, but nothing independent of GNSS confirms it: a slow or common-mode error
     * would go unnoticed.
     */
    @SerialName("insufficientEvidence") insufficientEvidence("insufficientEvidence");

    val isAnomaly: Boolean get() = this == suspect || this == rejected
    val usableAsPosition: Boolean get() = this == trusted || this == insufficientEvidence || this == degraded
}

@Serializable
enum class GNSSReasonCode(val rawValue: String) {
    @SerialName("noFix") noFix("noFix"),
    @SerialName("staleFix") staleFix("staleFix"),
    @SerialName("invalidFix") invalidFix("invalidFix"),
    @SerialName("timestampInconsistent") timestampInconsistent("timestampInconsistent"),
    @SerialName("degradedAccuracy") degradedAccuracy("degradedAccuracy"),
    @SerialName("accuracyInconsistent") accuracyInconsistent("accuracyInconsistent"),
    @SerialName("impossibleSpeed") impossibleSpeed("impossibleSpeed"),
    @SerialName("impossibleAcceleration") impossibleAcceleration("impossibleAcceleration"),
    @SerialName("positionJump") positionJump("positionJump"),
    @SerialName("inertialDisagreement") inertialDisagreement("inertialDisagreement"),
    @SerialName("slowDrift") slowDrift("slowDrift"),
    @SerialName("peerDisagreement") peerDisagreement("peerDisagreement"),
    @SerialName("independentEvidenceDisagreement") independentEvidenceDisagreement("independentEvidenceDisagreement"),
    @SerialName("peerEvidenceNotIndependent") peerEvidenceNotIndependent("peerEvidenceNotIndependent"),
    @SerialName("insufficientEvidence") insufficientEvidence("insufficientEvidence"),
    @SerialName("continuityLost") continuityLost("continuityLost"),
    @SerialName("recovering") recovering("recovering"),
}

@Serializable
enum class GNSSCheck(val rawValue: String) {
    @SerialName("freshness") freshness("freshness"),
    @SerialName("accuracy") accuracy("accuracy"),
    @SerialName("timing") timing("timing"),
    @SerialName("speed") speed("speed"),
    @SerialName("acceleration") acceleration("acceleration"),
    @SerialName("jump") jump("jump"),
    @SerialName("inertial") inertial("inertial"),
    @SerialName("peerProximity") peerProximity("peerProximity"),
    @SerialName("anchorProximity") anchorProximity("anchorProximity"),
    @SerialName("positionEvidence") positionEvidence("positionEvidence");

    /** Quality checks say how good a fix is; the others look for anomalies. */
    val isQuality: Boolean get() = this == freshness || this == accuracy
}

/** What could explain an anomaly. Spoofing is only ever one candidate among others. */
@Serializable
enum class GNSSPossibleCause(val rawValue: String) {
    @SerialName("signalObstruction") signalObstruction("signalObstruction"),
    @SerialName("multipath") multipath("multipath"),
    @SerialName("interference") interference("interference"),
    @SerialName("receiverFault") receiverFault("receiverFault"),
    @SerialName("clockOrDelivery") clockOrDelivery("clockOrDelivery"),
    @SerialName("inertialSensorError") inertialSensorError("inertialSensorError"),
    @SerialName("peerOrAnchorError") peerOrAnchorError("peerOrAnchorError"),
    @SerialName("spoofing") spoofing("spoofing"),
}

/** One check's result. */
@Serializable
data class GNSSEvidence(
    val check: GNSSCheck,
    /** 1 = consistent, 0 = full objection. */
    val score: Double,
    val observed: Double,
    /** The observed value at which this check makes a fix suspect. */
    val threshold: Double,
    val unit: String,
    /** The evidence does not depend on any GNSS receiver. */
    val independent: Boolean,
    val detail: String,
    /** Set when the score makes the fix suspect. */
    val reason: GNSSReasonCode?,
)

data class GNSSIntegrityUncertainty(
    /** Share of the check families that had data to run, 0...1. */
    val coverage: Double,
    /** Checks independent of GNSS that ran. */
    val independentChecks: Int,
    /**
     * The trust score could be this low if the independent checks that could not run had
     * objected: 0 with none, half the score with only relative (inertial) or only absolute
     * (anchor, position) evidence, the score itself with both. A coverage heuristic.
     */
    val trustLower: Double,
    val trustUpper: Double,
    /**
     * Smallest position offset the active independent checks would flag now, meters, in the
     * worst direction. Absolute evidence (anchors, independent positions) bounds the whole offset;
     * inertial motion only an offset built up within its longest window. null: unbounded, a slow
     * or common-mode error of any size could go unnoticed.
     */
    val minimumDetectableOffset: Double?,
    /**
     * Drift slower than this (m/s) stays inside the inertial check's tolerance however long it
     * runs; only absolute evidence can catch it. null without inertial motion.
     */
    val minimumDetectableDriftRate: Double?,
    /**
     * 1-sigma per axis the positioning engine should give this fix if it uses it; grows with
     * the fix's age. null when the fix must not be used.
     */
    val recommendedSigma: Double?,
)

data class GNSSIntegrityAssessment(
    val time: Double,
    /** The fix that was judged; on a tick without a new fix, the latest one. */
    val fix: GNSSFix?,
    val status: GNSSIntegrityStatus,
    /** 0...1. */
    val trustScore: Double,
    val reasons: List<GNSSReasonCode>,
    val evidence: List<GNSSEvidence>,
    val uncertainty: GNSSIntegrityUncertainty,
    val possibleCauses: List<GNSSPossibleCause>,
    /**
     * One line for the UI, at most 160 characters, e.g. "GPS jumped 412 m in 1.0 s; not proof of
     * an attack".
     */
    val summary: String,
    /** The longer story: what was seen and what could have caused it. */
    val explanation: String,
) {
    val isAnomaly: Boolean get() = status.isAnomaly
    val usableAsPosition: Boolean get() = status.usableAsPosition

    /** Always false: phone data can show that a fix is anomalous, never that it was spoofed. */
    val spoofingConfirmed: Boolean get() = false
}

class GNSSIntegrityEngine(options: Options = Options()) {
    /** Swift value type: the engine keeps its own copy. */
    data class Options(
        /** Fastest plausible ground speed, m/s. */
        var maxSpeed: Double = 7.0,
        /** Largest plausible acceleration, m/s². */
        var maxAcceleration: Double = 4.0,
        /**
         * Reported accuracy (68 % radius, m): full marks up to `goodAccuracy`, 0.4 at
         * `poorAccuracy`, unusable beyond `unusableAccuracy`.
         */
        var goodAccuracy: Double = 15.0,
        var poorAccuracy: Double = 50.0,
        var unusableAccuracy: Double = 100.0,
        /** Fix age, s: full marks up to `freshAge`, unusable beyond `maxAge`. */
        var freshAge: Double = 2.0,
        var maxAge: Double = 30.0,
        /** Normalised residuals (sigmas) where a check starts to doubt and where it fully objects. */
        var doubtSigma: Double = 3.5,
        var rejectSigma: Double = 7.0,
        /**
         * Inertial consistency windows, s. Long windows catch slow drift; the longest one bounds
         * how old an offset can be and still be caught.
         */
        var inertialWindows: List<Double> = listOf(5.0, 15.0, 30.0, 60.0, 120.0, 300.0),
        /** Inertial heading bias allowed, degrees, and step-length (scale) bias, fraction. */
        var inertialHeadingBias: Double = 10.0,
        var inertialScaleBias: Double = 0.08,
        /** Error floor of any inertial displacement, m. */
        var inertialFloor: Double = 1.5,
        /** Motion data may lag a fix by this much and still count, s; longer gaps break coverage. */
        var motionLatency: Double = 1.0,
        var maxMotionGap: Double = 3.0,
        /** How fast our own position reference loosens with no motion data, 1-sigma m/s. */
        var unaidedGrowth: Double = 0.5,
        /**
         * A fix is `trusted` only if the independent checks would catch an offset this large,
         * meters (built up within the longest inertial window, or absolute).
         */
        var alertLimit: Double = 50.0,
        /**
         * Reference looser than this (1-sigma m) when GNSS is taken back after a rejection
         * cannot tell the real position from a new offset: continuity is lost.
         */
        var tightReference: Double = 20.0,
        /** Trust regained per second after an anomaly. */
        var recoveryRate: Double = 0.1,
        /** Peer and position evidence older than this (s) relative to the fix is ignored. */
        var evidenceMaxAge: Double = 3.0,
        /** How fast an aging fix goes out of date, m/s, for `recommendedSigma`. */
        var staleSpeed: Double = 1.5,
        /** Fixes kept for the accuracy-consistency check. */
        var consistencyFixes: Int = 20,
        /** Seconds of history kept. */
        var history: Double = 330.0,
    ) {
        companion object {
            /** On foot (the default). A fresh copy each time, like Swift's value type. */
            val pedestrian: Options get() = Options()

            /** In a vehicle. */
            val vehicle: Options
                get() = Options().apply {
                    maxSpeed = 70.0
                    maxAcceleration = 8.0
                    unaidedGrowth = 15.0
                    staleSpeed = 25.0
                    alertLimit = 100.0
                }
        }
    }

    val options: Options = options.copy()
    var latest: GNSSIntegrityAssessment? = null
        private set

    /**
     * The latest fix that was usable as a position, with its assessment: what the positioning
     * engine should treat as "last trusted GNSS".
     */
    var lastUsable: GNSSIntegrityAssessment? = null
        private set

    private data class TrackPoint(
        val time: Double,
        val x: Double,
        val z: Double,
        val variance: Double,
    )

    /**
     * Where we expect this phone to be, independent of the newest fix: the last accepted fix
     * carried forward by inertial motion (or loosened by `unaidedGrowth` without it).
     * Mutated in place and only ever held by `reference`, which matches Swift's copy-and-write-back.
     */
    private class Reference(
        var time: Double,
        var x: Double,
        var z: Double,
        /** Random part, per axis. */
        var variance: Double,
        /** Inertial displacement since the last accepted fix; its bias does not average out. */
        var deadReckonedX: Double = 0.0,
        var deadReckonedZ: Double = 0.0,
    )

    private data class CheckOutcome(
        val evidence: GNSSEvidence,
        val reason: GNSSReasonCode?,
        /** Offset this check would flag right now (independent checks only). */
        val detectable: Double?,
        /** Absolute position evidence (anchor, position estimate) rather than relative motion. */
        val absolute: Boolean,
        /** Slowest drift this check would ever flag, m/s (inertial only). */
        var driftRate: Double? = null,
    )

    private data class EvidenceKey(val origin: EvidenceOrigin, val fromPeers: Boolean)

    private var lastFix: GNSSFix? = null
    private var previousFix: GNSSFix? = null
    private val accepted = ArrayList<GNSSFix>()
    private var reference: Reference? = null
    private val track = ArrayList<TrackPoint>()
    private var trackStart: Double? = null
    private val peers = HashMap<String, PeerProximity>()
    private val positionEvidence = HashMap<EvidenceKey, PositionEvidence>()
    private val normalizedSquares = ArrayList<Double>()
    private var lastOutcomes: List<CheckOutcome> = emptyList()
    private var lastAnomalyRaw = 1.0
    private var anomalyTrust = 1.0
    private var lastAssessedAt: Double? = null
    private var continuityLost = false

    // MARK: Inputs

    fun addMotion(motion: InertialDisplacement) {
        if (!(motion.end > motion.start && motion.dx.isFinite() && motion.dz.isFinite() &&
                motion.sigma.isFinite() && motion.sigma >= 0)) return
        val previous = track.lastOrNull()
        if (previous != null) {
            if (motion.start < previous.time - 0.05) return
            if (motion.start - previous.time > options.maxMotionGap) {
                trackStart = motion.start
                track.add(TrackPoint(motion.start, previous.x, previous.z, previous.variance))
            }
        } else {
            trackStart = motion.start
            track.add(TrackPoint(motion.start, 0.0, 0.0, 0.0))
        }
        val last = track[track.size - 1]
        track.add(TrackPoint(motion.end, last.x + motion.dx, last.z + motion.dz,
            last.variance + motion.sigma * motion.sigma))
        val horizon = motion.end - options.history
        val index = track.indexOfFirst { it.time >= horizon }
        if (index > 1) {
            track.subList(0, index - 1).clear()
            trackStart = max(trackStart ?: track[0].time, track[0].time)
        }
    }

    fun addPeer(peer: PeerProximity) {
        if (!(peer.peerPosition.x.isFinite() && peer.peerPosition.z.isFinite() && peer.maxRange.isFinite() &&
                peer.maxRange > 0 && peer.peerSigma.isFinite() && peer.peerSigma >= 0)) return
        val known = peers[peer.peerId]
        if (known != null && known.time > peer.time) return
        peers[peer.peerId] = peer
    }

    fun addPositionEvidence(evidence: PositionEvidence) {
        if (!(evidence.position.x.isFinite() && evidence.position.z.isFinite() &&
                evidence.sigma.isFinite() && evidence.sigma > 0)) return
        val key = EvidenceKey(evidence.origin, evidence.fromPeers)
        val known = positionEvidence[key]
        if (known != null && known.time > evidence.time) return
        positionEvidence[key] = evidence
    }

    fun reset() {
        latest = null
        lastUsable = null
        lastFix = null
        previousFix = null
        accepted.clear()
        reference = null
        track.clear()
        trackStart = null
        peers.clear()
        positionEvidence.clear()
        normalizedSquares.clear()
        lastOutcomes = emptyList()
        lastAnomalyRaw = 1.0
        anomalyTrust = 1.0
        lastAssessedAt = null
        continuityLost = false
    }

    // MARK: Assessment

    /**
     * Judges a new fix. `now` is when the app received it (defaults to the fix time); a fix that
     * arrives late is judged stale.
     */
    fun assess(fix: GNSSFix, now: Double? = null): GNSSIntegrityAssessment {
        val now = now ?: fix.time
        if (!fix.isValid) return assess(now, invalidFix = true)
        val lastFix = lastFix
        if (lastFix != null && fix.time == lastFix.time && fix.position == lastFix.position) {
            return assess(now)
        }

        val outcomes = mutableListOf(freshnessCheck(now - fix.time, fix), accuracyCheck(fix))
        var regressed = false
        val timing = timingCheck(fix, now)
        if (timing != null) {
            outcomes.add(timing)
            regressed = lastFix?.let { fix.time < it.time } ?: false
        }
        if (!regressed) {
            speedCheck(fix)?.let { outcomes.add(it) }
            accelerationCheck(fix)?.let { outcomes.add(it) }
            propagateReference(fix.time)
            jumpCheck(fix)?.let { outcomes.add(it) }
            inertialCheck(fix)?.let { outcomes.add(it) }
        }
        outcomes += proximityChecks(fix)
        outcomes += positionEvidenceChecks(fix)

        val anomalyRaw = outcomes.filter { !it.evidence.check.isQuality }.map { it.evidence.score }.minOrNull() ?: 1.0
        smoothTrust(anomalyRaw, now)

        // Take the fix into our reference only if nothing objects to it. A rejected fix leaves
        // the reference running on inertial motion, so a persistent offset stays visible. Taking
        // GNSS back when the reference has grown loose (after an anomaly or an outage, the classic
        // jam-then-spoof opening) cannot tell the real position from a new offset.
        val consistent = !regressed && anomalyRaw >= suspectBelow && fix.accuracy <= options.unusableAccuracy
        if (consistent) {
            val reference = reference
            if (reference != null && sqrt(referenceVariance(reference)) > options.tightReference) {
                continuityLost = true
            }
            accept(fix)
        }
        if (continuityLost && outcomes.any { it.absolute && it.evidence.independent && it.evidence.score >= 0.9 }) {
            continuityLost = false
        }
        if (!regressed) {
            previousFix = this.lastFix
            this.lastFix = fix
        }
        lastOutcomes = outcomes.toList()
        lastAnomalyRaw = anomalyRaw
        return publish(fuse(now, fix, outcomes, anomalyRaw, forceReject = regressed))
    }

    /** Re-judges the latest fix at `now` without a new one: fixes that stop coming go stale. */
    fun assess(now: Double): GNSSIntegrityAssessment = assess(now, invalidFix = false)

    private fun assess(now: Double, invalidFix: Boolean): GNSSIntegrityAssessment {
        val lastFix = lastFix
            ?: return publish(unavailable(now, if (invalidFix) GNSSReasonCode.invalidFix else GNSSReasonCode.noFix, null,
                if (invalidFix) "GPS fix has no valid position" else "No GPS fix yet"))
        val outcomes = lastOutcomes.filter { it.evidence.check != GNSSCheck.freshness }.toMutableList()
        outcomes.add(0, freshnessCheck(now - lastFix.time, lastFix))
        smoothTrust(lastAnomalyRaw, now)
        return publish(fuse(now, lastFix, outcomes, lastAnomalyRaw, forceReject = false))
    }

    private fun publish(assessment: GNSSIntegrityAssessment): GNSSIntegrityAssessment {
        latest = assessment
        if (assessment.usableAsPosition) lastUsable = assessment
        return assessment
    }

    private fun smoothTrust(raw: Double, now: Double) {
        val dt = lastAssessedAt?.let { max(0.0, now - it) } ?: 0.0
        lastAssessedAt = max(lastAssessedAt ?: now, now)
        // Trust drops at once and climbs back at `recoveryRate`.
        anomalyTrust = min(raw, anomalyTrust + options.recoveryRate * dt)
    }

    private fun accept(fix: GNSSFix) {
        val r = fix.sigma * fix.sigma
        val reference = reference
        if (reference != null) {
            val variance = referenceVariance(reference)
            val gain = variance / (variance + r)
            reference.x += gain * (fix.position.x - reference.x)
            reference.z += gain * (fix.position.z - reference.z)
            reference.variance = max((1 - gain) * variance, 1.0)
            reference.time = fix.time
            reference.deadReckonedX = 0.0
            reference.deadReckonedZ = 0.0
        } else {
            this.reference = Reference(fix.time, fix.position.x, fix.position.z, max(r, 1.0))
        }
        accepted.add(fix)
        val horizon = fix.time - options.history
        val index = accepted.indexOfFirst { it.time >= horizon }
        if (index > 0) accepted.subList(0, index).clear()
    }

    // MARK: Fusion

    private fun fuse(now: Double, fix: GNSSFix?, outcomes: List<CheckOutcome>, anomalyRaw: Double,
                     forceReject: Boolean): GNSSIntegrityAssessment {
        if (fix == null) return unavailable(now, GNSSReasonCode.noFix, null, "No GPS fix yet")
        val age = now - fix.time
        if (age > options.maxAge) {
            return unavailable(now, GNSSReasonCode.staleFix, fix, "Last GPS fix is ${seconds(age)} old")
        }
        if (fix.accuracy > options.unusableAccuracy) {
            return unavailable(now, GNSSReasonCode.degradedAccuracy, fix,
                "GPS accuracy ${meters(fix.accuracy)}: too coarse to use")
        }

        val quality = outcomes.filter { it.evidence.check.isQuality }.map { it.evidence.score }.minOrNull() ?: 1.0
        val anomalyOutcomes = outcomes.filter { !it.evidence.check.isQuality }
        val independent = outcomes.filter { it.evidence.independent }
        val detectable = independent.mapNotNull { it.detectable }.minOrNull()
        val independentAgree = independent.any { it.evidence.score >= suspectBelow }
        val bounded = (detectable ?: Double.POSITIVE_INFINITY) <= options.alertLimit
        val dependentAgree = outcomes.any {
            !it.evidence.independent && it.evidence.check in listOf(GNSSCheck.peerProximity, GNSSCheck.positionEvidence) &&
                it.evidence.score >= suspectBelow
        }

        val status: GNSSIntegrityStatus = if (forceReject || anomalyTrust < rejectBelow || anomalyRaw <= hardReject) {
            GNSSIntegrityStatus.rejected
        } else if (anomalyTrust < suspectBelow || (latest?.status?.isAnomaly == true && anomalyTrust < clearAbove)) {
            // Hysteresis: an anomaly clears only well above the line, so a borderline fix does not flap.
            GNSSIntegrityStatus.suspect
        } else if (quality < suspectBelow) {
            GNSSIntegrityStatus.degraded
        } else if (continuityLost || !independentAgree || !bounded) {
            GNSSIntegrityStatus.insufficientEvidence
        } else {
            GNSSIntegrityStatus.trusted
        }

        val reasons = mutableListOf<GNSSReasonCode>()
        fun add(reason: GNSSReasonCode?) {
            if (reason != null && reason !in reasons) reasons.add(reason)
        }
        for (outcome in outcomes.sortedBy { it.evidence.score }) {
            if (outcome.evidence.score < suspectBelow) add(outcome.reason)
        }
        if (status.isAnomaly && !anomalyOutcomes.any { it.evidence.score < suspectBelow }) {
            add(GNSSReasonCode.recovering)
        }
        if (status == GNSSIntegrityStatus.insufficientEvidence) {
            add(if (continuityLost) GNSSReasonCode.continuityLost else GNSSReasonCode.insufficientEvidence)
            if (dependentAgree && !independentAgree) add(GNSSReasonCode.peerEvidenceNotIndependent)
        }

        val trust = min(anomalyTrust, quality)
        val relative = independent.any { !it.absolute }
        val absolute = independent.any { it.absolute }
        val lower = if (relative && absolute) trust else if (relative || absolute) trust / 2 else 0.0
        val factor: Double? = when (status) {
            GNSSIntegrityStatus.trusted -> 1.0
            GNSSIntegrityStatus.insufficientEvidence -> 1.5
            GNSSIntegrityStatus.degraded -> 2.0
            GNSSIntegrityStatus.suspect -> 4.0
            GNSSIntegrityStatus.rejected, GNSSIntegrityStatus.unavailable -> null
        }
        val recommended = factor?.let { it * fix.sigma + max(0.0, age) * options.staleSpeed }

        val possible = causes(reasons)
        val evidence = outcomes.map { it.evidence }
        val text = summary(status, outcomes, possible, dependentAgree, continuityLost,
            unboundedBy = if (bounded) null else detectable)
        return GNSSIntegrityAssessment(
            time = now, fix = fix, status = status, trustScore = trust, reasons = reasons.toList(), evidence = evidence,
            uncertainty = GNSSIntegrityUncertainty(
                coverage = evidence.map { it.check }.toSet().size.toDouble() / GNSSCheck.entries.size.toDouble(),
                independentChecks = independent.size, trustLower = lower, trustUpper = trust,
                minimumDetectableOffset = detectable,
                minimumDetectableDriftRate = independent.mapNotNull { it.driftRate }.minOrNull(),
                recommendedSigma = recommended,
            ),
            possibleCauses = possible, summary = text.first, explanation = text.second,
        )
    }

    private fun unavailable(now: Double, reason: GNSSReasonCode, fix: GNSSFix?, detail: String): GNSSIntegrityAssessment {
        val possible = causes(listOf(reason))
        return GNSSIntegrityAssessment(
            time = now, fix = fix, status = GNSSIntegrityStatus.unavailable, trustScore = 0.0, reasons = listOf(reason),
            evidence = emptyList(),
            uncertainty = GNSSIntegrityUncertainty(
                coverage = 0.0, independentChecks = 0, trustLower = 0.0, trustUpper = 0.0,
                minimumDetectableOffset = null, minimumDetectableDriftRate = null, recommendedSigma = null,
            ),
            possibleCauses = possible, summary = clipped(detail),
            explanation = "$detail. Possible causes: ${describe(possible)}.",
        )
    }

    // MARK: Checks

    private fun score(sigmas: Double): Double =
        clamp01(1 - (sigmas - options.doubtSigma) / (options.rejectSigma - options.doubtSigma))

    /** Normalised residual at which a check's score falls to `suspectBelow`. */
    private val suspectSigmas: Double
        get() = options.doubtSigma + (1 - suspectBelow) * (options.rejectSigma - options.doubtSigma)

    private fun evidence(check: GNSSCheck, score: Double, observed: Double, threshold: Double, unit: String,
                         independent: Boolean = false, detail: String, reason: GNSSReasonCode?,
                         detectable: Double? = null, absolute: Boolean = false): CheckOutcome {
        val kept = if (score < suspectBelow) reason else null
        return CheckOutcome(
            evidence = GNSSEvidence(check = check, score = score, observed = observed, threshold = threshold,
                unit = unit, independent = independent, detail = detail, reason = kept),
            reason = kept, detectable = detectable, absolute = absolute,
        )
    }

    private fun freshnessCheck(age: Double, fix: GNSSFix): CheckOutcome {
        val fade = options.freshAge + 6
        val score = ramp(age, listOf(options.freshAge to 1.0, fade to 0.6, options.maxAge to 0.3))
        val threshold = options.freshAge + (fade - options.freshAge) * 0.25 / 0.4
        return evidence(GNSSCheck.freshness, score, observed = max(0.0, age), threshold = threshold, unit = "s",
            detail = "GPS fix ${seconds(max(0.0, age))} old", reason = GNSSReasonCode.staleFix)
    }

    private fun accuracyCheck(fix: GNSSFix): CheckOutcome {
        val reported = ramp(fix.accuracy, listOf(options.goodAccuracy to 1.0, options.poorAccuracy to 0.4,
            options.unusableAccuracy to 0.1))
        val threshold = options.goodAccuracy + (options.poorAccuracy - options.goodAccuracy) * 0.25 / 0.6
        // Reported accuracy that the fixes themselves keep exceeding is not credible. Accepted
        // fixes against our reference should average 2 for squared per-axis normalised offsets.
        val meanSquare = if (normalizedSquares.size >= options.consistencyFixes / 2)
            normalizedSquares.fold(0.0) { a, b -> a + b } / normalizedSquares.size.toDouble() else null
        val consistency = meanSquare?.let { ramp(it, listOf(8.0 to 1.0, 18.0 to 0.6, 50.0 to 0.3)) } ?: 1.0
        if (consistency < reported && meanSquare != null) {
            return evidence(GNSSCheck.accuracy, consistency, observed = sqrt(meanSquare / 2), threshold = 2.5, unit = "x",
                detail = "GPS scatters ${format1(sqrt(meanSquare / 2))}x its stated ${meters(fix.accuracy)} accuracy",
                reason = GNSSReasonCode.accuracyInconsistent)
        }
        return evidence(GNSSCheck.accuracy, reported, observed = fix.accuracy, threshold = threshold, unit = "m",
            detail = "GPS accuracy ${meters(fix.accuracy)}", reason = GNSSReasonCode.degradedAccuracy)
    }

    private fun timingCheck(fix: GNSSFix, now: Double): CheckOutcome? {
        val lastFix = lastFix
        if (lastFix != null && fix.time < lastFix.time) {
            return evidence(GNSSCheck.timing, 0.0, observed = lastFix.time - fix.time, threshold = 0.0, unit = "s",
                detail = "GPS time went back ${seconds(lastFix.time - fix.time)}",
                reason = GNSSReasonCode.timestampInconsistent)
        }
        if (fix.time > now + 2) {
            return evidence(GNSSCheck.timing, 0.3, observed = fix.time - now, threshold = 2.0, unit = "s",
                detail = "GPS time is ${seconds(fix.time - now)} in the future",
                reason = GNSSReasonCode.timestampInconsistent)
        }
        return null
    }

    private fun speedCheck(fix: GNSSFix): CheckOutcome? {
        var excess = 0.0
        var detail = ""
        val previous = lastFix
        if (previous != null && fix.time > previous.time && fix.time - previous.time <= 30) {
            val dt = fix.time - previous.time
            val moved = distance(fix.position, previous.position)
            // Only the part of the move that position noise cannot explain counts.
            val noise = options.doubtSigma * sqrt(fix.sigma * fix.sigma + previous.sigma * previous.sigma)
            excess = max(0.0, moved - noise) / dt
            detail = "GPS moved ${meters(moved)} in ${seconds(dt)}"
        }
        val reportedSpeed = fix.speed
        if (reportedSpeed != null && reportedSpeed.isFinite() && reportedSpeed >= 0) {
            val reported = max(0.0, reportedSpeed - options.doubtSigma * (fix.speedAccuracy ?: 0.5))
            if (reported > excess) {
                excess = reported
                detail = "GPS reports ${speed(reportedSpeed)}"
            }
        }
        if (detail.isEmpty()) return null
        val score = if (excess <= options.maxSpeed) 1.0 else clamp01(1 - (excess - options.maxSpeed) / options.maxSpeed)
        return evidence(GNSSCheck.speed, score, observed = excess, threshold = options.maxSpeed * (2 - suspectBelow),
            unit = "m/s", detail = detail, reason = GNSSReasonCode.impossibleSpeed)
    }

    private fun accelerationCheck(fix: GNSSFix): CheckOutcome? {
        val previous = lastFix ?: return null
        if (!(fix.time > previous.time && fix.time - previous.time <= 5)) return null
        val dt = fix.time - previous.time
        val dv: Double
        val noise: Double
        val v2 = fix.velocity
        val v1 = previous.velocity
        val first = previousFix
        if (v2 != null && v1 != null) {
            dv = hypot(v2.x - v1.x, v2.z - v1.z)
            noise = sqrt(2.0) * maxOf(fix.speedAccuracy ?: 1.0, previous.speedAccuracy ?: 1.0, 0.3)
        } else if (first != null && previous.time > first.time && previous.time - first.time <= 5) {
            val dt1 = previous.time - first.time
            val v1x = (previous.position.x - first.position.x) / dt1
            val v1z = (previous.position.z - first.position.z) / dt1
            val v2x = (fix.position.x - previous.position.x) / dt
            val v2z = (fix.position.z - previous.position.z) / dt
            dv = hypot(v2x - v1x, v2z - v1z)
            // v2 - v1 = p2/dt - p1 (1/dt + 1/dt1) + p0/dt1, with independent errors per fix.
            val a = fix.sigma / dt
            val b = previous.sigma * (1 / dt + 1 / dt1)
            val c = first.sigma / dt1
            noise = sqrt(a * a + b * b + c * c)
        } else {
            return null
        }
        val excess = max(0.0, dv - options.doubtSigma * noise) / dt
        val score = if (excess <= options.maxAcceleration) 1.0
        else clamp01(1 - (excess - options.maxAcceleration) / options.maxAcceleration)
        return evidence(GNSSCheck.acceleration, score, observed = excess,
            threshold = options.maxAcceleration * (2 - suspectBelow),
            unit = "m/s²", detail = "GPS velocity changed ${speed(dv)} in ${seconds(dt)}",
            reason = GNSSReasonCode.impossibleAcceleration)
    }

    private fun referenceVariance(reference: Reference): Double {
        val bias = biasFraction(options)
        val deadReckoned = hypot(reference.deadReckonedX, reference.deadReckonedZ)
        return reference.variance + (bias * deadReckoned) * (bias * deadReckoned)
    }

    private fun propagateReference(time: Double) {
        val reference = reference ?: return
        if (!(time > reference.time)) return
        val from = trackPoint(reference.time)
        val to = trackPoint(time)
        if (from != null && to != null) {
            val dx = to.x - from.x
            val dz = to.z - from.z
            reference.x += dx
            reference.z += dz
            reference.deadReckonedX += dx
            reference.deadReckonedZ += dz
            reference.variance += max(0.0, to.variance - from.variance)
        } else {
            val sigma = sqrt(reference.variance) + options.unaidedGrowth * (time - reference.time)
            reference.variance = sigma * sigma
        }
        reference.time = time
    }

    /**
     * Compares the fix with the last accepted one carried forward by inertial motion, allowing
     * the dead-reckoned leg its heading and step-length bias. While fixes keep being rejected the
     * leg keeps growing, so an offset that grows faster than the bias stays rejected.
     */
    private fun jumpCheck(fix: GNSSFix): CheckOutcome? {
        val reference = reference ?: return null
        val sigma = sqrt(reference.variance + fix.sigma * fix.sigma)
        val offset = hypot(fix.position.x - reference.x, fix.position.z - reference.z)
        val residual = distanceOutsideBias(
            gx = fix.position.x - (reference.x - reference.deadReckonedX),
            gz = fix.position.z - (reference.z - reference.deadReckonedZ),
            ix = reference.deadReckonedX, iz = reference.deadReckonedZ,
            maxAngle = options.inertialHeadingBias * PI / 180, maxScale = options.inertialScaleBias,
        )
        val n = residual / sigma
        // Feeds the accuracy-consistency check, but only from fixes we would take.
        if (n < options.doubtSigma) {
            val normalised = offset / max(fix.sigma, 0.5)
            normalizedSquares.add(min(normalised * normalised, 200.0))
            if (normalizedSquares.size > options.consistencyFixes) normalizedSquares.removeAt(0)
        }
        val leg = hypot(reference.deadReckonedX, reference.deadReckonedZ)
        return evidence(GNSSCheck.jump, score(n), observed = residual, threshold = suspectSigmas * sigma, unit = "m",
            detail = "GPS ${meters(offset)} from where ${if (leg < 0.5) "the last good fix" else "steps"} put us",
            reason = GNSSReasonCode.positionJump)
    }

    private data class InertialWorst(
        val n: Double, val residual: Double, val sigma: Double, val window: Double, val gnss: Double, val inertial: Double,
    )

    private fun inertialCheck(fix: GNSSFix): CheckOutcome? {
        val trackStart = trackStart ?: return null
        val current = trackPoint(fix.time) ?: return null
        val angle = options.inertialHeadingBias * PI / 180
        var worst: InertialWorst? = null
        // A slow drift is caught by the longest window or not at all, so that one sets the bound.
        var longest: Pair<Double, Double>? = null // (window, reach)
        for (window in options.inertialWindows) {
            val start = fix.time - window
            if (!(start >= trackStart - 0.5)) continue
            val base = acceptedFix(start, tolerance = max(1.5, 0.05 * window)) ?: continue
            if (!(base.time >= trackStart - 0.5)) continue
            val then = trackPoint(base.time) ?: continue
            val gx = fix.position.x - base.position.x
            val gz = fix.position.z - base.position.z
            val ix = current.x - then.x
            val iz = current.z - then.z
            val residual = distanceOutsideBias(gx, gz, ix, iz, maxAngle = angle, maxScale = options.inertialScaleBias)
            val sigma = sqrt(fix.sigma * fix.sigma + base.sigma * base.sigma + max(0.0, current.variance - then.variance) +
                options.inertialFloor * options.inertialFloor)
            val n = residual / sigma
            if (worst == null || n > worst.n) {
                worst = InertialWorst(n, residual, sigma, window, hypot(gx, gz), hypot(ix, iz))
            }
            val reach = suspectSigmas * sigma + hypot(ix, iz) * max(sin(angle), options.inertialScaleBias)
            if (window >= (longest?.first ?: 0.0)) longest = window to reach
        }
        if (worst == null || longest == null) return null
        val score = score(worst.n)
        // Caught only by the long windows: a slow drift rather than a jump.
        val reason = if (worst.window >= 60 && score < suspectBelow) GNSSReasonCode.slowDrift
        else GNSSReasonCode.inertialDisagreement
        val detail = if (worst.inertial < 0.5)
            "Phone still, but GPS moved ${meters(worst.gnss)} in ${seconds(worst.window)}"
        else "GPS moved ${meters(worst.gnss)}, steps say ${meters(worst.inertial)} in ${seconds(worst.window)}"
        val outcome = evidence(GNSSCheck.inertial, score, observed = worst.residual, threshold = suspectSigmas * worst.sigma,
            unit = "m", independent = true, detail = detail, reason = reason, detectable = longest.second)
        outcome.driftRate = longest.second / longest.first
        return outcome
    }

    private data class ScoredPeer(
        val score: Double, val distance: Double, val allowed: Double, val slack: Double, val id: String,
    )

    private fun proximityChecks(fix: GNSSFix): List<CheckOutcome> {
        val recent = peers.values.filter { abs(it.time - fix.time) <= options.evidenceMaxAge }.sortedBy { it.peerId }
        val outcomes = mutableListOf<CheckOutcome>()
        for (origin in EvidenceOrigin.entries) {
            val group = recent.filter { it.origin == origin }
            if (group.isEmpty()) continue
            val scored = group.map { peer ->
                val gap = distance(fix.position, peer.peerPosition)
                val allowed = peer.maxRange +
                    options.doubtSigma * sqrt(fix.sigma * fix.sigma + peer.peerSigma * peer.peerSigma)
                val slack = max(20.0, 0.5 * peer.maxRange)
                val score = if (gap <= allowed) 1.0 else clamp01(1 - (gap - allowed) / slack)
                ScoredPeer(score, gap, allowed, slack, peer.peerId)
            }.sortedBy { it.score }
            // With three or more, one faulty peer cannot condemn the fix: the median decides.
            val pick = if (scored.size >= 3) scored[scored.size / 2] else scored[0]
            val objecting = scored.count { it.score < suspectBelow }
            val independent = origin == EvidenceOrigin.surveyed
            val who = if (independent) "beacon" else "peer"
            val detail = if (objecting == 0)
                "GPS within Bluetooth range of ${scored.size} $who${if (scored.size == 1) "" else "s"}"
            else "GPS ${meters(pick.distance)} from $who ${pick.id}, in Bluetooth range"
            outcomes.add(evidence(if (independent) GNSSCheck.anchorProximity else GNSSCheck.peerProximity, pick.score,
                observed = pick.distance, threshold = pick.allowed + (1 - suspectBelow) * pick.slack, unit = "m",
                independent = independent, detail = detail,
                reason = if (independent) GNSSReasonCode.independentEvidenceDisagreement else GNSSReasonCode.peerDisagreement,
                detectable = if (independent) pick.allowed else null, absolute = true))
        }
        return outcomes
    }

    private fun positionEvidenceChecks(fix: GNSSFix): List<CheckOutcome> =
        positionEvidence.keys
            .sortedWith(compareBy<EvidenceKey>({ it.origin.rawValue }, { if (it.fromPeers) 1 else 0 }))
            .mapNotNull { key ->
                val estimate = positionEvidence[key] ?: return@mapNotNull null
                if (abs(estimate.time - fix.time) > options.evidenceMaxAge) return@mapNotNull null
                val sigma = sqrt(fix.sigma * fix.sigma + estimate.sigma * estimate.sigma)
                val offset = distance(fix.position, estimate.position)
                val independent = key.origin == EvidenceOrigin.surveyed
                // Named after where it came from; the reason after whether it depends on GNSS. An own
                // estimate that does depend on GNSS is this phone's earlier GNSS carried by its motion.
                val what = if (!key.fromPeers) "this phone's own position estimate"
                else if (independent) "the independent position estimate" else "the peer-based position estimate"
                val reason = if (independent) GNSSReasonCode.independentEvidenceDisagreement
                else if (key.fromPeers) GNSSReasonCode.peerDisagreement else GNSSReasonCode.inertialDisagreement
                evidence(GNSSCheck.positionEvidence, score(offset / sigma), observed = offset,
                    threshold = suspectSigmas * sigma, unit = "m", independent = independent,
                    detail = "GPS ${meters(offset)} from $what", reason = reason,
                    detectable = if (independent) suspectSigmas * sigma else null, absolute = true)
            }

    // MARK: History

    private fun acceptedFix(time: Double, tolerance: Double): GNSSFix? {
        var best: GNSSFix? = null
        for (i in accepted.indices.reversed()) {
            val fix = accepted[i]
            if (fix.time < time - tolerance) break
            if (abs(fix.time - time) <= tolerance && (best?.let { abs(fix.time - time) < abs(it.time - time) } ?: true)) {
                best = fix
            }
        }
        return best
    }

    /** Cumulative inertial displacement at `time`, interpolated; null outside unbroken coverage. */
    private fun trackPoint(time: Double): TrackPoint? {
        val trackStart = trackStart ?: return null
        val last = track.lastOrNull() ?: return null
        if (!(time >= trackStart - 0.5 && time <= last.time + options.motionLatency)) return null
        if (time >= last.time) return last
        if (time <= track[0].time) return track[0]
        var low = 0
        var high = track.size - 1
        while (high - low > 1) {
            val mid = (low + high) / 2
            if (track[mid].time <= time) low = mid else high = mid
        }
        val a = track[low]
        val b = track[high]
        val f = if (b.time > a.time) (time - a.time) / (b.time - a.time) else 0.0
        return TrackPoint(time, a.x + f * (b.x - a.x), a.z + f * (b.z - a.z), a.variance + f * (b.variance - a.variance))
    }

    companion object {
        /**
         * A check scoring below this makes a fix suspect; trust below `rejectBelow` rejects it, as
         * does any single anomaly check at or below `hardReject`.
         */
        const val suspectBelow = 0.75
        const val rejectBelow = 0.4
        const val hardReject = 0.2

        /** Trust an anomaly has to climb back above before it clears. */
        const val clearAbove = 0.85

        internal fun causes(reasons: List<GNSSReasonCode>): List<GNSSPossibleCause> {
            val causes = mutableListOf<GNSSPossibleCause>()
            for (reason in reasons) {
                val candidates: List<GNSSPossibleCause> = when (reason) {
                    GNSSReasonCode.noFix, GNSSReasonCode.staleFix -> listOf(GNSSPossibleCause.signalObstruction,
                        GNSSPossibleCause.interference, GNSSPossibleCause.receiverFault, GNSSPossibleCause.clockOrDelivery)
                    GNSSReasonCode.invalidFix, GNSSReasonCode.degradedAccuracy -> listOf(GNSSPossibleCause.signalObstruction,
                        GNSSPossibleCause.multipath, GNSSPossibleCause.interference)
                    GNSSReasonCode.accuracyInconsistent -> listOf(GNSSPossibleCause.multipath,
                        GNSSPossibleCause.receiverFault, GNSSPossibleCause.spoofing)
                    GNSSReasonCode.timestampInconsistent -> listOf(GNSSPossibleCause.clockOrDelivery,
                        GNSSPossibleCause.receiverFault, GNSSPossibleCause.spoofing)
                    GNSSReasonCode.impossibleSpeed, GNSSReasonCode.impossibleAcceleration, GNSSReasonCode.positionJump ->
                        listOf(GNSSPossibleCause.multipath, GNSSPossibleCause.receiverFault, GNSSPossibleCause.spoofing)
                    GNSSReasonCode.inertialDisagreement, GNSSReasonCode.slowDrift -> listOf(GNSSPossibleCause.multipath,
                        GNSSPossibleCause.inertialSensorError, GNSSPossibleCause.spoofing)
                    GNSSReasonCode.peerDisagreement, GNSSReasonCode.independentEvidenceDisagreement ->
                        listOf(GNSSPossibleCause.multipath, GNSSPossibleCause.peerOrAnchorError, GNSSPossibleCause.spoofing)
                    GNSSReasonCode.peerEvidenceNotIndependent, GNSSReasonCode.insufficientEvidence,
                    GNSSReasonCode.continuityLost, GNSSReasonCode.recovering -> emptyList()
                }
                for (cause in candidates) if (cause !in causes) causes.add(cause)
            }
            return causes
        }

        /**
         * The UI line (GPS wording, no attack wording beyond "not proof of an attack") and the longer
         * explanation with the possible causes.
         */
        private fun summary(status: GNSSIntegrityStatus, outcomes: List<CheckOutcome>, causes: List<GNSSPossibleCause>,
                            dependentAgree: Boolean, continuityLost: Boolean,
                            unboundedBy: Double?): Pair<String, String> {
            val worst = outcomes.minByOrNull { it.evidence.score }
            val objection = worst?.let { if (it.evidence.score < suspectBelow) it.evidence.detail else null }
            val agreeing = outcomes.filter { it.evidence.independent && it.evidence.score >= suspectBelow }
            val summary: String
            val explanation: String
            when (status) {
                GNSSIntegrityStatus.trusted -> {
                    val with = agreeing.map { outcome ->
                        when (outcome.evidence.check) {
                            GNSSCheck.inertial -> "steps and compass"
                            GNSSCheck.anchorProximity -> "a surveyed beacon"
                            else -> "an independent position"
                        }
                    }
                    summary = "GPS agrees with ${with.firstOrNull() ?: "independent evidence"}"
                    explanation = "No check objects, and evidence that does not depend on GNSS agrees: " +
                        agreeing.joinToString("; ") { it.evidence.detail } + "."
                }
                GNSSIntegrityStatus.insufficientEvidence -> {
                    if (continuityLost) {
                        summary = "GPS consistent again after an anomaly; not re-verified yet"
                        explanation = "GNSS is consistent again after an anomaly or outage, but our own reference had grown too loose to tell a real return from a new offset. A surveyed beacon or an independent position fix would re-verify it."
                    } else if (unboundedBy != null) {
                        summary = "GPS agrees with steps, but a slow drift up to ${meters(unboundedBy)} could pass unseen"
                        explanation = "Independent checks agree, but with the heading and step-length bias allowed they would miss an offset of up to ${meters(unboundedBy)} built up slowly."
                    } else {
                        summary = if (dependentAgree) "GPS unchecked: peers agree, but they use GPS too"
                        else "GPS unchecked: nothing independent of GPS to compare with"
                        explanation = "GNSS is self-consistent, but nothing independent of GNSS confirms it, so a slow or shared (common-mode) error would go unnoticed." +
                            (if (dependentAgree) " Peers agree, but their positions come from GNSS too, so their agreement is not verification." else "")
                    }
                }
                GNSSIntegrityStatus.degraded -> {
                    summary = objection ?: "GPS quality is low"
                    explanation = "Usable with a wider uncertainty: ${objection ?: "quality is low"}."
                }
                GNSSIntegrityStatus.suspect, GNSSIntegrityStatus.rejected -> {
                    if (objection != null) {
                        summary = "$objection; not proof of an attack"
                        explanation = "Anomaly: " + outcomes.filter { it.evidence.score < suspectBelow }
                            .joinToString("; ") { it.evidence.detail } +
                            ". This shows inconsistent GNSS, not its cause: ${describe(causes)} could each produce it."
                    } else {
                        summary = "GPS consistent again; trust recovering"
                        explanation = "The checks pass again, but trust climbs back only slowly after an anomaly."
                    }
                }
                GNSSIntegrityStatus.unavailable -> {
                    summary = "No usable GPS fix"
                    explanation = "$summary."
                }
            }
            return clipped(summary) to explanation
        }

        private fun describe(causes: List<GNSSPossibleCause>): String =
            if (causes.isEmpty()) "unknown" else causes.joinToString(", ") { it.rawValue }

        /** The contract's text limit, in UTF-16 units (Kotlin string length). Cuts between characters. */
        internal fun clipped(text: String, limit: Int = 160): String {
            if (text.length <= limit) return text
            val result = StringBuilder()
            val characters = BreakIterator.getCharacterInstance()
            characters.setText(text)
            var start = characters.first()
            var end = characters.next()
            while (end != BreakIterator.DONE) {
                val character = text.substring(start, end)
                if (result.length + character.length > limit - 1) break
                result.append(character)
                start = end
                end = characters.next()
            }
            return result.toString() + "…"
        }

        internal fun biasFraction(options: Options): Double =
            hypot(sin(options.inertialHeadingBias * PI / 180), options.inertialScaleBias)

        /**
         * Distance from the GNSS displacement `g` to the set of vectors s·R(θ)·i with |θ| ≤ maxAngle
         * and |s − 1| ≤ maxScale: what is left of it once the inertial displacement `i` is allowed its
         * heading and step-length bias.
         */
        internal fun distanceOutsideBias(gx: Double, gz: Double, ix: Double, iz: Double, maxAngle: Double,
                                         maxScale: Double): Double {
            val length = hypot(ix, iz)
            val g = hypot(gx, gz)
            val inner = (1 - maxScale) * length
            val outer = (1 + maxScale) * length
            if (length < 1e-9) return g
            if (g < 1e-9) return inner
            var delta = atan2(gx, gz) - atan2(ix, iz)
            delta = abs(atan2(sin(delta), cos(delta)))
            if (delta <= maxAngle) return maxOf(0.0, inner - g, g - outer)
            val beyond = delta - maxAngle
            val along = min(outer, max(inner, g * cos(beyond)))
            return sqrt(max(0.0, g * g + along * along - 2 * g * along * cos(beyond)))
        }

        internal fun ramp(x: Double, points: List<Pair<Double, Double>>): Double {
            val first = points.firstOrNull() ?: return 1.0
            val last = points.last()
            if (x <= first.first) return first.second
            for ((a, b) in points.zipWithNext()) {
                if (x <= b.first) return a.second + (b.second - a.second) * (x - a.first) / (b.first - a.first)
            }
            return last.second
        }

        internal fun clamp01(value: Double): Double = max(0.0, min(1.0, value))

        internal fun distance(a: FloorPoint, b: FloorPoint): Double = hypot(a.x - b.x, a.z - b.z)

        internal fun meters(value: Double): String =
            if (value >= 1000) "${format1(value / 1000)} km" else "${swiftRounded(value).toLong()} m"

        internal fun seconds(value: Double): String =
            if (value >= 120) "${swiftRounded(value / 60).toLong()} min"
            else if (value < 10) "${format1(value)} s"
            else "${swiftRounded(value).toLong()} s"

        internal fun speed(value: Double): String = "${swiftRounded(value * 3.6).toLong()} km/h"

        /**
         * `String(format: "%.1f", value)`: C printf rounds the exact binary value half to even, which
         * Java's formatter does not (it rounds the shortest decimal half up).
         */
        internal fun format1(value: Double): String {
            if (!value.isFinite()) return if (value.isNaN()) "nan" else if (value > 0) "inf" else "-inf"
            val text = BigDecimal(value).setScale(1, RoundingMode.HALF_EVEN).toPlainString()
            return if (value < 0 || (value == 0.0 && 1 / value < 0)) {
                if (text.startsWith("-")) text else "-$text"
            } else text
        }
    }
}

// MARK: - GhostCore contract

/**
 * GNSSIntegrityEngine behind the GhostCore contract (ARCHITECTURE.md): raw fixes, motion and
 * peer records come in as contract types, `IntegrityAssessment`s go out. Per pipeline step,
 * ingest motion, peers and this phone's own estimate first, then assess.
 *
 * The `GhostIntegrityEngine` conformance (EngineConformance.swift on iOS) is declared here, since
 * Kotlin cannot add an interface to a class from another file.
 */
class GNSSIntegrityMonitor(
    val subjectId: String,
    val frameId: String = GeoFrame.defaultFrameId,
    options: GNSSIntegrityEngine.Options = GNSSIntegrityEngine.Options.pedestrian,
    val radio: RadioModel = RadioModel.outdoors,
) : GhostIntegrityEngine {
    val engine: GNSSIntegrityEngine = GNSSIntegrityEngine(options)

    var latest: IntegrityAssessment? = null
        private set

    /**
     * The engine's own assessment behind `latest`, with what the contract record leaves out
     * (possible causes, explanation, recommended sigma).
     */
    var latestDetail: GNSSIntegrityAssessment? = null
        private set

    private val pendingFixes = ArrayList<PositionEstimate>()
    private var judgedFix: PositionEstimate? = null
    private var lastSimulatedInput: Double? = null

    /**
     * 95 % radius to draw around this phone's GNSS position when it is shown (trusted, or
     * "GPS (unchecked)"); null when it must not be shown as a position.
     */
    val displayR95: Double?
        get() = latestDetail?.uncertainty?.recommendedSigma?.let { PositionUncertainty.r95(fromSigma = it) }

    // MARK: Inputs

    /** Queues a raw fix (method gnss, this phone); it is judged at the next assess. */
    override fun ingest(fix: PositionEstimate) {
        if (!(fix.subjectId == subjectId && fix.frameId == frameId && fix.kind == PositionEstimate.Kind.measured &&
                fix.method == PositionEstimate.Method.gnss && fix.position != null)) return
        if (pendingFixes.size == 16) pendingFixes.removeAt(0)
        pendingFixes.add(fix)
    }

    override fun ingest(motion: MotionObservation) {
        if (!(motion.subjectId == subjectId && motion.frameId == frameId)) return
        val displacement = motion.displacement ?: (if (motion.stationary) FloorVector(x = 0.0, z = 0.0) else null) ?: return
        val sigma = motion.uncertainty.displacementR95?.let { it / PositionUncertainty.sigmaTo95 }
            ?: (0.1 + 0.05 * displacement.length)
        engine.addMotion(InertialDisplacement(start = motion.timestamp - motion.interval, end = motion.timestamp,
            dx = displacement.x, dz = displacement.z, sigma = max(sigma, 0.02), stationary = motion.stationary))
        noteSimulated(motion.provenance, motion.timestamp)
    }

    /**
     * A peer this phone hears directly, with that peer's latest position: being heard bounds how
     * far apart the two can be. Skipped when the peer's own GNSS is suspect or rejected, when its
     * position came from this phone (circular), or when it is only a prediction.
     */
    fun ingest(peer: PeerObservation, peerPosition: PositionEstimate, peerStatus: IntegrityAssessment.Status? = null) {
        val observation = peer
        val peerId = observation.peerId ?: return
        if (!(observation.observerId == subjectId && peerPosition.subjectId == peerId &&
                observation.frameId == frameId && peerPosition.frameId == frameId &&
                observation.linkState != PeerObservation.LinkState.lost)) return
        val position = peerPosition.position ?: return
        if (peerPosition.kind !in listOf(PositionEstimate.Kind.measured, PositionEstimate.Kind.estimated,
                PositionEstimate.Kind.declared)) return
        if (peerPosition.provenance.contains(subjectId)) return
        val rssi = observation.smoothedRSSI ?: median(observation.rawRSSI) ?: return
        if (peerStatus != null && (peerStatus == IntegrityAssessment.Status.suspect ||
                peerStatus == IntegrityAssessment.Status.rejected)) return
        engine.addPeer(PeerProximity(
            time = observation.timestamp, peerId = peerId, peerPosition = FloorPoint(x = position.x, z = position.z),
            peerSigma = peerPosition.uncertainty.r95 / PositionUncertainty.sigmaTo95,
            origin = if (peerPosition.provenance.gnssDependent) EvidenceOrigin.gnssDerived else EvidenceOrigin.surveyed,
            maxRange = PeerProximity.maxRange(rssi = rssi, radio = radio)))
        noteSimulated(observation.provenance, observation.timestamp)
        noteSimulated(peerPosition.provenance, observation.timestamp)
    }

    /**
     * This phone placed another way (Bluetooth estimate, UWB, dead reckoning, a declared landmark).
     * gnssDependent false makes it independent evidence. Skipped: a ring, and anything built from
     * this phone's own GNSS, which would judge the fix by itself. That covers an input `gnss` naming
     * this phone, an unnamed `gnss` input when this phone produced the estimate (the positioning
     * engine records its own fix that way), and an estimate of this phone's own making that depends
     * on GNSS without any peer: its own earlier fixes carried by motion, which the jump and
     * inertial checks already cover.
     *
     * Swift `ingest(ownEstimate:)`: renamed because Kotlin cannot overload `ingest(fix:)` (also a
     * `PositionEstimate`) by parameter name.
     */
    fun ingestOwnEstimate(estimate: PositionEstimate) {
        val provenance = estimate.provenance
        val peers = (provenance.contributors + provenance.inputs.mapNotNull { it.id }).toSet() - subjectId
        val ownGNSS = provenance.inputs.any {
            it.source == EvidenceSource.gnss && it.used &&
                (it.id == subjectId || (it.id == null && provenance.producerId == subjectId))
        }
        val position = estimate.position ?: return
        if (!(estimate.subjectId == subjectId && estimate.frameId == frameId &&
                estimate.method != PositionEstimate.Method.gnss &&
                estimate.kind in listOf(PositionEstimate.Kind.measured, PositionEstimate.Kind.estimated,
                    PositionEstimate.Kind.declared) &&
                !estimate.uncertainty.ambiguous && !ownGNSS && (peers.isNotEmpty() || !provenance.gnssDependent))) return
        engine.addPositionEvidence(PositionEvidence(
            time = estimate.timestamp, position = FloorPoint(x = position.x, z = position.z),
            sigma = max(estimate.uncertainty.r95 / PositionUncertainty.sigmaTo95, 0.5),
            origin = if (provenance.gnssDependent) EvidenceOrigin.gnssDerived else EvidenceOrigin.surveyed,
            sources = provenance.contributors.take(4), fromPeers = peers.isNotEmpty()))
        noteSimulated(provenance, estimate.timestamp)
    }

    // MARK: Assessment

    /** Judges a new raw fix (and any queued before it). */
    fun assess(fix: PositionEstimate, now: Double): IntegrityAssessment {
        ingest(fix = fix)
        return assess(now = now)
    }

    /** Judges queued fixes, or re-judges the latest one when none arrived (fixes go stale). */
    fun assess(now: Double): IntegrityAssessment {
        var result: Pair<GNSSIntegrityAssessment, PositionEstimate>? = null
        for (fix in pendingFixes) {
            val position = fix.position ?: continue
            noteSimulated(fix.provenance, fix.timestamp)
            val velocity = fix.velocity
            val speed = velocity?.length
            var course = velocity?.let { atan2(it.x, it.z) * 180 / PI }
            if (course != null && course < 0) course += 360
            if (speed != null && speed < 0.3) course = -1.0
            val native = engine.assess(GNSSFix(
                time = fix.timestamp, position = FloorPoint(x = position.x, z = position.z),
                accuracy = fix.uncertainty.r95 * PositionUncertainty.sigmaTo68 / PositionUncertainty.sigmaTo95,
                speed = speed, course = course), now)
            if (fix.timestamp >= (judgedFix?.timestamp ?: Double.NEGATIVE_INFINITY)) judgedFix = fix
            result = native to fix
        }
        pendingFixes.clear()
        if (result != null) return record(result.first, result.second, now)
        return record(engine.assess(now), judgedFix, now)
    }

    // MARK: GhostIntegrityEngine (the pipeline's protocol)

    /** `evidence`: estimates of this phone made without its GNSS, judged as by `ingestOwnEstimate`. */
    override fun assess(subjectId: String, evidence: List<PositionEstimate>, now: Double): IntegrityAssessment {
        if (subjectId != this.subjectId) {
            return IntegrityAssessment(
                subjectId = subjectId, timestamp = now, frameId = frameId, status = IntegrityAssessment.Status.unavailable,
                trustScore = 0.0, uncertainty = IntegrityAssessment.TrustInterval(lower = 0.0, upper = 0.0),
                reasons = listOf(IntegrityAssessment.Reason.noFix),
                summary = "No GPS fix", freshness = Freshness(maxAge = maxAge),
                provenance = Provenance(producerId = subjectId, algorithm = algorithm, gnssDependent = true),
            )
        }
        evidence.forEach { ingestOwnEstimate(it) }
        return assess(now = now)
    }

    private fun record(native: GNSSIntegrityAssessment, evaluated: PositionEstimate?, now: Double): IntegrityAssessment {
        val status = IntegrityAssessment.Status.entries.firstOrNull { it.rawValue == native.status.rawValue }
            ?: IntegrityAssessment.Status.unavailable
        val fix = if (status == IntegrityAssessment.Status.unavailable) null else evaluated
        val checks = native.evidence.map { it.check }.toSet()
        val inputs = mutableListOf<ProvenanceInput>()
        if (evaluated != null) {
            inputs.add(ProvenanceInput(source = EvidenceSource.gnss, id = subjectId, age = max(0.0, now - evaluated.timestamp),
                used = fix != null))
        }
        if (GNSSCheck.inertial in checks) inputs.add(ProvenanceInput(source = EvidenceSource.inertial, id = subjectId))
        if (GNSSCheck.peerProximity in checks || GNSSCheck.anchorProximity in checks) {
            inputs.add(ProvenanceInput(source = EvidenceSource.bluetooth))
        }
        if (GNSSCheck.positionEvidence in checks) inputs.add(ProvenanceInput(source = EvidenceSource.fusion))
        val simulated = (evaluated?.provenance?.simulated ?: false) ||
            (lastSimulatedInput?.let { now - it <= engine.options.history } ?: false)
        val trust = GNSSIntegrityEngine.clamp01(native.trustScore)
        val assessment = IntegrityAssessment(
            subjectId = subjectId, timestamp = now, frameId = frameId, status = status, trustScore = trust,
            uncertainty = IntegrityAssessment.TrustInterval(lower = min(trust, max(0.0, native.uncertainty.trustLower)),
                upper = trust),
            reasons = native.reasons.mapNotNull { reason ->
                IntegrityAssessment.Reason.entries.firstOrNull { it.rawValue == reason.rawValue }
            },
            evidence = native.evidence.take(GhostCoreContract.maxEvidence).map { item ->
                IntegrityAssessment.Evidence(
                    check = item.check.rawValue, observed = if (item.observed.isFinite()) item.observed else null,
                    threshold = if (item.threshold.isFinite()) item.threshold else null, unit = item.unit,
                    score = GNSSIntegrityEngine.clamp01(item.score), independent = item.independent,
                    reason = item.reason?.let { reason ->
                        IntegrityAssessment.Reason.entries.firstOrNull { it.rawValue == reason.rawValue }
                    },
                )
            },
            evaluatedFix = fix,
            minimumDetectableOffsetMeters = native.uncertainty.minimumDetectableOffset?.let {
                if (it <= GhostCoreContract.maxRadius) it else null
            },
            summary = native.summary, source = EvidenceSource.fusion, freshness = Freshness(maxAge = maxAge),
            provenance = Provenance(producerId = subjectId, algorithm = algorithm, inputs = inputs,
                gnssDependent = true, simulated = simulated),
        )
        latest = assessment
        latestDetail = native
        return assessment
    }

    private fun noteSimulated(provenance: Provenance, time: Double) {
        if (provenance.simulated) lastSimulatedInput = max(lastSimulatedInput ?: time, time)
    }

    companion object {
        const val algorithm = "gnss-integrity@1"

        /** An assessment stays usable this long once handed on, seconds. */
        const val maxAge = 5.0


        private fun median(values: List<Double>): Double? {
            if (values.isEmpty()) return null
            val sorted = values.sorted()
            val middle = sorted.size / 2
            return if (sorted.size % 2 == 1) sorted[middle] else (sorted[middle - 1] + sorted[middle]) / 2
        }
    }
}
