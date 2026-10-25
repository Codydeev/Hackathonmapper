package com.hackathonmapper.meshcore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sin
import kotlin.math.sqrt

class PositioningTests {
    /** Deterministic noise so the simulated walks are repeatable (bit-exact port of the Swift LCG). */
    private class Noise(var state: ULong) {
        fun uniform(): Double {
            state = state * 6364136223846793005UL + 1442695040888963407UL
            return (state shr 11).toDouble() / (1L shl 53).toDouble()
        }

        fun gaussian(): Double {
            // Swift evaluates left to right: the log's uniform first, then the cosine's.
            val radius = sqrt(-2 * ln(uniform() + 1e-12))
            return radius * cos(2 * Math.PI * uniform())
        }
    }

    private val flat = Vector3(0.0, 0.0, -1.0)
    private val upright = Vector3(0.0, -1.0, 0.0)
    private val still = Vector3(0.0, 0.0, 0.0)

    private fun <T> unwrap(value: T?): T {
        assertNotNull(value)
        return value!!
    }

    @Test
    fun testLinearSystemSolvesAndDetectsSingularity() {
        val x = unwrap(solveLinearSystem(listOf(listOf(2.0, 1.0), listOf(1.0, 3.0)), listOf(3.0, 5.0)))
        assertEquals(0.8, x[0], 1e-9)
        assertEquals(1.4, x[1], 1e-9)
        assertNull(solveLinearSystem(listOf(listOf(1.0, 2.0), listOf(2.0, 4.0)), listOf(1.0, 2.0)))
    }

    @Test
    fun testSwiftRoundedRoundsHalvesAwayFromZero() {
        assertEquals(3.0, swiftRounded(2.5), 0.0)
        assertEquals(-3.0, swiftRounded(-2.5), 0.0)
        assertEquals(1.0, swiftRounded(0.5), 0.0)
        assertEquals(0.0, swiftRounded(0.49999999999999994), 0.0)
        assertEquals(-60.0, swiftRounded(-60.4), 0.0)
        assertEquals(-61.0, swiftRounded(-60.5), 0.0)
        assertEquals(4503599627370497.0, swiftRounded(4503599627370497.0), 0.0)
    }

    /** 10 s of walking at 1.8 steps/s, vertical swing ±0.25 g, in both common holding poses. */
    @Test
    fun testStepsAndStrideFromSyntheticWalk() {
        for (gravity in listOf(flat, upright)) {
            val pdr = PedestrianDeadReckoning()
            val steps = mutableListOf<Step>()
            for (k in 0..500) {
                val t = k.toDouble() / 50
                val swing = 0.25 * sin(2 * Math.PI * 1.8 * t)
                // Upward acceleration is opposite to gravity.
                val acceleration = Vector3(-gravity.x * swing, -gravity.y * swing, -gravity.z * swing)
                pdr.process(MotionSample(time = t, gravity = gravity, userAcceleration = acceleration, rotationRate = still))
                    ?.let { steps.add(it) }
            }
            assertTrue("steps: ${steps.size}", steps.size in 16..19)
            assertEquals(steps.size, pdr.stepCount)
            for (step in steps) {
                assertTrue("stride: ${step.length}", step.length in 0.5..0.8)
                assertEquals(0.0, step.heading, 1e-9)
            }
        }
    }

    @Test
    fun testHandJitterIsNotAStep() {
        val pdr = PedestrianDeadReckoning()
        for (k in 0..500) {
            val t = k.toDouble() / 50
            val jitter = Vector3(0.0, 0.0, -0.05 * sin(2 * Math.PI * 4 * t))
            assertNull(pdr.process(MotionSample(time = t, gravity = flat, userAcceleration = jitter, rotationRate = still)))
        }
    }

    /** A clockwise (right) turn seen from above increases the heading toward +x, in either pose. */
    @Test
    fun testHeadingIntegratesGyroAboutGravity() {
        val rightTurns = listOf(
            Pair(flat, Vector3(0.0, 0.0, -Math.PI / 2)),
            Pair(upright, Vector3(0.0, -Math.PI / 2, 0.0)),
        )
        for ((gravity, rate) in rightTurns) {
            val pdr = PedestrianDeadReckoning()
            for (k in 0..50) {
                pdr.process(MotionSample(time = k.toDouble() / 50, gravity = gravity, userAcceleration = still, rotationRate = rate))
            }
            assertEquals(Math.PI / 2, pdr.heading, 0.02)
        }
        val step = Step(time = 0.0, length = 1.0, heading = Math.PI / 2)
        assertEquals(1.0, step.dx, 1e-9)
        assertEquals(0.0, step.dz, 1e-9)
    }

