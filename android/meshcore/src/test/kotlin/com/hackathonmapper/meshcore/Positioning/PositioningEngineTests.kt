package com.hackathonmapper.meshcore

import com.hackathonmapper.meshcore.Positioning as PZ
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.sin

class PositioningEngineTests {
    private fun engine(): PZ.Engine = PZ.Engine(selfId = "phone-b", frameId = "hervanta-v1")

    private fun fix(t: Double, p: PZ.Vec2 = PZ.Vec2.zero, accuracy: Double = 5.0, trusted: Boolean = true): PZ.GNSSFix =
        PZ.GNSSFix(t = t, position = p, horizontalAccuracy = accuracy, trusted = trusted)

    private fun anchor(
        id: String,
        p: PZ.Vec2,
        at: Double,
        kind: PZ.Anchor.Kind = PZ.Anchor.Kind.surveyed,
        sigma: Double = 1.0,
        dependsOn: List<String> = emptyList(),
    ): PZ.Anchor = PZ.Anchor(
        id = id, position = p, sigma = sigma, kind = kind, measuredAt = at,
        speedBound = if (kind == PZ.Anchor.Kind.surveyed) 0.0 else 1.5, dependsOn = dependsOn,
    )

    /** Exact RSSI for the true distance, 5 Hz, from `t0` to `t1`. */
    private fun rssi(e: PZ.Engine, from: String, anchor: PZ.Vec2, truth: PZ.Vec2, t0: Double, t1: Double, offset: Double = 0.0) {
        val value = PZ.PathLossModel.defaultOutdoor.expectedRSSI(distance = anchor.distance(to = truth)) + offset
        var t = t0
        while (t <= t1) {
            e.ingest(rssi = PZ.RSSISample(peerId = from, rssi = value, t = t, channel = PZ.RSSIChannel.advertisement))
            t += 0.2
        }
    }

    /** Phone lying still: zero user acceleration, gravity straight down. */
    private fun still(e: PZ.Engine, t0: Double, t1: Double, bias: Double = 0.0) {
        var t = t0
        while (t <= t1) {
            e.ingest(
                motion = PZ.MotionSample(
                    t = t, gravity = PZ.Vec3(0.0, 0.0, -1.0), userAcceleration = PZ.Vec3(0.0, 0.0, 0.0),
                    rotationRate = PZ.Vec3(0.0, 0.0, -bias),
                ),
            )
            t += 0.02
        }
    }

    @Test
    fun testTrustedFixIsGNSSAndUntrustedFixIsNeverUsed() {
        val e = engine()
        e.ingest(gnss = fix(1.0, PZ.Vec2(x = 5.0, z = 5.0), trusted = false))
        val before = e.estimate(at = 1.0)
        assertEquals(PZ.Estimate.Method.unavailable, before.method)
        assertNull(before.position)
        assertTrue(before.provenance.any { it.source == PZ.Contribution.Source.gnss && !it.used && (it.reason ?: "").contains("integrity") })

        e.ingest(gnss = fix(2.0, PZ.Vec2(x = 5.0, z = 5.0)))
        val after = e.estimate(at = 2.0)
        assertEquals(PZ.Estimate.Method.gnss, after.method)
        assertEquals(0.0, after.position!!.distance(to = PZ.Vec2(x = 5.0, z = 5.0)), 1e-9)
        assertEquals(PositionUncertainty.r95(fromRadius68 = 5.0), after.r95!!, 0.05)
        assertTrue(after.gnssDependent)
    }

    @Test
    fun testOutageWithoutMotionDataWidensAtWalkingPaceAndAges() {
        val e = engine()
        for (t in 0..10) e.ingest(gnss = fix(t.toDouble()))
        val lost = e.estimate(at = 40.0)
        assertEquals(PZ.Estimate.Method.deadReckoning, lost.method)
        assertEquals(30.0, lost.age!!, 1e-9)
        assertTrue(lost.flags.contains(PZ.Estimate.Flag.motionUnavailable))
        assertTrue("nobody counted steps: it may have walked 42 m in any direction", lost.r95!! > 1.4 * 30)
        assertEquals(10.0, lost.lastTrustedGNSS?.t)
    }

    @Test
    fun testStaleFixIsDroppedAndLateFixWithinLagIsUsed() {
        val e = engine()
        e.ingest(gnss = fix(10.0))
        e.estimate(at = 20.0)
        e.ingest(gnss = fix(15.0))
        assertEquals("5 s behind the filter clock is stale", 1, e.diagnostics.staleDropped)
        e.ingest(gnss = fix(19.0))
        assertEquals("1 s late is used", PZ.Estimate.Method.gnss, e.estimate(at = 20.5).method)
    }

