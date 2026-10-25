package com.hackathonmapper.meshcore

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

// Deterministic synthetic GNSS faults for testing GNSSIntegrityEngine. Faults are applied to the
// fixes the app hands to the engine (application data), never to a radio: nothing here transmits
// or needs a GNSS simulator, and the same seed always replays the same run.
//
// A run builds one simulated world per scenario and seed (a walker with pauses and turns, GNSS with
// time-correlated error, dead reckoning with heading and step-length bias, peers walking alongside
// with their own GNSS, surveyed beacons, Bluetooth RSSI) and then replays that same world through
// each detector configuration, so configurations are compared on identical data.
//
// Port of ios/MeshCore/Sources/MeshCore/GNSSFaultInjection.swift.

/**
 * mulberry32: small and identical on every platform, so a seed replays the same run.
 * A Swift value type with mutating methods: copy with `copy()` where Swift copies.
 */
class DeterministicRandom(seed: UInt) {
    private var state: UInt = seed

    fun copy(): DeterministicRandom = DeterministicRandom(state)

    fun next(): Double {
        state += 0x6d2b79f5u
        var t = state
        t = (t xor (t shr 15)) * (t or 1u)
        t = t xor (t + ((t xor (t shr 7)) * (t or 61u)))
        return (t xor (t shr 14)).toDouble() / 4_294_967_296.0
    }

    fun gauss(): Double {
        val radius = sqrt(-2 * ln(max(next(), 1e-12)))
        return radius * cos(2 * PI * next())
    }

    fun uniform(low: Double, high: Double): Double = low + (high - low) * next()
}

sealed class GNSSFault {
    /** Position jumps by a fixed offset and stays there (teleport spoof, receiver relock). */
    data class jump(val dx: Double, val dz: Double) : GNSSFault()

    /** Fixes run away at a steady speed, with matching reported speed and course. */
    data class fakeTrack(val speed: Double, val course: Double) : GNSSFault()

    /** Fixes accelerate away from the true track. */
    data class acceleration(val rate: Double, val course: Double) : GNSSFault()

    /**
     * Position slides away slowly (drag-off spoof, slowly growing multipath); reported velocity
     * includes the slide, as a careful spoofer would make it.
     */
    data class slowDrift(val rate: Double, val course: Double) : GNSSFault()

    /** The receiver keeps reporting the position from the start of the fault with fresh timestamps. */
    data object frozenPosition : GNSSFault()

    /** Fixes arrive late, with their true (old) timestamps. */
    data class delayed(val by: Double) : GNSSFault()

    /** No fixes at all. */
    data object dropout : GNSSFault()

    /** Reported accuracy and noise grow for ten seconds, then fixes stop (jamming). */
    data object jamming : GNSSFault()

    /** Fixes recorded `lag` seconds earlier are played back with current timestamps (meaconing). */
    data class replay(val lag: Double) : GNSSFault()

    /**
     * Faults that place the phone somewhere wrong (rather than only taking GNSS away), which the
     * engine has to flag as anomalies.
     */
    val isIntegrityFault: Boolean
        get() = when (this) {
            is delayed, dropout, jamming -> false
            else -> true
        }
}

data class GNSSFaultInjection(
    var fault: GNSSFault,
    var start: Double,
    /** null: until the run ends. */
    var end: Double? = null,
    /**
     * Applies the same fault to every peer's GNSS as well: one spoofer, jammer or ionosphere
     * covering the whole group.
     */
    var commonMode: Boolean = false,
) {
    internal fun isActive(time: Double): Boolean = time >= start && (end?.let { time < it } ?: true)
}