    @Test
    fun testPathLossModelRoundTrip() {
        val model = PathLossModel.default
        assertEquals(model.referenceRSSI, model.predictedRSSI(1.0), 1e-9)
        assertEquals(7.0, model.distance(model.predictedRSSI(7.0)), 1e-9)
        assertEquals(model.predictedRSSI(PathLossModel.minDistance), model.predictedRSSI(0.1), 0.0)
    }

    /** Anchor-to-anchor links with known distances recover the room's model and which radios read hot. */
    @Test
    fun testCalibrationRecoversModelAndDeviceOffsets() {
        val anchors = mapOf("a" to Pair(0.0, 0.0), "b" to Pair(2.0, 0.0), "c" to Pair(10.0, 0.0), "d" to Pair(0.0, 6.0), "e" to Pair(10.0, 8.0))
        val offsets = mapOf("a" to 4.0, "b" to -2.0, "c" to 0.0, "d" to -2.0, "e" to 0.0)
        val links = mutableListOf<AnchorLinkObservation>()
        for ((observer, p) in anchors) {
            for ((target, q) in anchors) {
                if (observer == target) continue
                val distance = hypot(p.first - q.first, p.second - q.second)
                val rssi = -62 - 25 * log10(distance) + (offsets[observer]!! + offsets[target]!!) / 2
                links.add(AnchorLinkObservation(observer = observer, target = target, distance = distance, rssi = rssi))
            }
        }
        val fit = PathLossCalibration.fit(
            links, prior = PathLossModel(referenceRSSI = -59.0, exponent = 2.2, sigmaDB = 2.0),
            referenceSigmaDB = 20.0, exponentSigma = 2.0,
        )
        assertEquals(20, fit.linkCount)
        assertEquals(-62.0, fit.model.referenceRSSI, 1.0)
        assertEquals(2.5, fit.model.exponent, 0.1)
        assertEquals(6.0, fit.deviceOffsets["a"]!! - fit.deviceOffsets["b"]!!, 1.2)
        assertEquals(0.0, fit.linkOffset("unknown"), 0.0)

        assertEquals(PathLossCalibration.uncalibrated, PathLossCalibration.fit(emptyList()))
    }

    @Test
    fun testRangeSolverFindsPositionFromFourAnchors() {
        val model = PathLossModel.default
        val inputs = listOf(Pair(0.0, 0.0), Pair(10.0, 0.0), Pair(10.0, 8.0), Pair(0.0, 8.0)).map { anchor ->
            RangeInput(
                anchorX = anchor.first, anchorZ = anchor.second, verticalOffset = 0.0,
                rssi = model.predictedRSSI(hypot(3 - anchor.first, 5 - anchor.second)), sigmaDB = 6.0,
            )
        }
        val fix = unwrap(RangeSolver.solve(inputs, model = model))
        assertEquals(3.0, fix.x, 0.05)
        assertEquals(5.0, fix.z, 0.05)
        assertEquals(4, fix.anchorCount)
        assertTrue(fix.accuracy < 10)
        assertNull(RangeSolver.solve(inputs.take(2), model = model))
    }

    /** Standing still, a reading claiming the anchor is 1 m away instead of 5 m is impossible. */
    @Test
    fun testFilterGateRejectsRangeTheStepsCannotExplain() {
        val filter = PositionFilter(x = 0.0, z = 0.0, positionSigma = 0.3, offsetSigmaDB = 1.0)
        val model = PathLossModel.default
        val result = filter.update(
            rssi = model.predictedRSSI(1.0), sigmaDB = 3.0, anchorX = 5.0, anchorZ = 0.0,
            verticalOffset = 0.0, anchorSigma = 0.1, model = model,
        )
        assertEquals(PositionFilter.UpdateResult.rejected, result)
        assertEquals(0.0, filter.x, 0.0)
        assertEquals(0.0, filter.z, 0.0)
    }