    @Test
    fun testRememberedFixSeedsWithWalkingPaceUncertainty() {
        val e = engine()
        e.estimate(at = 100.0)
        e.ingest(gnss = fix(40.0, PZ.Vec2(x = 3.0, z = 4.0)))
        val est = e.estimate(at = 100.0)
        assertEquals(PZ.Vec2(x = 3.0, z = 4.0), est.position!!)
        assertTrue("60 s unaccounted for", est.r95!! > 1.4 * 60 * 2)
    }

    @Test
    fun testOneAnchorGivesAProximityRegionNotAPoint() {
        val e = engine()
        val a = PZ.Vec2(x = 0.0, z = 0.0)
        val truth = PZ.Vec2(x = 9.0, z = 8.0)
        e.ingest(anchor = anchor("phone-a", a, at = 0.0, kind = PZ.Anchor.Kind.gnss, sigma = 3.3))
        rssi(e, from = "phone-a", anchor = a, truth = truth, 0.0, 9.0)
        val est = e.estimate(at = 9.0)
        assertEquals(PZ.Estimate.Method.proximity, est.method)
        assertNull("a neighbour's coordinate is not our position", est.position)
        assertEquals(a, est.regionCenter)
        assertTrue(est.r95!! >= truth.distance(to = a))
        assertEquals(listOf("phone-a"), est.anchorIds)
        assertTrue(est.gnssDependent)
    }

    @Test
    fun testTwoAnchorsAreAmbiguous() {
        val e = engine()
        val truth = PZ.Vec2(x = 10.0, z = 8.0)
        for ((id, p) in listOf("phone-a" to PZ.Vec2(x = 0.0, z = 0.0), "phone-c" to PZ.Vec2(x = 20.0, z = 0.0))) {
            e.ingest(anchor = anchor(id, p, at = 0.0))
            rssi(e, from = id, anchor = p, truth = truth, 0.0, 9.0)
        }
        val est = e.estimate(at = 9.0)
        assertEquals(PZ.Estimate.Method.ambiguous, est.method)
        assertNull(est.position)
        assertEquals(2, est.candidates.size)
        assertTrue(est.candidates.minOf { it.distance(to = truth) } < 1.5)
    }

    @Test
    fun testThreeAnchorsMultilaterate() {
        val e = engine()
        val truth = PZ.Vec2(x = 14.0, z = 9.0)
        for ((id, p) in listOf("phone-a" to PZ.Vec2(x = 0.0, z = 0.0), "phone-c" to PZ.Vec2(x = 30.0, z = 0.0), "phone-d" to PZ.Vec2(x = 15.0, z = 26.0))) {
            e.ingest(anchor = anchor(id, p, at = 0.0))
            rssi(e, from = id, anchor = p, truth = truth, 0.0, 9.0)
        }
        val est = e.estimate(at = 9.0)
        assertEquals(PZ.Estimate.Method.multilateration, est.method)
        assertTrue(est.position!!.distance(to = truth) < est.r95!!)
        assertEquals(setOf("phone-a", "phone-c", "phone-d"), est.anchorIds.toSet())
    }

    @Test
    fun testStaleAnchorIsIgnored() {
        val e = engine()
        e.ingest(anchor = anchor("phone-a", PZ.Vec2.zero, at = 0.0, kind = PZ.Anchor.Kind.gnss))
        rssi(e, from = "phone-a", anchor = PZ.Vec2.zero, truth = PZ.Vec2(x = 5.0, z = 0.0), 40.0, 50.0)
        assertEquals("an anchor position 50 s old is not used", PZ.Estimate.Method.unavailable, e.estimate(at = 50.0).method)
    }

    @Test
    fun testEstimatedAnchorThatDependsOnThisPhoneIsRefused() {
        val e = engine()
        e.ingest(anchor = anchor("phone-c", PZ.Vec2.zero, at = 0.0, kind = PZ.Anchor.Kind.estimated, sigma = 4.0, dependsOn = listOf("phone-c", "phone-b")))
        rssi(e, from = "phone-c", anchor = PZ.Vec2.zero, truth = PZ.Vec2(x = 5.0, z = 0.0), 0.0, 9.0)
        assertEquals(1, e.diagnostics.anchorsRefused)
        assertEquals(PZ.Estimate.Method.unavailable, e.estimate(at = 9.0).method)
    }