data class GNSSScenario(
    var name: String,
    var duration: Int = 600,
    var injections: List<GNSSFaultInjection> = emptyList(),
    var motion: Motion = Motion.walk,
    var environment: Environment = Environment.openSky,
    var peerCount: Int = 3,
    /** Surveyed beacons, placed 15 m beside the route where the walker passes at these seconds. */
    var anchorsAt: List<Int> = emptyList(),
) {
    enum class Motion(val rawValue: String) {
        /** Walks with turns and occasional pauses. */
        walk("walk"),

        /** Stays where it is (the GPS anchor on a table). */
        still("still"),
    }

    /** How hard the sky is on GNSS when nothing is wrong. */
    enum class Environment(val rawValue: String) {
        /** 2.5 m per axis of slowly wandering error, accuracy reported honestly (about 4 m). */
        openSky("openSky"),

        /**
         * 5 m of wandering error plus multipath bursts: every few minutes the fix steps 10–35 m
         * aside for 8–25 s while the reported accuracy grows only by a third. No fault, but the
         * hardest clean case for false alarms.
         */
        urban("urban"),
    }

    /**
     * When the fault the engine should catch begins: the first integrity fault, or else the first
     * fault of any kind.
     */
    val detectionStart: Double?
        get() = (injections.firstOrNull { it.fault.isIntegrityFault } ?: injections.firstOrNull())?.start

    val expectsAnomaly: Boolean get() = injections.any { it.fault.isIntegrityFault }

    companion object {
        /** ARCHITECTURE.md section 10, S2: phone C's fixes offset by 400 m at once. */
        val jump400 = GNSSScenario("S2 jump 400 m",
            injections = listOf(GNSSFaultInjection(GNSSFault.jump(dx = 400.0, dz = 0.0), start = 240.0)))

        /** S3: C's offset grows 1 m/s, bearing 90°. */
        val drift1 = GNSSScenario("S3 drift 1 m/s",
            injections = listOf(GNSSFaultInjection(GNSSFault.slowDrift(rate = 1.0, course = 90.0), start = 240.0)))

        /** S4: the S3 offset (60 m after a minute) is removed again. */
        val recovery = GNSSScenario("S4 drift removed", injections = listOf(
            GNSSFaultInjection(GNSSFault.slowDrift(rate = 1.0, course = 90.0), start = 240.0, end = 300.0),
        ))

        /** The scenario library: clean runs for false alarms, then one per fault. */
        val library: List<GNSSScenario> = listOf(
            GNSSScenario("clean walk", duration = 900),
            GNSSScenario("clean, phone still", duration = 900, motion = Motion.still),
            GNSSScenario("clean walk, urban multipath", duration = 900, environment = Environment.urban),
            GNSSScenario("clean, still, urban multipath", duration = 900, motion = Motion.still,
                environment = Environment.urban),
            jump400, drift1, recovery,
            GNSSScenario("teleport 1 km",
                injections = listOf(GNSSFaultInjection(GNSSFault.jump(dx = 700.0, dz = -700.0), start = 240.0))),
            GNSSScenario("jump 50 m",
                injections = listOf(GNSSFaultInjection(GNSSFault.jump(dx = 35.0, dz = 35.0), start = 240.0))),
            GNSSScenario("fake track 15 m/s",
                injections = listOf(GNSSFaultInjection(GNSSFault.fakeTrack(speed = 15.0, course = 120.0), start = 240.0))),
            GNSSScenario("acceleration 8 m/s²",
                injections = listOf(GNSSFaultInjection(GNSSFault.acceleration(rate = 8.0, course = 200.0), start = 240.0))),
            GNSSScenario("slow drift 0.5 m/s", duration = 900,
                injections = listOf(GNSSFaultInjection(GNSSFault.slowDrift(rate = 0.5, course = 75.0), start = 240.0))),
            GNSSScenario("slow drift 0.2 m/s", duration = 900,
                injections = listOf(GNSSFaultInjection(GNSSFault.slowDrift(rate = 0.2, course = 75.0), start = 240.0))),
            GNSSScenario("very slow drift 0.05 m/s", duration = 900,
                injections = listOf(GNSSFaultInjection(GNSSFault.slowDrift(rate = 0.05, course = 75.0), start = 240.0))),
            GNSSScenario("slow drift 0.5 m/s, phone still", duration = 900,
                injections = listOf(GNSSFaultInjection(GNSSFault.slowDrift(rate = 0.5, course = 75.0), start = 240.0)),
                motion = Motion.still),
            GNSSScenario("frozen position",
                injections = listOf(GNSSFaultInjection(GNSSFault.frozenPosition, start = 240.0, end = 360.0))),
            GNSSScenario("replay 30 s old",
                injections = listOf(GNSSFaultInjection(GNSSFault.replay(lag = 30.0), start = 240.0))),
            GNSSScenario("fixes 15 s late",
                injections = listOf(GNSSFaultInjection(GNSSFault.delayed(by = 15.0), start = 240.0, end = 300.0))),
            GNSSScenario("dropout 60 s",
                injections = listOf(GNSSFaultInjection(GNSSFault.dropout, start = 240.0, end = 300.0))),
            GNSSScenario("jamming 60 s",
                injections = listOf(GNSSFaultInjection(GNSSFault.jamming, start = 240.0, end = 300.0))),
            GNSSScenario("jam 30 s, then 200 m offset", injections = listOf(
                GNSSFaultInjection(GNSSFault.dropout, start = 240.0, end = 270.0),
                GNSSFaultInjection(GNSSFault.jump(dx = 140.0, dz = 140.0), start = 270.0),
            )),
            GNSSScenario("common-mode jump 1 km", injections = listOf(
                GNSSFaultInjection(GNSSFault.jump(dx = 700.0, dz = -700.0), start = 240.0, commonMode = true))),
            GNSSScenario("common-mode drift 0.5 m/s", duration = 900, injections = listOf(
                GNSSFaultInjection(GNSSFault.slowDrift(rate = 0.5, course = 75.0), start = 240.0, commonMode = true))),
            GNSSScenario("common-mode drift 0.5 m/s, anchor at 600 s", duration = 900,
                injections = listOf(
                    GNSSFaultInjection(GNSSFault.slowDrift(rate = 0.5, course = 75.0), start = 240.0, commonMode = true)),
                anchorsAt = listOf(600)),
        )

        fun named(name: String): GNSSScenario? = library.firstOrNull { it.name == name }
    }
}

