package com.hackathonmapper.meshcore

import com.hackathonmapper.meshcore.Positioning as PZ
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

// Swift declares `typealias PZ = Positioning` here for the whole test module. Kotlin cannot reach
// nested types through a type alias, so each test file imports `Positioning as PZ` instead.

/** SplitMix64: repeatable synthetic worlds. Bit-exact with the Swift `SimRandom`. */
class SimRandom(seed: ULong) {
    private var state: ULong = seed * 0x9E3779B97F4A7C15uL + 1uL

    fun next(): Double {
        state += 0x9E3779B97F4A7C15uL
        var z = state
        z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9uL
        z = (z xor (z shr 27)) * 0x94D049BB133111EBuL
        z = z xor (z shr 31)
        return (z shr 11).toDouble() / (1uL shl 53).toDouble()
    }

    fun gauss(): Double {
        val u = max(next(), 1e-12)
        return sqrt(-2 * ln(u)) * cos(2 * PI * next())
    }

    fun uniform(a: Double, b: Double): Double = a + (b - a) * next()
}

/**
 * A synthetic walk with every sensor the engine reads, generated from a known true track. The
 * "true" radio deliberately differs from the engine's default model (p0, n, per-phone offsets,
 * correlated shadowing, deep fades, body blocking), so the tests do not grade the model on its
 * own assumptions.
 */
class SyntheticWalk {
    data class AnchorSpec(
        var id: String,
        var position: PZ.Vec2,
        var kind: PZ.Anchor.Kind = PZ.Anchor.Kind.gnss,
        /** Sigma the anchor reports (5 m GNSS accuracy -> 3.3 m per axis). */
        var reportedSigma: Double = 3.3,
        /** Its actual position error (GNSS wander), per axis. */
        var trueErrorSigma: Double = 2.5,
        /** Its radio reads this many dB stronger or weaker than the model. */
        var rssiOffset: Double = 0.0,
    )

    data class Disturbance(
        var center: PZ.Vec2,
        var radius: Double,
        var bias: Double,
        /** Whether the field-strength check notices it. */
        var flagged: Boolean,
    )

    /** Swift's `(start: TimeInterval, duration: TimeInterval)` tuple. */
    data class Pause(val start: Double, val duration: Double)

    var seed: ULong = 1uL
    var duration: Double = 720.0
    /** GNSS fixes stop after this time (nil: GNSS throughout; 0: never). */
    var gnssUntil: Double? = 120.0
    var start = PZ.Vec2(x = 0.0, z = 0.0)
    var waypoints: List<PZ.Vec2> = listOf(PZ.Vec2(x = 80.0, z = 0.0), PZ.Vec2(x = 80.0, z = 60.0), PZ.Vec2(x = 0.0, z = 60.0), PZ.Vec2(x = 0.0, z = 0.0))
    var loop = true
    var pauses: List<Pause> = listOf(Pause(300.0, 20.0), Pause(500.0, 15.0))
    var initialHeading = PI / 2

    var imuRate = 50.0
    var stepFrequency = 1.8
    var strideLength = 0.74
    /**
     * Relative 1-sigma of slow stride changes (speeding up, slowing down) the accelerometer
     * amplitude does not reveal, with a 20 s time constant.
     */
    var strideVariation = 0.0
    var accelAmplitude = 0.3
    var carryOffset = PZ.degrees(8.0)
    var gyroBias = PZ.degrees(0.2)
    var gyroNoise = 0.01
    var withMotion = true

    var withCompass = true
    var compassRate = 10.0
    var compassNoise = PZ.degrees(5.0)
    var compassReportedSigma = PZ.degrees(8.0)
    var disturbances: List<Disturbance> = listOf(Disturbance(center = PZ.Vec2(x = 80.0, z = 30.0), radius = 12.0, bias = PZ.degrees(35.0), flagged = false))

    var gnssWhite = 1.5
    var gnssCorrelated = 3.0
    var gnssTau = 30.0
    var gnssReportedAccuracy = 5.0

    var anchors: List<AnchorSpec> = emptyList()
    var anchorReportLatency = 1.0
    var radioP0 = -58.0
    var radioN = 2.3
    var shadowSigma = 4.5
    var shadowDecorrelation = 5.0
    var fastSigma = 3.0
    var deepFadeProbability = 0.08
    var bodyLoss = 5.0
    var hearRange = 55.0
    var hearSoft = 6.0
    var advertisementRate = 5.0
    var sensitivity = -100.0

    var truthRate = 2.0

    data class Output(
        var records: List<PZ.LogRecord>,
        var truth: List<PZ.Replay.TruthSample>,
    )

    companion object {
        fun fourCornerAnchors(seed: ULong): List<AnchorSpec> {
            val r = SimRandom(seed = seed + 99uL)
            return listOf(Triple("anchor-s", 40.0, -8.0), Triple("anchor-e", 88.0, 30.0), Triple("anchor-n", 40.0, 68.0), Triple("anchor-w", -8.0, 30.0)).map {
                AnchorSpec(id = it.first, position = PZ.Vec2(x = it.second, z = it.third), rssiOffset = 2 * r.gauss())
            }
        }
    }