    @Test
    fun testFilterStepMovesAlongFrameHeadingAndGrowsUncertainty() {
        val filter = PositionFilter(x = 1.0, z = 1.0, positionSigma = 0.1)
        val before = filter.accuracy
        filter.predict(length = 2.0, heading = Math.PI / 2, alongSigma = 0.2, crossSigma = 0.1, headingDrift = 0.0)
        assertEquals(3.0, filter.x, 1e-9)
        assertEquals(1.0, filter.z, 1e-9)
        assertTrue(filter.accuracy > before)
        filter.observePosition(x = 3.0, z = 1.0, sigma = 0.05)
        assertTrue(filter.accuracy < before)
    }

    /** Value semantics: a copy of the filter evolves on its own (Swift `var f = filter`). */
    @Test
    fun testFilterCopyIsIndependent() {
        val filter = PositionFilter(x = 1.0, z = 1.0, positionSigma = 0.1)
        val copy = filter.copy()
        copy.predict(length = 2.0, heading = 0.0, alongSigma = 0.2, crossSigma = 0.1, headingDrift = 0.1)
        assertEquals(1.0, filter.z, 0.0)
        assertEquals(PositionFilter(x = 1.0, z = 1.0, positionSigma = 0.1).covariance, filter.covariance)
        assertEquals(3.0, copy.z, 1e-9)
    }

    @Test
    fun testMotionAwareRSSIAveragesWhileStillAndDropsImpossibleJumps() {
        val model = PathLossModel.default
        val rssi = MotionAwareRSSI()
        for (k in 0 until 16) {
            rssi.record(if (k % 2 == 0) -55.0 else -65.0, k.toDouble(), moving = false, distance = 4.0, model = model)
        }
        var estimate = unwrap(rssi.estimate(15.0, speed = 0.0, distance = 4.0, model = model))
        assertEquals(-60.0, estimate.rssi, 1e-9)
        assertTrue(estimate.sigmaDB < 5)
        assertEquals(16, rssi.stillSampleCount)

        // A 25 dB drop without moving is a body or door in the way, not a new range...
        assertFalse(rssi.record(-85.0, 16.0, moving = false, distance = 4.0, model = model))
        assertFalse(rssi.record(-85.0, 17.0, moving = false, distance = 4.0, model = model))
        assertEquals(2, rssi.droppedSamples)
        // ...unless it persists: then the new level is accepted.
        assertTrue(rssi.record(-85.0, 18.0, moving = false, distance = 4.0, model = model))
        estimate = unwrap(rssi.estimate(18.0, speed = 0.0, distance = 4.0, model = model))
        assertEquals(-85.0, estimate.rssi, 1e-9)

        // After walking 10 m the same jump is plausible.
        val walking = MotionAwareRSSI()
        walking.record(-60.0, 0.0, moving = true, distance = 4.0, model = model)
        assertTrue(walking.record(-80.0, 1.0, moving = true, walked = 10.0, distance = 4.0, model = model))
        assertNull("stale sample", walking.estimate(10.0, speed = 0.0, distance = 4.0, model = model))
    }