/** Which inputs a detector gets. The world is the same for all of them. */
data class GNSSDetectorConfig(
    var name: String,
    var useInertial: Boolean,
    var usePeers: Boolean,
    var useAnchors: Boolean,
    var options: GNSSIntegrityEngine.Options = GNSSIntegrityEngine.Options.pedestrian,
) {
    companion object {
        /** The fix's own consistency only: accuracy, age, timestamps, speed, acceleration, jumps. */
        val gnssOnly = GNSSDetectorConfig("GNSS only", useInertial = false, usePeers = false, useAnchors = false)

        /** Plus consensus with peers whose positions come from their own GNSS. */
        val peers = GNSSDetectorConfig("+ peers", useInertial = false, usePeers = true, useAnchors = false)

        /** Plus surveyed beacons, still without inertial motion. */
        val peersAndAnchors = GNSSDetectorConfig("+ peers + beacons", useInertial = false, usePeers = true, useAnchors = true)

        /** Plus inertial motion. */
        val inertial = GNSSDetectorConfig("+ inertial", useInertial = true, usePeers = false, useAnchors = false)

        /** Everything, surveyed beacons included. */
        val full = GNSSDetectorConfig("full", useInertial = true, usePeers = true, useAnchors = true)

        val all = listOf(gnssOnly, peers, peersAndAnchors, inertial, full)
    }
}

/** One simulated world: everything the app would have received, second by second. */
class GNSSSimulatedWorld(val scenario: GNSSScenario, val seed: UInt) {
    /** Index = second. Where the phone really is. */
    val truth: List<FloorPoint>

    /** The fix delivered in each second, after faults; null when none arrived. */
    val fixes: List<GNSSFix?>

    /** Dead-reckoning increment ending in each second (index 0 unused). */
    val motion: List<InertialDisplacement?>
    val peerReports: List<List<PeerProximity>>
    val anchorReports: List<List<PeerProximity>>

    /** RSSI (dBm) behind each report, same layout. */
    val peerRSSI: List<List<Double>>
    val anchorRSSI: List<List<Double>>

    init {
        val duration = scenario.duration
        val radio = RadioModel.outdoors

        val truth = route(seed, duration, scenario.motion)
        this.truth = truth
        val ownClean = cleanFixes(truth, seed + 1_000u, scenario.environment)
        fixes = (0..duration).map { second -> inject(scenario.injections, second, ownClean) }

        val noise = DeterministicRandom(seed + 2_000u)
        val headingBias = noise.uniform(-4.0, 4.0) * PI / 180
        val scale = 1 + noise.uniform(-0.03, 0.03)
        var headingWalk = 0.0
        val motion = mutableListOf<InertialDisplacement?>(null)
        for (second in 1..duration) {
            val dx = truth[second].x - truth[second - 1].x
            val dz = truth[second].z - truth[second - 1].z
            val start = (second - 1).toDouble()
            val end = second.toDouble()
            if (hypot(dx, dz) < 0.05) {
                motion.add(InertialDisplacement(start, end, dx = 0.0, dz = 0.0, sigma = 0.02, stationary = true))
                continue
            }
            headingWalk = max(-0.035, min(0.035, headingWalk + 0.005 * noise.gauss()))
            val angle = headingBias + headingWalk
            val rx = scale * (dx * cos(angle) + dz * sin(angle)) + 0.08 * noise.gauss()
            val rz = scale * (-dx * sin(angle) + dz * cos(angle)) + 0.08 * noise.gauss()
            motion.add(InertialDisplacement(start, end, dx = rx, dz = rz, sigma = 0.1 + 0.05 * hypot(dx, dz)))
        }
        this.motion = motion

        val peerReports = List(duration + 1) { mutableListOf<PeerProximity>() }
        val peerRSSI = List(duration + 1) { mutableListOf<Double>() }
        val commonMode = scenario.injections.filter { it.commonMode }
        for (peer in 0 until scenario.peerCount) {
            val layout = DeterministicRandom(seed + 3_000u + peer.toUInt())
            val radius = layout.uniform(8.0, 35.0)
            val phase = layout.uniform(0.0, 2 * PI)
            val rate = layout.uniform(-0.01, 0.01)
            val peerTruth = truth.mapIndexed { second, point ->
                val angle = phase + rate * second.toDouble()
                FloorPoint(x = point.x + radius * sin(angle), z = point.z + radius * cos(angle))
            }
            val peerClean = cleanFixes(peerTruth, seed + 4_000u + peer.toUInt(), scenario.environment)
            val hearing = DeterministicRandom(seed + 5_000u + peer.toUInt())
            for (second in 1..duration) {
                val distance = hypot(peerTruth[second].x - truth[second].x, peerTruth[second].z - truth[second].z)
                val heard = hearing.next() <= radio.hearProbability(distance)
                val rssi = radio.expectedRSSI(distance) + radio.sigma * 0.8 * hearing.gauss()
                if (!heard) continue
                val fix = inject(commonMode, second, peerClean) ?: continue
                peerReports[second].add(PeerProximity(
                    time = second.toDouble(), peerId = "peer-$peer", peerPosition = fix.position, peerSigma = fix.sigma,
                    origin = EvidenceOrigin.gnssDerived, maxRange = PeerProximity.maxRange(rssi = rssi, radio = radio)))
                peerRSSI[second].add(rssi)
            }
        }
        this.peerReports = peerReports.map { it.toList() }
        this.peerRSSI = peerRSSI.map { it.toList() }

        val anchorReports = List(duration + 1) { mutableListOf<PeerProximity>() }
        val anchorRSSI = List(duration + 1) { mutableListOf<Double>() }
        val hearing = DeterministicRandom(seed + 6_000u)
        for ((index, at) in scenario.anchorsAt.withIndex()) {
            if (!(at > 0 && at <= duration)) continue
            val dx = truth[at].x - truth[at - 1].x
            val dz = truth[at].z - truth[at - 1].z
            val length = max(hypot(dx, dz), 1e-9)
            val anchor = FloorPoint(x = truth[at].x + 15 * dz / length, z = truth[at].z - 15 * dx / length)
            for (second in 1..duration) {
                val distance = hypot(anchor.x - truth[second].x, anchor.z - truth[second].z)
                if (!(hearing.next() <= radio.hearProbability(distance))) continue
                val rssi = radio.expectedRSSI(distance) + radio.sigma * 0.8 * hearing.gauss()
                anchorReports[second].add(PeerProximity(
                    time = second.toDouble(), peerId = "anchor-$index", peerPosition = anchor, peerSigma = 1.0,
                    origin = EvidenceOrigin.surveyed, maxRange = PeerProximity.maxRange(rssi = rssi, radio = radio)))
                anchorRSSI[second].add(rssi)
            }
        }
        this.anchorReports = anchorReports.map { it.toList() }
        this.anchorRSSI = anchorRSSI.map { it.toList() }
    }

