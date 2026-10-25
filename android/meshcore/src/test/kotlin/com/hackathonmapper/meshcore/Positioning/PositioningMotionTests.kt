package com.hackathonmapper.meshcore

import com.hackathonmapper.meshcore.Positioning as PZ
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** Axis and sign checks: get these wrong and every later accuracy number is meaningless. */
class PositioningMotionTests {
    private val flat = PZ.Vec3(0.0, 0.0, -1.0)

    private fun motion(
        t: Double,
        gravity: PZ.Vec3 = PZ.Vec3(0.0, 0.0, -1.0),
        accel: PZ.Vec3 = PZ.Vec3(0.0, 0.0, 0.0),
        rotation: PZ.Vec3 = PZ.Vec3(0.0, 0.0, 0.0),
    ): PZ.MotionSample = PZ.MotionSample(t = t, gravity = gravity, userAcceleration = accel, rotationRate = rotation)

    @Test
    fun testTurningClockwiseIncreasesHeading() {
        // Flat, screen up: device z is up; a negative rotation about z is clockwise seen from above.
        assertEquals(0.5, PZ.DeviceAxes.headingRate(motion(0.0, rotation = PZ.Vec3(0.0, 0.0, -0.5)))!!, 1e-12)
    }

    @Test
    fun testHeadingRateDoesNotDependOnHowThePhoneIsHeld() {
        // Upright in portrait: device y is up.
        val upright = motion(0.0, gravity = PZ.Vec3(0.0, -1.0, 0.0), rotation = PZ.Vec3(0.0, 0.3, 0.0))
        assertEquals(-0.3, PZ.DeviceAxes.headingRate(upright)!!, 1e-12)
    }

    /** Earth's field near Tampere expressed in a device frame whose forward axis points at `heading`. */
    private fun field(heading: Double, upright: Boolean): Pair<PZ.Vec3, PZ.Vec3> {
        val h = heading
        val east = PZ.Vec3(1.0, 0.0, 0.0)
        val north = PZ.Vec3(0.0, 1.0, 0.0)
        val up = PZ.Vec3(0.0, 0.0, 1.0)
        val world = north.scaled(15.0) - up.scaled(50.0)
        val forward = east.scaled(sin(h)) + north.scaled(cos(h))
        val right = east.scaled(cos(h)) - north.scaled(sin(h))
        val (x, y, z) = if (upright) Triple(right, up, forward.scaled(-1.0)) else Triple(right, forward, up)
        val b = PZ.Vec3(world.dot(x), world.dot(y), world.dot(z))
        val g = PZ.Vec3(-up.dot(x), -up.dot(y), -up.dot(z))
        return Pair(b, g)
    }

    @Test
    fun testCompassIsTiltCompensatedFlatAndUpright() {
        for (degrees in listOf(0.0, 37.0, 90.0, 181.0, 300.0)) {
            val h = PZ.degrees(degrees)
            for (upright in listOf(false, true)) {
                val (b, g) = field(heading = h, upright = upright)
                val out = PZ.Compass.heading(magneticField = b, gravity = g, declination = 0.0)!!
                assertEquals("$degrees° upright $upright", 0.0, PZ.wrap(out.heading - h), 1e-9)
            }
        }
        val (b, g) = field(heading = 0.0, upright = false)
        val declined = PZ.Compass.heading(magneticField = b, gravity = g, declination = PZ.Compass.tampereDeclination)!!
        assertEquals("true = magnetic + declination", PZ.Compass.tampereDeclination, declined.heading, 1e-9)
    }

    @Test
    fun testCompassDisturbanceIsDetected() {
        assertTrue(!PZ.Compass.isDisturbed(strength = 52.5, dip = PZ.degrees(74.0)))
        assertTrue("steel nearby", PZ.Compass.isDisturbed(strength = 70.0, dip = PZ.degrees(74.0)))
        assertTrue(PZ.Compass.isDisturbed(strength = 52.0, dip = PZ.degrees(55.0)))
    }

    @Test
    fun testStepDetectorCountsWalkingSteps() {
        val detector = PZ.StepDetector()
        val rng = SimRandom(seed = 4uL)
        val steps = ArrayList<PZ.StepEvent>()
        var t = 0.0
        while (t < 30) {
            val a = 0.3 * sin(2 * PI * 1.8 * t) + 0.02 * rng.gauss()
            detector.add(motion(t, gravity = flat, accel = PZ.Vec3(0.0, 0.0, a)))?.let { steps.add(it) }
            t += 0.02
        }
        assertEquals(54.0, steps.size.toDouble(), 3.0)
        val lengths = steps.drop(1).map { it.length }
        assertEquals("Weinberg at 0.6 g peak to peak", 0.70, lengths.sum() / lengths.size, 0.05)
    }

