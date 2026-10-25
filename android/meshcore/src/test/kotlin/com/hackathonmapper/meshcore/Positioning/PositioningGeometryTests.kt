package com.hackathonmapper.meshcore

import com.hackathonmapper.meshcore.Positioning as PZ
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt

class PositioningGeometryTests {
    private val model = PZ.PathLossModel.defaultOutdoor

    private fun observation(
        id: String,
        at: PZ.Vec2,
        truth: PZ.Vec2,
        offset: Double = 0.0,
        sigma: Double = 1.0,
        t: Double = 10.0,
    ): PZ.RangeObservation {
        val anchor = at
        val rssi = model.expectedRSSI(distance = anchor.distance(to = truth)) + offset
        val window = PZ.RSSIWindow(
            peerId = id, channel = PZ.RSSIChannel.advertisement, median = rssi, spread = 2.0, count = 20, rejected = 0,
            start = t - 4, end = t, t = t - 2,
        )
        val a = PZ.Anchor(id = id, position = anchor, sigma = sigma, kind = PZ.Anchor.Kind.surveyed, measuredAt = t, speedBound = 0.0)
        return PZ.RangeObservation(anchor = a, window = window, model = model)
    }

    private fun <T> unwrap(value: T?): T {
        assertNotNull(value)
        return value!!
    }

    @Test
    fun testOneAnchorIsADiscAroundTheAnchorNeverAPoint() {
        val anchor = PZ.Vec2(x = 0.0, z = 0.0)
        val truth = PZ.Vec2(x = 12.0, z = 5.0)
        for (offset in listOf(0.0, -10.0, 6.0)) {
            val s = unwrap(PZ.RangeGeometry.solve(listOf(observation("phone-a", at = anchor, truth = truth, offset = offset))))
            assertEquals(PZ.GeometrySolution.Kind.proximity, s.kind)
            assertEquals("the region is centred on the anchor; the anchor's coordinate is not our position", anchor, s.center)
            assertTrue(s.candidates.isEmpty())
            assertTrue("disc must hold the truth (offset $offset dB)", s.r95 >= truth.distance(to = anchor))
        }
    }

    @Test
    fun testTwoAnchorsLeaveTwoMirrorCandidates() {
        val truth = PZ.Vec2(x = 10.0, z = 8.0)
        val s = unwrap(
            PZ.RangeGeometry.solve(
                listOf(
                    observation("phone-a", at = PZ.Vec2(x = 0.0, z = 0.0), truth = truth),
                    observation("phone-c", at = PZ.Vec2(x = 20.0, z = 0.0), truth = truth),
                ),
            ),
        )
        assertEquals(PZ.GeometrySolution.Kind.ambiguous, s.kind)
        assertEquals(2, s.candidates.size)
        assertTrue(s.candidates.minOf { it.distance(to = truth) } < 1)
        assertTrue("the mirror spot fits equally well", s.candidates.minOf { it.distance(to = PZ.Vec2(x = 10.0, z = -8.0)) } < 1)
        assertTrue(s.r95 >= s.center.distance(to = truth))
    }

    @Test
    fun testThreeWellPlacedAnchorsMultilaterate() {
        val truth = PZ.Vec2(x = 14.0, z = 9.0)
        val s = unwrap(
            PZ.RangeGeometry.solve(
                listOf(
                    observation("phone-a", at = PZ.Vec2(x = 0.0, z = 0.0), truth = truth),
                    observation("phone-c", at = PZ.Vec2(x = 30.0, z = 0.0), truth = truth),
                    observation("phone-d", at = PZ.Vec2(x = 15.0, z = 26.0), truth = truth),
                ),
            ),
        )
        assertEquals(PZ.GeometrySolution.Kind.multilateration, s.kind)
        assertTrue(s.center.distance(to = truth) < 0.5)
        assertTrue(unwrap(s.hdop) < PZ.RangeGeometry.maxHDOP)
        assertTrue("RSSI ranges cannot give metre-level precision", s.r95 > 3)
    }

    @Test
    fun testCollinearAnchorsDoNotClaimAPoint() {
        val truth = PZ.Vec2(x = 12.0, z = 10.0)
        val s = unwrap(
            PZ.RangeGeometry.solve(
                listOf(
                    observation("phone-a", at = PZ.Vec2(x = 0.0, z = 0.0), truth = truth),
                    observation("phone-c", at = PZ.Vec2(x = 15.0, z = 0.0), truth = truth),
                    observation("phone-d", at = PZ.Vec2(x = 30.0, z = 0.0), truth = truth),
                ),
            ),
        )
        assertNotEquals("a mirror solution across the anchor line fits as well", PZ.GeometrySolution.Kind.multilateration, s.kind)
        assertTrue(s.r95 >= s.center.distance(to = truth))
    }