    /**
     * One second of the world as the GhostCore pipeline would receive it: this phone's raw fix
     * (after faults) and motion, and each heard peer or beacon with its position. Every record is
     * marked simulated.
     */
    data class ContractInputs(
        val fix: PositionEstimate?,
        val motion: MotionObservation?,
        val peers: List<Peer>,
    ) {
        /** Swift's `(observation: PeerObservation, position: PositionEstimate)` tuple. */
        data class Peer(val observation: PeerObservation, val position: PositionEstimate)
    }

    /**
     * `epoch` is the Unix time of second 0. A fix outside the frame's coordinate limit is dropped,
     * as the app would never produce it.
     */
    fun contractInputs(second: Int, subjectId: String = "phone-c", frameId: String = GeoFrame.defaultFrameId,
                       epoch: Double = 1_793_000_000.0): ContractInputs {
        fun provenance(producer: String, gnss: Boolean): Provenance =
            Provenance(producerId = producer, algorithm = "gnss-harness@1", gnssDependent = gnss, simulated = true)
        fun inFrame(point: FloorPoint): Boolean =
            abs(point.x) <= GhostCoreContract.maxCoordinate && abs(point.z) <= GhostCoreContract.maxCoordinate

        var fix: PositionEstimate? = null
        val raw = fixes[second]
        if (raw != null && inFrame(raw.position)) {
            val velocity = raw.velocity?.let { if (hypot(it.x, it.z) <= 100) FloorVector(x = it.x, z = it.z) else null }
            fix = PositionEstimate(
                subjectId = subjectId, timestamp = epoch + raw.time, frameId = frameId,
                kind = PositionEstimate.Kind.measured, method = PositionEstimate.Method.gnss,
                position = Position(x = raw.position.x, y = 0.0, z = raw.position.z),
                uncertainty = PositionUncertainty(r95 = PositionUncertainty.r95(fromRadius68 = raw.accuracy)),
                velocity = velocity, lastAbsoluteAt = epoch + raw.time, source = EvidenceSource.gnss,
                freshness = Freshness(maxAge = 30.0), provenance = provenance(subjectId, gnss = true))
        }
        val motion = this.motion[second]?.let { step ->
            MotionObservation(
                subjectId = subjectId, timestamp = epoch + step.end, interval = step.end - step.start, frameId = frameId,
                method = MotionObservation.Method.pedometer, displacement = FloorVector(x = step.dx, z = step.dz),
                stationary = step.stationary,
                uncertainty = MotionObservation.Uncertainty(
                    displacementR95 = PositionUncertainty.r95(fromSigma = step.sigma), headingSigma = null),
                freshness = Freshness(maxAge = 5.0), provenance = provenance(subjectId, gnss = false))
        }
        val peers = mutableListOf<ContractInputs.Peer>()
        val heard = peerReports[second].zip(peerRSSI[second]).map { Triple(it.first, it.second, false) } +
            anchorReports[second].zip(anchorRSSI[second]).map { Triple(it.first, it.second, true) }
        for ((report, rssi, surveyed) in heard) {
            if (!inFrame(report.peerPosition)) continue
            val clamped = min(20.0, max(-127.0, rssi))
            val observation = PeerObservation(
                observerId = subjectId, peerId = report.peerId, timestamp = epoch + report.time, frameId = frameId,
                channel = PeerObservation.Channel.connection, linkState = PeerObservation.LinkState.ready,
                rawRSSI = listOf(clamped), window = 1.0, smoothedRSSI = clamped,
                uncertainty = PeerObservation.Uncertainty(stdDevDb = null, sampleCount = 1),
                freshness = Freshness(maxAge = 5.0), provenance = provenance(subjectId, gnss = false))
            val point = Position(x = report.peerPosition.x, y = 0.0, z = report.peerPosition.z)
            val uncertainty = PositionUncertainty(r95 = PositionUncertainty.r95(fromSigma = report.peerSigma))
            val position = if (surveyed) {
                PositionEstimate(subjectId = report.peerId, timestamp = epoch + report.time, frameId = frameId,
                    kind = PositionEstimate.Kind.declared, method = PositionEstimate.Method.manual, position = point,
                    uncertainty = uncertainty, source = EvidenceSource.manual, freshness = Freshness(maxAge = 3_600.0),
                    provenance = provenance(report.peerId, gnss = false))
            } else {
                PositionEstimate(subjectId = report.peerId, timestamp = epoch + report.time, frameId = frameId,
                    kind = PositionEstimate.Kind.measured, method = PositionEstimate.Method.gnss, position = point,
                    uncertainty = uncertainty, lastAbsoluteAt = epoch + report.time, source = EvidenceSource.gnss,
                    freshness = Freshness(maxAge = 30.0), provenance = provenance(report.peerId, gnss = true))
            }
            peers.add(ContractInputs.Peer(observation, position))
        }
        return ContractInputs(fix = fix, motion = motion, peers = peers)
    }