    @Test
    fun testWithdrawnAnchorStopsAnchoringAtOnce() {
        val e = engine()
        val truth = PZ.Vec2(x = 14.0, z = 9.0)
        val spots = listOf("phone-a" to PZ.Vec2(x = 0.0, z = 0.0), "phone-c" to PZ.Vec2(x = 30.0, z = 0.0), "phone-d" to PZ.Vec2(x = 15.0, z = 26.0))
        for ((id, p) in spots) {
            e.ingest(anchor = anchor(id, p, at = 0.0))
            rssi(e, from = id, anchor = p, truth = truth, 0.0, 9.0)
        }
        assertTrue(e.estimate(at = 9.0).anchorIds.contains("phone-c"))
        e.removeAnchor("phone-c", at = 9.5, reason = "GNSS rejected: positionJump")
        val est = e.estimate(at = 10.0)
        assertFalse(est.anchorIds.contains("phone-c"))
        val c = est.provenance.filter { it.peerId == "phone-c" }
        assertEquals(1, c.size)
        assertEquals(false, c.firstOrNull()?.used)
        assertEquals("GNSS rejected: positionJump", c.firstOrNull()?.reason)
    }

    @Test
    fun testGyroBiasIsLearnedWhileStill() {
        val e = engine()
        e.ingest(compass = PZ.CompassSample(t = 0.0, heading = 0.0, sigma = PZ.degrees(5.0)))
        still(e, 0.02, 20.0, bias = 0.004)
        assertEquals(0.004, e.gyroBiasEstimate, 0.0005)
        assertEquals("a still phone's heading does not drift", 0.0, e.estimate(at = 20.0).heading!!, PZ.degrees(1.0))
    }

    @Test
    fun testHeadingUncertaintyGrowsWithoutCompass() {
        val e = engine()
        e.declare(position = PZ.Vec2.zero, sigma = 1.0, at = 0.0)
        e.ingest(compass = PZ.CompassSample(t = 0.0, heading = 0.0, sigma = PZ.degrees(3.0)))
        val start = e.estimate(at = 0.01).headingSigma!!
        var t = 0.02
        while (t < 300) {
            val a = 0.3 * sin(2 * PI * 1.8 * t)
            e.ingest(
                motion = PZ.MotionSample(
                    t = t, gravity = PZ.Vec3(0.0, 0.0, -1.0), userAcceleration = PZ.Vec3(0.0, 0.0, a),
                    rotationRate = PZ.Vec3(0.0, 0.0, 0.0),
                ),
            )
            t += 0.02
        }
        assertTrue("gyro-only heading drifts and says so", e.estimate(at = t).headingSigma!! > 1.5 * start)
    }

    @Test
    fun testRepeatedRSSIFromAStaticLinkDoesNotCollapseTheUncertainty() {
        // A phone lying still 12 m from an anchor in a spot whose shadowing reads 5 dB weak. Ten
        // minutes of identical evidence must not shrink the circle to the biased range.
        val e = engine()
        val truth = PZ.Vec2(x = 12.0, z = 0.0)
        e.declare(position = PZ.Vec2(x = 13.0, z = 1.0), sigma = 2.5, at = 0.0)
        e.ingest(anchor = anchor("marker", PZ.Vec2.zero, at = 0.0, sigma = 0.3))
        val rng = SimRandom(seed = 9uL)
        var t = 0.0
        val r95s = ArrayList<Double>()
        var contained = 0
        var checks = 0
        while (t < 600) {
            still(e, t + 0.02, t + 1)
            val value = PZ.PathLossModel.defaultOutdoor.expectedRSSI(distance = 12.0) - 5
            for (k in 0 until 5) {
                e.ingest(
                    rssi = PZ.RSSISample(
                        peerId = "marker", rssi = swiftRounded(value + 2.5 * rng.gauss()),
                        t = t + 0.2 * (k + 1).toDouble(), channel = PZ.RSSIChannel.advertisement,
                    ),
                )
            }
            e.ingest(anchor = anchor("marker", PZ.Vec2.zero, at = t + 1, sigma = 0.3))
            t += 1
            val est = e.estimate(at = t)
            val p = est.position
            val r = est.r95
            if (p != null && r != null) {
                r95s.add(r)
                checks += 1
                if (p.distance(to = truth) <= r) contained += 1
            }
        }
        assertTrue(e.diagnostics.rangeUpdates > 50)
        assertTrue("shadowing is a state: static evidence cannot make it metre-precise", r95s.last() > 2)
        assertTrue(contained.toDouble() / checks.toDouble() >= 0.95)
    }
}