    fun generate(): Output {
        val rng = SimRandom(seed = seed)
        val records = ArrayList<PZ.LogRecord>()
        records.add(PZ.LogRecord.header(selfId = "phone-b", frameId = "hervanta-v1", note = "synthetic seed $seed"))
        val truth = ArrayList<PZ.Replay.TruthSample>()

        var pos = start
        var theta = initialHeading
        var target = 0
        var phase = 0.0
        var walkedTotal = 0.0
        val dt = 1 / imuRate
        var prevDevice = theta - carryOffset
        var nextCompass = 0.0
        var nextGNSS = 0.0
        var nextTruth = 0.0
        var nextReport = 0.0
        var gnssError = PZ.Vec2(x = gnssCorrelated * rng.gauss(), z = gnssCorrelated * rng.gauss())
        val anchorErrors = anchors.map { a -> PZ.Vec2(x = a.trueErrorSigma * rng.gauss(), z = a.trueErrorSigma * rng.gauss()) }.toMutableList()
        val shadow = anchors.map { shadowSigma * rng.gauss() }.toMutableList()
        val shadowWalked = anchors.map { 0.0 }.toMutableList()
        val nextAdvert = anchors.indices.map { it.toDouble() / (advertisementRate * max(1, anchors.size).toDouble()) }.toMutableList()
        var done = false
        var strideFactor = 1.0

        var t = 0.0
        while (t <= duration) {
            val paused = pauses.any { t >= it.start && t < it.start + it.duration }
            var speed = 0.0
            if (!paused && !done) {
                val goal = waypoints[target]
                val to = goal - pos
                if (to.length < 1.5) {
                    if (target + 1 < waypoints.size) target += 1 else if (loop) target = 0 else done = true
                }
                val desired = atan2(to.x, to.z)
                val turn = PZ.wrap(desired - theta)
                val maxTurn = PZ.degrees(120.0) * dt
                theta = PZ.wrap(theta + max(-maxTurn, min(maxTurn, turn)))
                if (strideVariation > 0) {
                    val a = exp(-dt / 20)
                    strideFactor = 1 + a * (strideFactor - 1) + sqrt(1 - a * a) * strideVariation * rng.gauss()
                }
                speed = if (done) 0.0 else stepFrequency * strideLength * max(0.5, strideFactor)
            }
            val moved = speed * dt
            pos = pos + PZ.Vec2.heading(theta) * moved
            walkedTotal += moved
            if (speed > 0) phase += 2 * PI * stepFrequency * dt

            val device = theta - carryOffset + PZ.degrees(2.0) * sin(phase / 2)
            val rate = PZ.wrap(device - prevDevice) / dt
            prevDevice = device

            if (withMotion) {
                val pitch = PZ.degrees(3.0) * sin(phase)
                val up = PZ.Vec3(0.0, sin(pitch), cos(pitch))
                val accelNoise = if (speed > 0) 0.02 else 0.003
                val vertical = if (speed > 0) accelAmplitude * sin(phase) else 0.0
                val accel = up.scaled(vertical) + PZ.Vec3(accelNoise * rng.gauss(), accelNoise * rng.gauss(), accelNoise * rng.gauss())
                val gyroNoiseNow = if (speed > 0) gyroNoise else gyroNoise / 4
                val omega = up.scaled(-(rate + gyroBias)) +
                    PZ.Vec3(gyroNoiseNow * rng.gauss(), gyroNoiseNow * rng.gauss(), gyroNoiseNow * rng.gauss())
                records.add(PZ.LogRecord.motion(sample = PZ.MotionSample(t = t, gravity = up.scaled(-1.0), userAcceleration = accel, rotationRate = omega)))
            }

            if (withCompass && t >= nextCompass) {
                nextCompass += 1 / compassRate
                var heading = device + compassNoise * rng.gauss()
                var disturbed = false
                for (d in disturbances) {
                    if (!(pos.distance(to = d.center) < d.radius)) continue
                    heading += d.bias
                    disturbed = disturbed || d.flagged
                }
                records.add(PZ.LogRecord.compass(sample = PZ.CompassSample(t = t, heading = PZ.wrap(heading), sigma = compassReportedSigma, disturbed = disturbed)))
            }

            if (t >= nextGNSS) {
                nextGNSS += 1
                val a = exp(-1 / gnssTau)
                val b = sqrt(1 - a * a) * gnssCorrelated
                gnssError = PZ.Vec2(x = a * gnssError.x + b * rng.gauss(), z = a * gnssError.z + b * rng.gauss())
                for (i in anchorErrors.indices) {
                    val s = anchors[i].trueErrorSigma
                    anchorErrors[i] = PZ.Vec2(
                        x = a * anchorErrors[i].x + sqrt(1 - a * a) * s * rng.gauss(),
                        z = a * anchorErrors[i].z + sqrt(1 - a * a) * s * rng.gauss(),
                    )
                }
                if (gnssUntil?.let { t < it } ?: true) {
                    val measured = pos + gnssError + PZ.Vec2(x = gnssWhite * rng.gauss(), z = gnssWhite * rng.gauss())
                    val course = if (speed > 0.5) PZ.wrap(theta + PZ.degrees(4.0) * rng.gauss()) else null
                    records.add(
                        PZ.LogRecord.gnss(
                            fix = PZ.GNSSFix(
                                t = t, position = measured, horizontalAccuracy = gnssReportedAccuracy,
                                course = course, courseSigma = if (course == null) null else PZ.degrees(8.0),
                                speed = speed, trusted = true,
                            ),
                        ),
                    )
                }
            }

            if (t >= nextReport) {
                nextReport += 1
                for ((i, a) in anchors.withIndex()) {
                    val reported = if (a.kind == PZ.Anchor.Kind.gnss) a.position + anchorErrors[i] else a.position
                    records.add(
                        PZ.LogRecord.anchor(
                            anchor = PZ.Anchor(
                                id = a.id, position = reported, sigma = a.reportedSigma, kind = a.kind,
                                measuredAt = t - anchorReportLatency, timeSigma = 0.5,
                                speedBound = if (a.kind == PZ.Anchor.Kind.surveyed) 0.0 else 1.5,
                                gnssDependent = a.kind == PZ.Anchor.Kind.gnss,
                            ),
                        ),
                    )
                }
            }

            for (i in anchors.indices) {
                if (!(t >= nextAdvert[i])) continue
                nextAdvert[i] += 1 / advertisementRate
                val a = anchors[i]
                val d = pos.distance(to = a.position)
                val hear = 1 / (1 + exp((d - hearRange) / hearSoft))
                if (!(rng.next() < hear)) continue
                val rho = exp(-(walkedTotal - shadowWalked[i]) / shadowDecorrelation)
                shadow[i] = rho * shadow[i] + sqrt(1 - rho * rho) * shadowSigma * rng.gauss()
                shadowWalked[i] = walkedTotal
                var rssi = radioP0 + a.rssiOffset - 10 * radioN * log10(max(0.5, d)) + shadow[i] + fastSigma * rng.gauss()
                if (rng.next() < deepFadeProbability) rssi -= rng.uniform(5.0, 20.0)
                val bearing = atan2(a.position.x - pos.x, a.position.z - pos.z)
                if (abs(PZ.wrap(bearing - theta)) > PZ.degrees(110.0)) rssi -= bodyLoss
                rssi = swiftRounded(rssi)
                if (!(rssi >= sensitivity)) continue
                records.add(PZ.LogRecord.rssi(sample = PZ.RSSISample(peerId = a.id, rssi = rssi, t = t, channel = PZ.RSSIChannel.advertisement)))
            }

            if (t >= nextTruth) {
                nextTruth += 1 / truthRate
                truth.add(PZ.Replay.TruthSample(t, pos))
                records.add(PZ.LogRecord.truth(position = pos, t = t))
            }
            t += dt
        }
        return Output(records = records, truth = truth)
    }
}