    companion object {
        /** A walker on turns and pauses, or a phone lying still. */
        internal fun route(seed: UInt, duration: Int, motion: GNSSScenario.Motion): List<FloorPoint> {
            val random = DeterministicRandom(seed)
            var x = 0.0
            var z = 0.0
            var heading = random.uniform(0.0, 2 * PI)
            var speed = random.uniform(1.2, 1.5)
            var segmentLeft = random.uniform(20.0, 80.0)
            var pauseLeft = 0
            val points = mutableListOf(FloorPoint(x = 0.0, z = 0.0))
            repeat(max(1, duration)) {
                if (motion == GNSSScenario.Motion.walk) {
                    if (pauseLeft > 0) {
                        pauseLeft -= 1
                    } else {
                        x += speed * sin(heading)
                        z += speed * cos(heading)
                        segmentLeft -= 1
                        if (segmentLeft <= 0) {
                            heading += random.uniform(-70.0, 70.0) * PI / 180
                            speed = random.uniform(1.2, 1.5)
                            segmentLeft = random.uniform(20.0, 80.0)
                            if (random.next() < 0.25) pauseLeft = random.uniform(10.0, 40.0).toInt()
                        }
                    }
                }
                points.add(FloorPoint(x = x, z = z))
            }
            return points
        }

        /**
         * Fixes with time-correlated error (Gauss-Markov), white noise on top, and a reported accuracy
         * that matches them; in `.urban`, multipath bursts the reported accuracy mostly misses.
         */
        internal fun cleanFixes(truth: List<FloorPoint>, seed: UInt,
                                environment: GNSSScenario.Environment = GNSSScenario.Environment.openSky): List<GNSSFix> {
            val random = DeterministicRandom(seed)
            val urban = environment == GNSSScenario.Environment.urban
            val sigma = if (urban) 5.0 else 2.5
            val white = if (urban) 1.5 else 0.8
            val tau = if (urban) 30.0 else 45.0
            val decay = exp(-1 / tau)
            val drive = sigma * sqrt(1 - decay * decay)
            var ex = sigma * random.gauss()
            var ez = sigma * random.gauss()
            var burstLeft = 0
            var burstX = 0.0
            var burstZ = 0.0
            return truth.indices.map { second ->
                ex = decay * ex + drive * random.gauss()
                ez = decay * ez + drive * random.gauss()
                if (urban) {
                    if (burstLeft > 0) {
                        burstLeft -= 1
                    } else if (random.next() < 1.0 / 150) {
                        burstLeft = random.uniform(8.0, 25.0).toInt()
                        val size = random.uniform(10.0, 35.0)
                        val angle = random.uniform(0.0, 2 * PI)
                        burstX = size * sin(angle)
                        burstZ = size * cos(angle)
                    }
                }
                val bx = if (burstLeft > 0) burstX else 0.0
                val bz = if (burstLeft > 0) burstZ else 0.0
                val previous = truth[max(0, second - 1)]
                val vx = truth[second].x - previous.x + 0.2 * random.gauss()
                val vz = truth[second].z - previous.z + 0.2 * random.gauss()
                val speed = hypot(vx, vz)
                var course = atan2(vx, vz) * 180 / PI
                if (course < 0) course += 360
                val inflation = if (burstLeft > 0) 1.33 else 1.0
                val accuracy = swiftRounded(1.515 * hypot(sigma, white) * inflation * random.uniform(0.85, 1.15) * 10) / 10
                val px = truth[second].x + ex + bx + white * random.gauss()
                val pz = truth[second].z + ez + bz + white * random.gauss()
                GNSSFix(time = second.toDouble(), position = FloorPoint(x = px, z = pz),
                    accuracy = accuracy, speed = speed, course = if (speed < 0.3) -1.0 else course, speedAccuracy = 0.3)
            }
        }

        /** The fix delivered in `second` once the faults active then have been applied. */
        internal fun inject(injections: List<GNSSFaultInjection>, second: Int, clean: List<GNSSFix>): GNSSFix? {
            val now = second.toDouble()
            var fix: GNSSFix? = clean[second]
            for (injection in injections) {
                if (!injection.isActive(now)) continue
                val current = fix ?: break
                val elapsed = now - injection.start
                fun moved(dx: Double, dz: Double, velocity: Pair<Double, Double>? = null): GNSSFix {
                    var speed = current.speed
                    var course = current.course
                    val base = current.velocity
                    if (velocity != null && base != null) {
                        val vx = base.x + velocity.first
                        val vz = base.z + velocity.second
                        speed = hypot(vx, vz)
                        val degrees = atan2(vx, vz) * 180 / PI
                        course = if (degrees < 0) degrees + 360 else degrees
                    }
                    return GNSSFix(time = current.time,
                        position = FloorPoint(x = current.position.x + dx, z = current.position.z + dz),
                        accuracy = current.accuracy, speed = speed, course = course, speedAccuracy = current.speedAccuracy)
                }
                when (val fault = injection.fault) {
                    is GNSSFault.jump -> fix = moved(fault.dx, fault.dz)
                    is GNSSFault.fakeTrack -> {
                        val r = fault.course * PI / 180
                        fix = moved(fault.speed * elapsed * sin(r), fault.speed * elapsed * cos(r),
                            velocity = fault.speed * sin(r) to fault.speed * cos(r))
                    }
                    is GNSSFault.acceleration -> {
                        val r = fault.course * PI / 180
                        val distance = 0.5 * fault.rate * elapsed * elapsed
                        fix = moved(distance * sin(r), distance * cos(r),
                            velocity = fault.rate * elapsed * sin(r) to fault.rate * elapsed * cos(r))
                    }
                    is GNSSFault.slowDrift -> {
                        val r = fault.course * PI / 180
                        fix = moved(fault.rate * elapsed * sin(r), fault.rate * elapsed * cos(r),
                            velocity = fault.rate * sin(r) to fault.rate * cos(r))
                    }
                    GNSSFault.frozenPosition -> {
                        val frozen = clean[min(clean.size - 1, max(0, injection.start.toInt()))]
                        fix = GNSSFix(time = now, position = frozen.position, accuracy = frozen.accuracy, speed = 0.0,
                            course = -1.0, speedAccuracy = current.speedAccuracy)
                    }
                    is GNSSFault.delayed -> fix = clean[max(0, second - fault.by.toInt())]
                    GNSSFault.dropout -> fix = null
                    GNSSFault.jamming -> {
                        if (elapsed < 10) {
                            val random = DeterministicRandom(second.toUInt() * 7_919u)
                            val accuracy = 10 + 9 * elapsed
                            val px = current.position.x + accuracy / 1.515 * random.gauss()
                            val pz = current.position.z + accuracy / 1.515 * random.gauss()
                            fix = GNSSFix(time = now, position = FloorPoint(x = px, z = pz), accuracy = accuracy)
                        } else {
                            fix = null
                        }
                    }
                    is GNSSFault.replay -> {
                        val old = clean[max(0, second - fault.lag.toInt())]
                        fix = GNSSFix(time = now, position = old.position, accuracy = old.accuracy, speed = old.speed,
                            course = old.course, speedAccuracy = old.speedAccuracy)
                    }
                }
            }
            return fix
        }
    }
}

