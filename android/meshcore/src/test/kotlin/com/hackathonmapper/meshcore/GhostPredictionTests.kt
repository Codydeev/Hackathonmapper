package com.hackathonmapper.meshcore

import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.sin
import kotlin.math.sqrt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GhostPredictionTests {
    private fun bluetooth(t: Double, x: Double, z: Double, sigma: Double = 8.0): GhostObservation =
        GhostObservation(t = t, x = x, z = z, sigma = sigma, source = GhostObservation.Source.bluetooth)

    /** A walk east at `speed`, observed every second from 0 to `until`. */
    private fun walk(tracker: GhostTracker, id: String = "B", speed: Double = 1.3, until: Int = 60) {
        for (t in 0..until) tracker.observe(id, bluetooth(t.toDouble(), speed * t.toDouble(), 0.0))
    }

    // MARK: Gaussian math

    @Test
    fun testIsotropicRegionsMatchClosedForm() {
        val g = GhostGaussian.isotropic(x = 3.0, z = -4.0, sigma = 10.0)
        val k95 = sqrt(-2 * ln(0.05))
        assertEquals(10 * k95, g.circleRadius(0.95), 1e-3)
        assertEquals(1 - exp(-225.0 / 200), g.mass(15.0), 1e-9)
        assertEquals(2 * PI * 100 * -ln(0.1), g.area(0.9), 1e-6)
        assertEquals(0.0, g.level(3.0, -4.0), 1e-12)
        assertEquals(0.95, g.level(3 + 10 * k95, -4.0), 1e-9)
    }

    @Test
    fun testCircleRadiusHoldsItsMassForElongatedBeliefs() {
        val g = GhostGaussian(x = 0.0, z = 0.0, xx = 400.0, xz = 150.0, zz = 100.0)
        val r = g.circleRadius(0.95)
        val points = g.samples(40_000, seed = 7uL)
        val inside = points.count { hypot(it.x, it.z) <= r }.toDouble() / points.size.toDouble()
        assertEquals(0.95, inside, 0.005)
        assertTrue(r < g.ellipse(0.95).semiMajor + 1e-9)
    }

    @Test
    fun testEllipseAxesAndOrientation() {
        val e = GhostGaussian(x = 0.0, z = 0.0, xx = 100.0, zz = 25.0).ellipse(0.9)
        val k = sqrt(-2 * ln(0.1))
        assertEquals(10 * k, e.semiMajor, 1e-9)
        assertEquals(5 * k, e.semiMinor, 1e-9)
        assertEquals(0.0, e.angle, 1e-12)
        val diagonal = GhostGaussian(x = 0.0, z = 0.0, xx = 50.0, xz = 40.0, zz = 50.0).principal
        assertEquals(PI / 4, diagonal.angle, 1e-9)
        assertEquals(90.0, diagonal.major, 1e-9)
        assertEquals(10.0, diagonal.minor, 1e-9)
    }

    @Test
    fun testSamplesAreDeterministic() {
        val g = GhostGaussian(x = 1.0, z = 2.0, xx = 30.0, xz = 5.0, zz = 20.0)
        assertEquals(g.samples(16, seed = 3uL).map { it.x }, g.samples(16, seed = 3uL).map { it.x })
        assertNotEquals(g.samples(16, seed = 3uL).map { it.x }, g.samples(16, seed = 4uL).map { it.x })
    }

    @Test
    fun testScaleMixtureRegionsAreExact() {
        val core = GhostGaussian.isotropic(x = 0.0, z = 0.0, sigma = 5.0)
        val b = GhostBelief(
            core = core,
            scales = listOf(GhostBelief.Scale(weight = 0.8, variance = 1.0), GhostBelief.Scale(weight = 0.2, variance = 9.0)),
        )
        val r = b.circleRadius(0.9)
        assertEquals(0.9, b.mass(r), 1e-4)
        val d2 = b.radius2(0.9)
        assertEquals(0.9, b.level(sqrt(d2 * 25), 0.0), 1e-6)
        assertEquals(core.circleRadius(0.95), GhostBelief(core = core).circleRadius(0.95), 1e-3)
    }

    // MARK: Kalman filter

    @Test
    fun testMeanRevertingNoiseMatchesConstantVelocityForShortGaps() {
        // Ornstein-Uhlenbeck with tau >> dt behaves like white acceleration with q = 2 s^2 / tau.
        val o = bluetooth(0.0, 0.0, 0.0, sigma = 3.0)
        val tau = 1e5
        val s = 300.0
        val ou = GhostKalman(
            o,
            GhostMotionParams(
                kind = GhostMotionParams.Kind.meanReverting, motionNoise = s, persistence = tau,
                gpsSigmaScale = 1.0, radioSigmaScale = 1.0, initialSpeedSigma = 1.0,
            ),
        )
        val cv = GhostKalman(
            o,
            GhostMotionParams(
                kind = GhostMotionParams.Kind.constantVelocity, motionNoise = sqrt(2 * s * s / tau),
                persistence = Double.POSITIVE_INFINITY, gpsSigmaScale = 1.0, radioSigmaScale = 1.0,
                initialSpeedSigma = 1.0,
            ),
        )
        ou.advance(10.0)
        cv.advance(10.0)
        assertEquals(cv.positionNow.xx, ou.positionNow.xx, cv.positionNow.xx * 1e-3)
    }

    @Test
    fun testFilterLearnsVelocityAndGapsGrowSubQuadratically() {
        val f = GhostKalman(bluetooth(0.0, 0.0, 0.0, sigma = 3.0), GhostMotionParams.walking)
        for (t in 1..60) f.update(bluetooth(t.toDouble(), 1.3 * t.toDouble(), 0.0, sigma = 3.0))
        assertEquals(1.3, f.velocityNow.vx, 0.15)
        assertEquals(0.0, f.velocityNow.vz, 0.15)
        val radii = listOf(5.0, 10.0, 30.0, 60.0, 120.0, 300.0, 600.0).map { f.belief(60 + it).circleRadius(0.95) }
        assertEquals("the area only grows while nothing is heard", radii.sorted(), radii)
        // Constant velocity would grow 2.8x from 5 to 10 min (h^1.5); people turn and stop.
        assertTrue(radii[6] / radii[5] < 2)
        // The mean keeps going for a while, then slows down instead of running off forever.
        val far = f.belief(660.0)
        assertTrue(far.x > 78 + 30)
        assertTrue(far.x < 78 + 1.3 * 600)
    }

    @Test
    fun testCovarianceStaysSymmetricAndPositive() {
        val f = GhostKalman(bluetooth(0.0, 0.0, 0.0), GhostMotionParams.walking)
        for (t in 1..500) {
            f.update(bluetooth(t.toDouble(), sin(t.toDouble() / 10) * 30, t.toDouble() * 0.5, sigma = 5 + (t % 7).toDouble()))
            if (t % 3 == 0) {
                f.apply(
                    GhostMotionHint(
                        t = t.toDouble() + 0.5, stationary = false,
                        velocity = GhostVelocity(vx = 1.0, vz = 0.5, sigma = 0.3),
                    ),
                )
            }
        }
        val g = f.positionNow
        assertTrue(g.xx > 0)
        assertTrue(g.zz > 0)
        assertTrue(g.xx * g.zz - g.xz * g.xz > 0)
    }

    @Test
    fun testStationaryHintsHoldTheAreaSmall() {
        val still = GhostKalman(bluetooth(0.0, 0.0, 0.0, sigma = 4.0), GhostMotionParams.walking)
        val unknown = still.copy()
        for (t in 1..30) {
            still.update(bluetooth(t.toDouble(), 0.0, 0.0, sigma = 4.0))
            unknown.update(bluetooth(t.toDouble(), 0.0, 0.0, sigma = 4.0))
        }
        for (t in 31..150) still.apply(GhostMotionHint(t = t.toDouble(), stationary = true))
        assertTrue(still.belief(150.0).circleRadius(0.95) < 0.5 * unknown.belief(150.0).circleRadius(0.95))
    }

    @Test
    fun testDeadReckoningDriftGrowsWithDistanceWalked() {
        val f = GhostKalman(
            GhostObservation(t = 0.0, x = 0.0, z = 0.0, sigma = 3.0, source = GhostObservation.Source.gps),
            GhostMotionParams.walking,
        )
        for (t in 1..20) {
            f.update(GhostObservation(t = t.toDouble(), x = 0.0, z = 1.4 * t.toDouble(), sigma = 3.0, source = GhostObservation.Source.gps))
        }
        val hint = { t: Double -> GhostMotionHint(t = t, stationary = false, velocity = GhostVelocity(vx = 0.0, vz = 1.4, sigma = 0.05)) }
        for (t in 21..80) f.apply(hint(t.toDouble()))
        assertEquals(1.4 * 60, f.deadReckoned, 1e-6)
        // Very confident step readings still leave a drift of 15% of the distance per axis.
        assertTrue(sqrt(f.positionNow.xx) > 0.15 * 84 - 1e-6)
        f.update(GhostObservation(t = 81.0, x = 0.0, z = 113.0, sigma = 3.0, source = GhostObservation.Source.gps))
        assertEquals(0.0, f.deadReckoned, 0.0)
    }

    @Test
    fun testPredictionIsNeverSharperThanItsLastObservation() {
        val f = GhostKalman(
            GhostObservation(t = 0.0, x = 0.0, z = 0.0, sigma = 6.0, source = GhostObservation.Source.gps),
            GhostMotionParams.walking,
        )
        val b = f.belief(0.5)
        assertTrue(b.core.xx >= 36 - 1e-9)
        assertTrue(b.core.zz >= 36 - 1e-9)
    }

    @Test
    fun testConstantVelocityBaseline() {
        val track = (0..20).map {
            GhostObservation(t = it.toDouble(), x = it.toDouble(), z = 2 * it.toDouble(), sigma = 4.0, source = GhostObservation.Source.gps)
        }
        val cv = GhostConstantVelocity(window = 10.0, startScale = 1.0, velocitySigma = 0.5, diffusion = 1.0)
        val p = cv.predict(track, 30.0)!!
        assertEquals(30.0, p.x, 1e-9)
        assertEquals(60.0, p.z, 1e-9)
        assertEquals(16 + 0.25 * 100 + 10, p.xx, 1e-9)
        assertNull(cv.predict(emptyList(), 1.0))
    }

    // MARK: Tracker

    @Test
    fun testStatusGoesLiveGhostLostAndKeepsTheLastObservation() {
        val tracker = GhostTracker()
        walk(tracker)
        val live = tracker.estimate("B", 62.0)!!
        assertEquals(GhostStatus.live, live.status)
        assertFalse(live.isPrediction)
        val ghost = tracker.estimate("B", 90.0)!!
        assertEquals(GhostStatus.ghost, ghost.status)
        assertEquals(GhostBasis.extrapolated, ghost.basis)
        assertTrue(ghost.isPrediction)
        assertEquals(bluetooth(60.0, 78.0, 0.0), ghost.lastObserved)
        assertEquals(30.0, ghost.age, 1e-9)
        assertTrue("the prediction moves on; the last observation stays put", ghost.belief!!.x > 78)
        assertTrue(ghost.summary, ghost.summary.startsWith("Predicted: last seen 30 s ago (Bluetooth), 95% within "))
        val later = tracker.estimate("B", 200.0)!!
        assertTrue(later.r95!! > ghost.r95!!)
        assertTrue(later.confidence < ghost.confidence)
        val lost = tracker.estimate("B", 700.0)!!
        assertEquals(GhostStatus.lost, lost.status)
        assertNull(lost.belief)
        assertNull(lost.r95)
        assertEquals(0.0, lost.confidence, 0.0)
        assertEquals(60.0, lost.lastObserved.t, 0.0)
        assertEquals("Lost: last seen 10 min 40 s ago (Bluetooth)", lost.summary)
        assertNull(tracker.estimate("nobody", 10.0))
    }

    @Test
    fun testLateAndDuplicateObservationsAreIgnored() {
        val tracker = GhostTracker()
        walk(tracker, until = 30)
        assertNull(tracker.observe("B", bluetooth(30.0, 500.0, 500.0)))
        assertNull(tracker.observe("B", bluetooth(12.0, 500.0, 500.0)))
        assertEquals(bluetooth(30.0, 39.0, 0.0), tracker.lastObservation("B"))
        assertNull(tracker.observe("B", GhostObservation(t = 31.0, x = Double.NaN, z = 0.0, sigma = 8.0, source = GhostObservation.Source.bluetooth)))
        assertEquals(30.0, tracker.lastObservation("B")?.t)
    }

    @Test
    fun testRecoveryInsideThePredictionIsFused() {
        val tracker = GhostTracker()
        walk(tracker)
        val r = tracker.observe("B", bluetooth(120.0, 1.3 * 120, 0.0))!!
        assertEquals(GhostRecovery.Action.fused, r.action)
        assertEquals(60.0, r.gap, 0.0)
        assertEquals(true, r.insideR95)
        assertTrue(r.level!! < 0.9)
        assertEquals("a fresh observation drops the prediction at once", GhostStatus.live, tracker.estimate("B", 121.0)?.status)
        assertEquals(1, tracker.recoveries.size)
        assertEquals(1, tracker.calibration.count)
    }

    @Test
    fun testRecoveryFarFromThePredictionRestartsTheTrack() {
        val tracker = GhostTracker()
        walk(tracker, until = 40)
        val r = tracker.observe("B", GhostObservation(t = 60.0, x = 400.0, z = -300.0, sigma = 5.0, source = GhostObservation.Source.gps))!!
        assertEquals(GhostRecovery.Action.restarted, r.action)
        assertEquals(false, r.insideR95)
        val e = tracker.estimate("B", 60.0)!!
        assertEquals(400.0, e.belief!!.x, 1e-6)
        assertEquals(-300.0, e.belief!!.z, 1e-6)
    }

    @Test
    fun testRecoveryAfterMaxHorizonHasNoPredictionToCheck() {
        val tracker = GhostTracker()
        walk(tracker, until = 10)
        val r = tracker.observe("B", bluetooth(900.0, 20.0, 20.0))!!
        assertEquals(GhostRecovery.Action.restarted, r.action)
        assertNull(r.level)
        assertNull(r.insideR95)
        assertEquals(0, tracker.calibration.count)
    }

    @Test
    fun testClockAheadOfOursNeverGivesNegativeAges() {
        val tracker = GhostTracker()
        tracker.observe("B", bluetooth(101.5, 0.0, 0.0))
        val e = tracker.estimate("B", 100.0)!!
        assertEquals(0.0, e.age, 0.0)
        assertEquals(GhostStatus.live, e.status)
    }

    @Test
    fun testMotionHintsMakeItDeadReckoning() {
        val tracker = GhostTracker()
        for (t in 0..30) {
            tracker.observe("A", GhostObservation(t = t.toDouble(), x = 0.0, z = 1.4 * t.toDouble(), sigma = 5.0, source = GhostObservation.Source.gps))
        }
        for (t in 31..60) {
            tracker.motion(
                "A",
                GhostMotionHint(
                    t = t.toDouble(), stationary = false,
                    velocity = GhostVelocity.fromHeading(speed = 1.4, heading = 0.0, speedSigma = 0.2, headingSigma = 0.2),
                ),
            )
        }
        val e = tracker.estimate("A", 60.0)!!
        assertEquals(GhostStatus.ghost, e.status)
        assertEquals(GhostBasis.deadReckoned, e.basis)
        assertEquals(1.4 * 60, e.belief!!.z, 6.0)
        assertTrue(e.summary, e.summary.startsWith("Dead reckoning:"))
        assertEquals("hints went quiet", GhostBasis.extrapolated, tracker.estimate("A", 70.0)?.basis)
    }

    @Test
    fun testOnlineCalibrationWidensWhenRecoveriesMissTheArea() {
        val config = GhostTracker.Config()
        config.gate = 1_000.0 // keep fusing so every miss is counted
        val tracker = GhostTracker(config)
        for (round in 0 until 12) {
            val base = round.toDouble() * 100
            for (t in 0..20) tracker.observe("B", bluetooth(base + t.toDouble(), 0.0, 0.0, sigma = 2.0))
            // Heard again 30 s later far beyond anything a walker does in 30 s.
            tracker.observe("B", bluetooth(base + 50, 150.0, 0.0, sigma = 2.0))
        }
        assertTrue(tracker.inflation > 1)
        assertTrue(tracker.calibration.coverage90!! < 0.8)
    }

    @Test
    fun testWellCalibratedRecoveriesLeaveInflationAlone() {
        val tracker = GhostTracker()
        for (round in 0 until 12) {
            val base = round.toDouble() * 200
            for (t in 0..30) tracker.observe("B", bluetooth(base + t.toDouble(), 1.3 * t.toDouble(), 0.0))
            tracker.observe("B", bluetooth(base + 50, 1.3 * 50, 0.0))
        }
        assertEquals(1.0, tracker.inflation, 0.0)
    }

    // MARK: Contract adapter

    private val frame = GeoFrame.defaultFrameId

    private fun estimate(
        id: String,
        t: Double,
        x: Double,
        z: Double,
        r95: Double = 20.0,
        kind: PositionEstimate.Kind = PositionEstimate.Kind.estimated,
        method: PositionEstimate.Method = PositionEstimate.Method.particle,
        source: EvidenceSource = EvidenceSource.bluetooth,
        age: Double = 0.0,
        simulated: Boolean = false,
    ): PositionEstimate = PositionEstimate(
        subjectId = id, timestamp = t, frameId = frame, kind = kind, method = method,
        position = Position(x = x, y = 0.0, z = z), uncertainty = PositionUncertainty(r95 = r95),
        source = source, freshness = Freshness(ageAtHandoff = age, maxAge = 30.0),
        provenance = Provenance(
            producerId = "phone-c", algorithm = "bluetooth-estimator@1",
            gnssDependent = source == EvidenceSource.gnss, simulated = simulated,
        ),
    )

    @Test
    fun testPredictorPublishesAValidPredictionOnlyWhileTheSubjectIsAGhost() {
        val ghost = GhostPredictor(producerId = "phone-a", frameId = frame)
        val t0 = 1_793_000_000.0
        for (t in 0..60) {
            ghost.observe(estimate("phone-b", t = t0 + t, x = 1.3 * t, z = 0.0, simulated = true), receivedAt = t0 + t)
        }
        assertNull("live: no prediction", ghost.predict(subjectId = "phone-b", t0 + 61))
        val p = ghost.predict(subjectId = "phone-b", t0 + 120)
        assertNotNull(p)
        p!!
        p.validate()
        assertEquals(Prediction.Method.kalman, p.method)
        assertEquals(EvidenceSource.prediction, p.source)
        assertEquals(60.0, p.horizon, 1e-9)
        assertEquals(Position(x = 78.0, y = 0.0, z = 0.0), p.lastObservedPosition)
        assertTrue(p.center.x > 78)
        assertEquals("kalman-ou@1", p.provenance.algorithm)
        assertEquals(listOf("phone-a", "phone-c"), p.provenance.contributors)
        assertTrue("simulated inputs stay flagged", p.provenance.simulated)
        assertFalse(p.provenance.gnssDependent)
        assertEquals("last observation", p.provenance.inputs.lastOrNull()?.reason)
        assertEquals(64, p.cloud?.size)
        val next = ghost.predict(subjectId = "phone-b", t0 + 121)
        assertNotNull(next)
        assertTrue(next!!.uncertainty.r95 > p.uncertainty.r95)
        assertEquals(null, p.withoutCloud.cloud)
        assertEquals(PositionEstimate.Kind.predicted, p.asPositionEstimate.kind)
        // Heard again: the prediction is gone at once.
        ghost.observe(estimate("phone-b", t = t0 + 130, x = 160.0, z = 0.0), receivedAt = t0 + 130)
        assertNull(ghost.predict(subjectId = "phone-b", t0 + 130))
        assertNull(ghost.predict(subjectId = "phone-b", t0 + 131))
        assertNull("lost: no prediction", ghost.predict(subjectId = "phone-b", t0 + 2_000))
    }

    @Test
    fun testPredictorNeverLearnsFromPredictionsOrOtherFrames() {
        val ghost = GhostPredictor(producerId = "phone-a", frameId = frame)
        val t0 = 1_793_000_000.0
        ghost.observe(estimate("b", t = t0, x = 0.0, z = 0.0), receivedAt = t0)
        ghost.observe(
            estimate(
                "b", t = t0 + 5, x = 50.0, z = 0.0, kind = PositionEstimate.Kind.predicted,
                method = PositionEstimate.Method.prediction, source = EvidenceSource.prediction,
            ),
            receivedAt = t0 + 5,
        )
        ghost.observe(
            estimate("b", t = t0 + 6, x = 60.0, z = 0.0, method = PositionEstimate.Method.deadReckoning, source = EvidenceSource.inertial),
            receivedAt = t0 + 6,
        )
        val other = PositionEstimate(
            subjectId = "b", timestamp = t0 + 7, frameId = "elsewhere-v1", kind = PositionEstimate.Kind.estimated,
            method = PositionEstimate.Method.particle, position = Position(x = 70.0, y = 0.0, z = 0.0),
            uncertainty = PositionUncertainty(r95 = 10.0), source = EvidenceSource.bluetooth,
            freshness = Freshness(maxAge = 30.0), provenance = Provenance(producerId = "c", algorithm = "x@1", gnssDependent = false),
        )
        ghost.observe(other, receivedAt = t0 + 7)
        assertEquals(1, ghost.tracker.observations("b").size)
    }

    @Test
    fun testRelayedEstimatesAreTimedByAgeNotByTheSendersClock() {
        val ghost = GhostPredictor(producerId = "phone-a", frameId = frame)
        // The sender's clock is an hour off; only its age at handoff counts.
        ghost.observe(estimate("b", t = 5_000.0, x = 0.0, z = 0.0, age = 4.0), receivedAt = 1_793_000_100.0)
        assertEquals(1_793_000_096.0, ghost.tracker.lastObservation("b")?.t)
        assertEquals(20 / PositionUncertainty.sigmaTo95, ghost.tracker.lastObservation("b")?.sigma ?: 0.0, 1e-9)
    }

    @Test
    fun testGNSSInputsMarkPredictionsGNSSDependent() {
        val ghost = GhostPredictor(producerId = "phone-a", frameId = frame)
        val t0 = 1_793_000_000.0
        for (t in 0..10) {
            ghost.observe(
                estimate(
                    "phone-a", t = t0 + t, x = 0.0, z = t.toDouble(), r95 = 8.0, kind = PositionEstimate.Kind.measured,
                    method = PositionEstimate.Method.gnss, source = EvidenceSource.gnss,
                ),
                receivedAt = t0 + t,
            )
        }
        val p = ghost.predict(subjectId = "phone-a", t0 + 30)
        assertNotNull(p)
        p!!.validate()
        assertTrue(p.provenance.gnssDependent)
        assertEquals(GhostObservation.Source.gps, ghost.tracker.lastObservation("phone-a")?.source)
    }

    @Test
    fun testLearnedAreaIsUsedOnlyWithEnoughHistory() {
        val t0 = 1_793_000_000.0
        fun run(seconds: Int, learned: GhostLearnedArea?): Pair<GhostPredictor, Prediction?> {
            val ghost = GhostPredictor(producerId = "phone-a", frameId = frame)
            var calls = 0
            ghost.learnedArea = { track, horizon ->
                calls += 1
                assertEquals(30.0, horizon, 1e-9)
                assertEquals(t0 + seconds, track.lastOrNull()?.t)
                learned
            }
            for (t in 0..seconds) {
                ghost.observe(estimate("b", t = t0 + t, x = t.toDouble(), z = 0.0), receivedAt = t0 + t)
            }
            assertNull("live: no prediction, model not asked", ghost.predict(subjectId = "b", t0 + seconds + 1))
            assertEquals(0, calls)
            return Pair(ghost, ghost.predict(subjectId = "b", t0 + seconds + 30))
        }
        val area = GhostLearnedArea(
            center = FloorVector(x = 120.0, z = 3.0), r95 = 70.0,
            cloud = listOf(FloorVector(x = 118.0, z = 2.0)), algorithm = "movement-model-v2-nomap@1",
        )
        val long = run(seconds = 90, learned = area).second
        assertNotNull(long)
        long!!.validate()
        assertEquals(Prediction.Method.movementModel, long.method)
        assertEquals(Position(x = 120.0, y = 0.0, z = 3.0), long.center)
        assertEquals(70.0, long.uncertainty.r95, 0.0)
        assertEquals(Position(x = 90.0, y = 0.0, z = 0.0), long.lastObservedPosition)
        assertEquals("movement-model-v2-nomap@1", long.provenance.algorithm)
        assertEquals("under 60 s of track", Prediction.Method.kalman, run(seconds = 40, learned = area).second!!.method)
        assertEquals("model declined", Prediction.Method.kalman, run(seconds = 90, learned = null).second!!.method)
    }

    @Test
    fun testTrackKeepsTwoMinutes() {
        val tracker = GhostTracker()
        for (t in 0..300) tracker.observe("B", bluetooth(t.toDouble(), t.toDouble(), 0.0))
        assertEquals(180.0, tracker.observations("B").firstOrNull()?.t)
        assertEquals(121, tracker.observations("B").size)
    }

    @Test
    fun testAmbiguousEstimatesSteerLessAndStartWider() {
        fun lastR95(ambiguous: Boolean): Double {
            val ghost = GhostPredictor(producerId = "phone-a", frameId = frame)
            for (t in 0..30) {
                val e = PositionEstimate(
                    subjectId = "b", timestamp = 1_793_000_000.0 + t, frameId = frame, kind = PositionEstimate.Kind.estimated,
                    method = PositionEstimate.Method.particle, position = Position(x = t.toDouble(), y = 0.0, z = 0.0),
                    uncertainty = PositionUncertainty(r95 = 40.0, ambiguous = ambiguous), source = EvidenceSource.bluetooth,
                    freshness = Freshness(maxAge = 30.0),
                    provenance = Provenance(producerId = "c", algorithm = "x@1", gnssDependent = false),
                )
                ghost.observe(e, receivedAt = 1_793_000_000.0 + t)
            }
            return ghost.predict(subjectId = "b", 1_793_000_040.0)!!.uncertainty.r95
        }
        assertTrue(lastR95(ambiguous = true) > 1.5 * lastR95(ambiguous = false))
        // Never sharper than the radio position as the filter trusts it.
        assertTrue(lastR95(ambiguous = false) >= 40 * GhostMotionParams.walking.radioSigmaScale - 1e-6)
    }

    @Test
    fun testMotionObservationBecomesAVelocityHint() {
        val m = MotionObservation(
            subjectId = "a", timestamp = 100.0, interval = 2.0, frameId = frame, method = MotionObservation.Method.pedometer,
            steps = 4, displacement = FloorVector(x = 0.0, z = 2.8), heading = 0.0, stationary = false,
            uncertainty = MotionObservation.Uncertainty(displacementR95 = 0.7, headingSigma = 0.2),
            freshness = Freshness(maxAge = 5.0),
            provenance = Provenance(producerId = "a", algorithm = "pdr@1", gnssDependent = false),
        )
        val hint = GhostMotionHint(m)
        assertEquals(100.0, hint.t, 0.0)
        assertFalse(hint.stationary)
        assertEquals(1.4, hint.velocity!!.vz, 1e-9)
        assertEquals(1.4 * 0.2, hint.velocity!!.sigma, 1e-9)
    }
}