/**
 * Hold-last-fix baseline (what the app showed before): the last trusted fix, with a circle growing
 * at walking pace.
 */
object HoldLastBaseline {
    fun run(records: List<PZ.LogRecord>, every: Double = 1.0, end: Double): List<PZ.ReplayEpoch> {
        val fixes = records.mapNotNull { r -> if (r is PZ.LogRecord.gnss && r.fix.trusted) r.fix else null }
        val truth = records.mapNotNull { r -> if (r is PZ.LogRecord.truth) PZ.Replay.TruthSample(r.t, r.position) else null }
        val epochs = ArrayList<PZ.ReplayEpoch>()
        var t = 1.0
        while (t <= end) {
            val fix = fixes.lastOrNull { it.t <= t }
            if (fix != null) {
                val age = t - fix.t
                val r95 = PositionUncertainty.r95(fromRadius68 = fix.horizontalAccuracy) + 1.4 * age
                val e = PZ.Estimate(
                    method = if (age <= 3) PZ.Estimate.Method.gnss else PZ.Estimate.Method.deadReckoning, frameId = "hervanta-v1",
                    t = t, position = fix.position, regionCenter = fix.position,
                    covariance = PZ.Covariance2.isotropic(sigma = r95 / PZ.Stats.r95PerSigma), r95 = r95,
                    candidates = emptyList(), heading = null, headingSigma = null, lastAbsoluteAt = fix.t, lastTrustedGNSS = fix,
                    anchorIds = emptyList(), gnssDependent = true, provenance = emptyList(), flags = emptyList(),
                )
                epochs.add(PZ.Replay.score(e, truth = PZ.Replay.interpolate(truth, at = t)))
            }
            t += every
        }
        return epochs
    }
}