data class GNSSRunMetrics(
    /** Seconds with no fault yet (after warm-up), and those flagged as anomalies anyway. */
    val cleanEpochs: Int,
    val falseAlarmEpochs: Int,
    /** Separate false-alarm episodes, and how many of them reached `rejected`. */
    val falseAlarmEvents: Int,
    val falseRejectEpochs: Int,
    /**
     * Flagged clean seconds in which the fix really was off by more than `justifiedError` (urban
     * multipath): no fault was injected, but GNSS was wrong.
     */
    val justifiedAlarmEpochs: Int,
    /** Clean seconds marked `trusted`: what honesty costs in availability. */
    val trustedCleanEpochs: Int,
    val faultEpochs: Int,
    val detected: Boolean,
    /** Seconds from the fault's start to the first flag. */
    val detectionDelay: Double?,
    /** How far the delivered fix was from the truth when first flagged, meters. */
    val errorAtDetection: Double?,
    /**
     * Seconds in the fault when a fix still marked usable was off by more than the alert limit and
     * by more than 3.5 times its recommended sigma: misleading information.
     */
    val misleadingEpochs: Int,
    /** The same, while marked `trusted`: integrity failures. */
    val trustedButWrongEpochs: Int,
    /** Largest error of a fix still usable during the fault, meters. */
    val maxUndetectedError: Double,
    /** Seconds from the end of the fault to `trusted` again; null if it never was. */
    val retrustDelay: Double?,
)

