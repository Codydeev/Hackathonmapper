package com.hackathonmapper.meshcore

import com.hackathonmapper.meshcore.Positioning as PZ
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import kotlin.math.abs
import kotlin.math.log10

class PositioningRSSITests {
    private fun sample(
        rssi: Double,
        t: Double,
        peer: String = "phone-a",
        channel: PZ.RSSIChannel = PZ.RSSIChannel.advertisement,
    ): PZ.RSSISample = PZ.RSSISample(peerId = peer, rssi = rssi, t = t, channel = channel)

    @Test
    fun testMedianIgnoresDeepFadeAndSpike() {
        val filter = PZ.RSSIMedianFilter(window = 4.0)
        val values = listOf(-70.0, -71.0, -69.0, -70.0, -95.0, -72.0, -93.0, -70.0, -71.0, -69.0)
        for ((i, v) in values.withIndex()) assertTrue(filter.add(sample(v, i * 0.4)))
        val w = filter.current(peerId = "phone-a", channel = PZ.RSSIChannel.advertisement, now = 3.9)
        assertNotNull(w)
        w!!
        assertEquals(-70.0, w.median, 0.01)
        assertEquals("the two deep fades are Hampel outliers", 2, w.rejected)
        assertEquals(8, w.count)
        val mean = values.sum() / values.size
        assertTrue("a mean would have been pulled by several dB", abs(mean + 70) > 2)
    }

    @Test
    fun testInvalidReadingsAreDropped() {
        val filter = PZ.RSSIMedianFilter()
        assertFalse("iOS reports 127 when it has no reading", filter.add(sample(127.0, 0.0)))
        assertFalse(filter.add(sample(-128.0, 0.0)))
        assertFalse(filter.add(sample(21.0, 0.0)))
        assertFalse(filter.add(sample(Double.NaN, 0.0)))
        assertTrue(filter.add(sample(-60.0, 0.0)))
    }

    @Test
    fun testWindowsDoNotOverlapAndUseEachSampleOnce() {
        val filter = PZ.RSSIMedianFilter(window = 4.0)
        for (i in 0..50) filter.add(sample(-70.0, i * 0.2))
        assertTrue("less than one window of samples yet", filter.takeWindows(now = 3.9).isEmpty())
        val first = filter.takeWindows(now = 4.0)
        assertEquals(1, first.size)
        assertEquals(21, first.firstOrNull()?.count)
        assertTrue(filter.takeWindows(now = 5.0).isEmpty())
        val second = filter.takeWindows(now = 8.3)
        assertEquals(21, second.firstOrNull()?.count)
        assertTrue((second.firstOrNull()?.start ?: 0.0) > (first.firstOrNull()?.end ?: Double.POSITIVE_INFINITY))
        assertFalse("older than samples already handed out", filter.add(sample(-70.0, 3.0)))
    }

    @Test
    fun testStaleSamplesAreDroppedUnused() {
        val filter = PZ.RSSIMedianFilter(window = 4.0)
        for (i in 0 until 10) filter.add(sample(-70.0, i * 0.1))
        assertTrue(filter.takeWindows(now = 20.0).isEmpty())
    }

    @Test
    fun testLateSampleKeepsTimeOrder() {
        val filter = PZ.RSSIMedianFilter(window = 4.0, minSamples = 1)
        filter.add(sample(-70.0, 1.0))
        filter.add(sample(-72.0, 0.5))
        assertEquals(0.5, filter.current(peerId = "phone-a", channel = PZ.RSSIChannel.advertisement, now = 1.0)?.start)
    }

    @Test
    fun testRelayedSmoothedValueIsOneWindow() {
        val filter = PZ.RSSIMedianFilter(window = 4.0)
        filter.add(sample(-66.0, 1.0, channel = PZ.RSSIChannel.relayedSmoothed))
        val windows = filter.takeWindows(now = 1.0)
        assertEquals(1, windows.size)
        assertEquals(-66.0, windows.firstOrNull()?.median)
    }