    @Test
    fun testNoStepsWhileStill() {
        val detector = PZ.StepDetector()
        val rng = SimRandom(seed = 5uL)
        var count = 0
        for (i in 0 until 1_500) {
            if (detector.add(motion(i * 0.02, accel = PZ.Vec3(0.0, 0.0, 0.003 * rng.gauss()))) != null) count += 1
        }
        assertEquals(0, count)
    }

    @Test
    fun testStillnessReportsTheGyroBias() {
        val still = PZ.StationarityDetector()
        var result: Double? = null
        for (i in 0 until 100) result = still.add(motion(i * 0.02, rotation = PZ.Vec3(0.0, 0.0, -0.004)))
        assertNotNull(result)
        assertEquals(0.004, result!!, 1e-9)
        val walking = PZ.StationarityDetector()
        for (i in 0 until 100) {
            result = walking.add(motion(i * 0.02, accel = PZ.Vec3(0.0, 0.0, 0.3 * sin(i * 0.2))))
        }
        assertNull(result)
    }

    // MARK: - Frames through the engine

    private fun walk(engine: PZ.Engine, from: Double, seconds: Double, rotation: Double = 0.0): Double {
        val t0 = from
        var t = t0
        while (t < t0 + seconds) {
            t += 0.02
            val a = 0.3 * sin(2 * PI * 1.8 * (t - t0))
            engine.ingest(motion = motion(t, accel = PZ.Vec3(0.0, 0.0, a), rotation = PZ.Vec3(0.0, 0.0, rotation)))
        }
        return t
    }

    @Test
    fun testWalkingEastIsPositiveXAndNorthIsPositiveZ() {
        val engine = PZ.Engine(selfId = "phone-b", frameId = "hervanta-v1")
        engine.declare(position = PZ.Vec2.zero, sigma = 1.0, at = 0.0)
        engine.ingest(compass = PZ.CompassSample(t = 0.01, heading = PI / 2, sigma = PZ.degrees(3.0)))
        var t = walk(engine, from = 0.01, seconds = 10.0)
        val east = engine.estimate(at = t).position!!
        assertTrue(east.x > 9)
        assertEquals(0.0, east.z, 1.5)

        // A compass that jumps 90° while the gyro saw no turn is gated out as inconsistent...
        engine.ingest(compass = PZ.CompassSample(t = t + 0.01, heading = 0.0, sigma = PZ.degrees(3.0)))
        assertEquals(PI / 2, engine.estimate(at = t + 0.01).heading!!, PZ.degrees(3.0))
        // ...a real left turn shows on the gyro.
        val turnEnd = t + 2
        while (t < turnEnd) {
            t += 0.02
            engine.ingest(motion = motion(t, rotation = PZ.Vec3(0.0, 0.0, PI / 4)))
        }
        t = walk(engine, from = t, seconds = 10.0)
        val north = engine.estimate(at = t).position!!
        assertTrue(north.z - east.z > 9)
        assertEquals(0.0, north.x - east.x, 2.5)
    }

    @Test
    fun testGyroTurnRightWithoutCompass() {
        val engine = PZ.Engine(selfId = "phone-b", frameId = "hervanta-v1")
        engine.declare(position = PZ.Vec2.zero, sigma = 1.0, at = 0.0)
        engine.ingest(compass = PZ.CompassSample(t = 0.01, heading = 0.0, sigma = PZ.degrees(2.0)))
        // Turn 90° clockwise on the spot over 2 s, then walk.
        var t = 0.01
        while (t < 2.01) {
            t += 0.02
            engine.ingest(motion = motion(t, rotation = PZ.Vec3(0.0, 0.0, -PI / 4)))
        }
        assertEquals(PI / 2, engine.estimate(at = t).heading!!, PZ.degrees(3.0))
        t = walk(engine, from = t, seconds = 10.0)
        val p = engine.estimate(at = t).position!!
        assertTrue("after a right turn from north the phone walks east", p.x > 9)
        assertEquals(0.0, p.z, 2.0)
    }
}