data class GNSSRunResult(
    val scenario: String,
    val config: String,
    val seed: UInt,
    val assessments: List<GNSSIntegrityAssessment>,
    /** Index = second; distance of the delivered fix from the truth. */
    val errors: List<Double?>,
    val metrics: GNSSRunMetrics,
)

data class GNSSComparisonRow(
    val scenario: String,
    val config: String,
    val runs: Int,
    val detectedRuns: Int,
    val medianDelay: Double?,
    val maxDelay: Double?,
    val medianErrorAtDetection: Double?,
    val falseAlarmEpochs: Int,
    val cleanEpochs: Int,
    val falseAlarmEvents: Int,
    val falseRejectEpochs: Int,
    val justifiedAlarmEpochs: Int,
    val trustedCleanEpochs: Int,
    val misleadingEpochs: Int,
    val trustedButWrongEpochs: Int,
    val maxUndetectedError: Double,
    val minRetrustDelay: Double?,
    val expectsAnomaly: Boolean,
    val hasFault: Boolean,
) {
    val missedRuns: Int get() = if (hasFault) runs - detectedRuns else 0
    val falseAlarmRate: Double get() = if (cleanEpochs == 0) 0.0 else falseAlarmEpochs.toDouble() / cleanEpochs.toDouble()
}

object GNSSFaultHarness {
    /** Seconds ignored at the start of a run. */
    const val warmUp = 10

    /** Position error beyond which a usable fix is hazardous for someone on foot, meters. */
    const val alertLimit = 30.0

    /** A flag on clean data is justified when the fix really was off by more than this, meters. */
    const val justifiedError = 20.0

    fun run(world: GNSSSimulatedWorld, config: GNSSDetectorConfig): GNSSRunResult {
        val engine = GNSSIntegrityEngine(config.options)
        val scenario = world.scenario
        val assessments = mutableListOf<GNSSIntegrityAssessment>()
        val errors = mutableListOf<Double?>(null)
        for (second in 1..scenario.duration) {
            val now = second.toDouble()
            if (config.useInertial) world.motion[second]?.let { engine.addMotion(it) }
            if (config.usePeers) world.peerReports[second].forEach { engine.addPeer(it) }
            if (config.useAnchors) world.anchorReports[second].forEach { engine.addPeer(it) }
            val fix = world.fixes[second]
            if (fix != null) {
                assessments.add(engine.assess(fix, now))
                errors.add(GNSSIntegrityEngine.distance(fix.position, world.truth[second]))
            } else {
                assessments.add(engine.assess(now))
                errors.add(null)
            }
        }
        return GNSSRunResult(scenario = scenario.name, config = config.name, seed = world.seed, assessments = assessments,
            errors = errors, metrics = metrics(scenario, assessments, errors))
    }

    internal fun metrics(scenario: GNSSScenario, assessments: List<GNSSIntegrityAssessment>,
                         errors: List<Double?>): GNSSRunMetrics {
        val faultStart = scenario.injections.map { it.start }.minOrNull()
        val detectionStart = scenario.detectionStart
        val faultEnd = if (scenario.injections.any { it.end == null }) null
        else scenario.injections.mapNotNull { it.end }.maxOrNull()
        val flags: (GNSSIntegrityStatus) -> Boolean = if (scenario.expectsAnomaly) { status -> status.isAnomaly }
        else { status -> status != GNSSIntegrityStatus.trusted && status != GNSSIntegrityStatus.insufficientEvidence }
        var clean = 0
        var falseEpochs = 0
        var falseEvents = 0
        var falseRejects = 0
        var justified = 0
        var trustedClean = 0
        var faultEpochs = 0
        var misleading = 0
        var trustedWrong = 0
        var wasFalse = false
        var delay: Double? = null
        var errorAtDetection: Double? = null
        var retrust: Double? = null
        var maxUndetected = 0.0
        for ((index, assessment) in assessments.withIndex()) {
            val second = index + 1
            val time = second.toDouble()
            val error = errors[second]
            if (faultStart != null && time >= faultStart) {
                if (faultEnd != null && time >= faultEnd) {
                    if (retrust == null && assessment.status == GNSSIntegrityStatus.trusted) retrust = time - faultEnd
                    continue
                }
                faultEpochs += 1
                if (delay == null && detectionStart != null && time >= detectionStart && flags(assessment.status)) {
                    delay = time - detectionStart
                    errorAtDetection = error
                }
                if (assessment.usableAsPosition && error != null) {
                    maxUndetected = max(maxUndetected, error)
                    val stated = 3.5 * (assessment.uncertainty.recommendedSigma ?: 0.0)
                    if (error > max(alertLimit, stated)) {
                        misleading += 1
                        if (assessment.status == GNSSIntegrityStatus.trusted) trustedWrong += 1
                    }
                }
            } else if (second >= warmUp) {
                clean += 1
                if (assessment.status == GNSSIntegrityStatus.trusted) trustedClean += 1
                if (assessment.status == GNSSIntegrityStatus.rejected) falseRejects += 1
                val flagged = assessment.isAnomaly
                if (flagged) {
                    falseEpochs += 1
                    if (!wasFalse) falseEvents += 1
                    if (error != null && error > justifiedError) justified += 1
                }
                wasFalse = flagged
            }
        }
        return GNSSRunMetrics(cleanEpochs = clean, falseAlarmEpochs = falseEpochs, falseAlarmEvents = falseEvents,
            falseRejectEpochs = falseRejects, justifiedAlarmEpochs = justified,
            trustedCleanEpochs = trustedClean,
            faultEpochs = faultEpochs, detected = delay != null, detectionDelay = delay,
            errorAtDetection = errorAtDetection, misleadingEpochs = misleading,
            trustedButWrongEpochs = trustedWrong, maxUndetectedError = maxUndetected,
            retrustDelay = retrust)
    }