    @Test
    fun testDistanceIntervalIsWideAndHonest() {
        val model = PZ.PathLossModel.defaultOutdoor
        val rssi = model.expectedRSSI(distance = 10.0)
        assertEquals(10.0, model.medianDistance(rssi = rssi), 1e-6)
        val interval = model.distanceInterval(rssi = rssi)
        assertTrue(interval.contains(10.0))
        assertTrue("5.6 dB of spread is a factor ~2.7 in distance at 95 %", interval.lowerBound < 4)
        assertTrue(interval.upperBound > 25)
    }

    // MARK: - Calibration

    private fun calibrationSession(p0: Double, n: Double, distances: List<Double>, seed: ULong): PZ.CalibrationSession {
        val rng = SimRandom(seed = seed)
        val session = PZ.CalibrationSession(
            peerId = "phone-a", channel = PZ.RSSIChannel.advertisement, observerModel = "iPhone17,1",
            peerModel = "iPhone16,1", environment = "Hervanta field",
        )
        var t = 0.0
        for (d in distances) {
            session.begin(distance = d, label = "in hand, facing")
            val spot = 2 * rng.gauss()
            for (k in 0 until 150) {
                t += 0.2
                var rssi = p0 - 10 * n * log10(d) + spot + 3 * rng.gauss()
                if (rng.next() < 0.05) rssi -= 15
                session.record(sample(swiftRounded(rssi), t))
            }
            assertTrue(session.isStepComplete)
            session.end()
            t += 30
        }
        return session
    }

    @Test
    fun testCalibrationRecoversPathLoss() {
        val session = calibrationSession(p0 = -61.0, n = 2.2, distances = PZ.CalibrationSession.suggestedDistances, seed = 7uL)
        val result = session.fit(window = 4.0, date = "2026-10-24")
        assertEquals(-61.0, result.model.p0, 3.0)
        assertEquals(2.2, result.model.n, 0.4)
        assertEquals(7, result.distances.size)
        assertTrue("one walk cannot measure shadowing below 3 dB", result.model.sigmaShadow >= 3)
        assertTrue(result.model.sigmaFast < 4)
        assertTrue(result.leaveOneOutRangeError < 0.5)
        assertTrue(result.model.source.contains("calibrated 2026-10-24"))
    }

    @Test
    fun testCalibrationAtTheFieldTestDistances() {
        // ARCHITECTURE.md T2 records 2, 5, 10 and 20 m.
        val session = calibrationSession(p0 = -58.0, n = 2.5, distances = listOf(2.0, 5.0, 10.0, 20.0), seed = 11uL)
        val result = session.fit()
        assertEquals(2.5, result.model.n, 0.6)
        assertTrue(result.warnings.any { it.contains("Fewer than 5 distances") })
    }

    @Test
    fun testCalibrationRefusesTooFewDistances() {
        val session = calibrationSession(p0 = -60.0, n = 2.0, distances = listOf(1.0, 8.0), seed = 3uL)
        try {
            session.fit()
            fail("expected an error")
        } catch (e: PZ.CalibrationError) {
            assertEquals(PZ.CalibrationError.tooFewDistances(found = 2), e)
        }
    }

    @Test
    fun testCalibrationRefusesNarrowSpan() {
        val session = calibrationSession(p0 = -60.0, n = 2.0, distances = listOf(2.0, 3.0, 4.0), seed = 3uL)
        try {
            session.fit()
            fail("expected an error")
        } catch (e: PZ.CalibrationError) {
            if (e !is PZ.CalibrationError.distanceSpanTooSmall) fail("$e")
        }
    }

    @Test
    fun testCalibrationOnlyRecordsThePeerDuringAStep() {
        val session = PZ.CalibrationSession(
            peerId = "phone-a", channel = PZ.RSSIChannel.advertisement, observerModel = "a", peerModel = "b", environment = "",
        )
        assertFalse("no step active", session.record(sample(-60.0, 0.0)))
        session.begin(distance = 2.0)
        assertFalse(session.record(sample(-60.0, 1.0, peer = "phone-c")))
        assertFalse(session.record(sample(-60.0, 1.0, channel = PZ.RSSIChannel.connection)))
        assertTrue(session.record(sample(-60.0, 1.0)))
    }
}