    @Test
    fun testClusteredAnchorsFallBackToADisc() {
        val truth = PZ.Vec2(x = 40.0, z = 30.0)
        val s = unwrap(
            PZ.RangeGeometry.solve(
                listOf(
                    observation("phone-a", at = PZ.Vec2(x = 0.0, z = 0.0), truth = truth),
                    observation("phone-c", at = PZ.Vec2(x = 1.0, z = 0.0), truth = truth),
                    observation("phone-d", at = PZ.Vec2(x = 0.0, z = 1.0), truth = truth),
                ),
            ),
        )
        assertNotEquals(PZ.GeometrySolution.Kind.multilateration, s.kind)
        assertTrue(s.r95 >= s.center.distance(to = truth))
    }

    @Test
    fun testNoisyMultilaterationRadiusHoldsTheTruth() {
        // Readings scatter by the model's own spread; the reported r95 should hold the truth ~95 %.
        val rng = SimRandom(seed = 21uL)
        val anchors = listOf(PZ.Vec2(x = 0.0, z = 0.0), PZ.Vec2(x = 40.0, z = 0.0), PZ.Vec2(x = 40.0, z = 40.0), PZ.Vec2(x = 0.0, z = 40.0))
        var solved = 0
        var contained = 0
        for (k in 0 until 300) {
            val truth = PZ.Vec2(x = rng.uniform(5.0, 35.0), z = rng.uniform(5.0, 35.0))
            val obs = anchors.mapIndexed { i, a ->
                observation("phone-$i", at = a, truth = truth, offset = model.totalSigma * rng.gauss())
            }
            val s = PZ.RangeGeometry.solve(obs)
            if (s == null || s.kind != PZ.GeometrySolution.Kind.multilateration) continue
            solved += 1
            if (s.center.distance(to = truth) <= s.r95) contained += 1
        }
        assertTrue(solved > 200)
        assertTrue("$contained/$solved", contained.toDouble() / solved.toDouble() >= 0.85)
    }

    @Test
    fun testWeakReadingNearSensitivityOnlySaysFar() {
        // At the edge of range only the fades up are heard, so the median reads too strong: a phone
        // 90 m away whose surviving samples read like 55 m. The disc must still hold it.
        val survivorRSSI = model.expectedRSSI(distance = 55.0)
        assertTrue(model.isCensored(rssi = survivorRSSI))
        assertEquals(model.maxRange, model.distanceInterval(rssi = survivorRSSI).upperBound, 0.0)
        val truth = PZ.Vec2(x = 90.0, z = 0.0)
        val window = PZ.RSSIWindow(
            peerId = "phone-a", channel = PZ.RSSIChannel.advertisement, median = survivorRSSI, spread = 2.0, count = 6,
            rejected = 0, start = 6.0, end = 10.0, t = 8.0,
        )
        val a = PZ.Anchor(id = "phone-a", position = PZ.Vec2.zero, sigma = 3.0, kind = PZ.Anchor.Kind.gnss, measuredAt = 10.0, speedBound = 0.0)
        val s = unwrap(PZ.RangeGeometry.solve(listOf(PZ.RangeObservation(anchor = a, window = window, model = model))))
        assertTrue(s.r95 >= truth.distance(to = PZ.Vec2.zero))
        assertFalse("a 30 m reading is well above the floor", model.isCensored(rssi = model.expectedRSSI(distance = 30.0)))
    }

    @Test
    fun testAnchorUncertaintyGrowsWithAge() {
        val a = PZ.Anchor(id = "phone-a", position = PZ.Vec2.zero, sigma = 3.0, kind = PZ.Anchor.Kind.gnss, measuredAt = 0.0, timeSigma = 0.5, speedBound = 1.5)
        assertEquals(sqrt(9 + 0.5625), a.sigma(at = 0.0), 1e-9)
        assertTrue(a.sigma(at = 10.0) > 15)
        val fixed = PZ.Anchor(id = "marker", position = PZ.Vec2.zero, sigma = 0.5, kind = PZ.Anchor.Kind.surveyed, measuredAt = 0.0, speedBound = 0.0)
        assertEquals(0.5, fixed.sigma(at = 100.0), 0.0)
    }
}