    /** Runs every scenario on every seed through every configuration. */
    fun compare(scenarios: List<GNSSScenario> = GNSSScenario.library,
                configs: List<GNSSDetectorConfig> = GNSSDetectorConfig.all,
                seeds: List<UInt> = (1u..5u).toList()): List<GNSSComparisonRow> {
        val rows = mutableListOf<GNSSComparisonRow>()
        for (scenario in scenarios) {
            val worlds = seeds.map { GNSSSimulatedWorld(scenario, it) }
            for (config in configs) {
                val results = worlds.map { run(it, config).metrics }
                val delays = results.mapNotNull { it.detectionDelay }.sorted()
                val errors = results.mapNotNull { it.errorAtDetection }.sorted()
                rows.add(GNSSComparisonRow(
                    scenario = scenario.name, config = config.name, runs = results.size,
                    detectedRuns = results.count { it.detected },
                    medianDelay = if (delays.isEmpty()) null else delays[delays.size / 2], maxDelay = delays.lastOrNull(),
                    medianErrorAtDetection = if (errors.isEmpty()) null else errors[errors.size / 2],
                    falseAlarmEpochs = results.sumOf { it.falseAlarmEpochs },
                    cleanEpochs = results.sumOf { it.cleanEpochs },
                    falseAlarmEvents = results.sumOf { it.falseAlarmEvents },
                    falseRejectEpochs = results.sumOf { it.falseRejectEpochs },
                    justifiedAlarmEpochs = results.sumOf { it.justifiedAlarmEpochs },
                    trustedCleanEpochs = results.sumOf { it.trustedCleanEpochs },
                    misleadingEpochs = results.sumOf { it.misleadingEpochs },
                    trustedButWrongEpochs = results.sumOf { it.trustedButWrongEpochs },
                    maxUndetectedError = results.maxOfOrNull { it.maxUndetectedError } ?: 0.0,
                    minRetrustDelay = results.mapNotNull { it.retrustDelay }.minOrNull(),
                    expectsAnomaly = scenario.expectsAnomaly, hasFault = scenario.injections.isNotEmpty()))
            }
        }
        return rows
    }

    /** The comparison as a Markdown table. */
    fun markdown(rows: List<GNSSComparisonRow>): String {
        val lines = mutableListOf(
            "| Scenario | Detector | Detected | Delay median / max | Offset at detection | Clean-data alarms: s / episodes / rejected s / s with GPS really > ${justifiedError.toInt()} m off, of clean s | Trusted share (clean) | Misleading s (of them trusted) | Max undetected error |",
            "|---|---|---|---|---|---|---|---|---|",
        )
        fun seconds(value: Double?): String = value?.let { "${it.toLong()} s" } ?: "–"
        fun meters(value: Double?): String = value?.let { "${swiftRounded(it).toLong()} m" } ?: "–"
        for (row in rows) {
            val detected = if (row.hasFault) "${row.detectedRuns}/${row.runs}" else "–"
            val delay = if (row.hasFault) "${seconds(row.medianDelay)} / ${seconds(row.maxDelay)}" else "–"
            val falseAlarms = if (row.cleanEpochs == 0) "–"
            else "${row.falseAlarmEpochs} / ${row.falseAlarmEvents} / ${row.falseRejectEpochs} / ${row.justifiedAlarmEpochs} of ${row.cleanEpochs}"
            val trusted = if (row.cleanEpochs == 0) "–"
            else "${swiftRounded(100 * row.trustedCleanEpochs.toDouble() / row.cleanEpochs.toDouble()).toLong()} %"
            val hazard = if (row.hasFault) "${row.misleadingEpochs} (${row.trustedButWrongEpochs})" else "–"
            val undetected = if (row.hasFault) meters(row.maxUndetectedError) else "–"
            lines.add("| ${row.scenario} | ${row.config} | $detected | $delay | ${meters(row.medianErrorAtDetection)} | $falseAlarms | $trusted | $hazard | $undetected |")
        }
        return lines.joinToString("\n")
    }
}