    /**
     * About ten minutes of walking with a radio that reads 4 dB hot, a stride 8% long, a heading
     * 4° off that drifts a further 0.1°/s, noisy RSSI with occasional 15 dB dropouts, and
     * anchors whose radios differ. Dead reckoning alone drifts; the fused estimate stays bounded.
     */
    @Test
    fun testFusionBoundsDeadReckoningDriftOnLongWalk() {
        val noise = Noise(7919UL)
        val truth = PathLossModel(referenceRSSI = -60.0, exponent = 2.3, sigmaDB = 4.0)
        val anchors = mapOf("n1" to Pair(0.0, 0.0), "n2" to Pair(12.0, 0.0), "n3" to Pair(12.0, 10.0), "n4" to Pair(0.0, 10.0))
        val ids = anchors.keys.sorted()
        val anchorOffset = HashMap<String, Double>()
        val shadowing = HashMap<String, Double>()
        for (id in ids) {
            anchorOffset[id] = 3 * noise.gaussian()
            shadowing[id] = 2 * noise.gaussian()
        }
        val phoneOffset = 8.0

        val engine = FusionEngine()
        val links = mutableListOf<AnchorLinkObservation>()
        for (observer in ids) {
            for (target in ids) {
                if (observer == target) continue
                val distance = hypot(anchors[observer]!!.first - anchors[target]!!.first, anchors[observer]!!.second - anchors[target]!!.second)
                val rssi = truth.predictedRSSI(distance) + (anchorOffset[observer]!! + anchorOffset[target]!!) / 2 +
                    3 * noise.gaussian()
                links.add(AnchorLinkObservation(observer = observer, target = target, distance = distance, rssi = rssi))
            }
        }
        engine.setCalibration(PathLossCalibration.fit(links))

        val lap = listOf(
            Pair(2.0, 2.0), Pair(10.0, 2.0), Pair(10.0, 8.0), Pair(2.0, 8.0), Pair(2.0, 4.0), Pair(8.0, 4.0),
            Pair(8.0, 6.0), Pair(4.0, 6.0), Pair(4.0, 9.0), Pair(11.0, 9.0), Pair(11.0, 2.0),
        )
        val route = List(8) { lap }.flatten()
        var x = 2.0
        var z = 2.0
        var deadX = 2.0
        var deadZ = 2.0
        var time = 0.0
        var nextUpdate = 1.0
        val fusedErrors = mutableListOf<Double>()
        val deadErrors = mutableListOf<Double>()
        engine.start(x = 2.0, z = 2.0, heading = 0.0)

        fun advance(end: Double) {
            while (nextUpdate <= end) {
                val sightings = ids.map { id ->
                    val anchor = anchors[id]!!
                    var rssi = truth.predictedRSSI(hypot(x - anchor.first, z - anchor.second)) +
                        (phoneOffset + anchorOffset[id]!!) / 2 + shadowing[id]!! + 4 * noise.gaussian()
                    if (noise.uniform() < 0.05) rssi -= 15
                    AnchorSighting(
                        anchorId = id, position = Position(x = anchor.first, y = 0.0, z = anchor.second),
                        positionAccuracy = null, rssi = swiftRounded(rssi), sampleTime = nextUpdate,
                    )
                }
                engine.update(sightings, nextUpdate)
                val filter = engine.filter
                if (filter != null) {
                    fusedErrors.add(hypot(filter.x - x, filter.z - z))
                    deadErrors.add(hypot(deadX - x, deadZ - z))
                }
                nextUpdate += 1
            }
        }

        for (index in 1 until route.size) {
            val (fromX, fromZ) = route[index - 1]
            val (toX, toZ) = route[index]
            val length = hypot(toX - fromX, toZ - fromZ)
            if (!(length > 0)) continue
            val count = max(1, swiftRounded(length / 0.7).toInt())
            val heading = atan2(toX - fromX, toZ - fromZ)
            for (i in 0 until count) {
                time += 0.55
                x += (toX - fromX) / count.toDouble()
                z += (toZ - fromZ) / count.toDouble()
                val measuredHeading = heading + 4 * Math.PI / 180 + 0.1 * Math.PI / 180 * time + 0.03 * noise.gaussian()
                val measuredLength = length / count.toDouble() * 1.08
                val step = Step(time = time, length = measuredLength, heading = measuredHeading)
                engine.apply(step)
                deadX += step.dx
                deadZ += step.dz
                advance(time)
            }
            time += 8
            advance(time)
        }

        val fusedMean = fusedErrors.fold(0.0) { sum, value -> sum + value } / fusedErrors.size.toDouble()
        val deadMean = deadErrors.fold(0.0) { sum, value -> sum + value } / deadErrors.size.toDouble()
        val filter = unwrap(engine.filter)
        assertTrue("fused mean error $fusedMean m", fusedMean < 3)
        assertTrue("fused $fusedMean m vs dead reckoning $deadMean m", fusedMean < deadMean - 1)
        assertTrue(fusedErrors.last() < 4)
        assertTrue(deadErrors.last() > fusedErrors.last())
        assertEquals(phoneOffset / 2, filter.receiverOffsetDB, 3.0)
        assertTrue(engine.acceptedUpdates > 100)
    }
}
