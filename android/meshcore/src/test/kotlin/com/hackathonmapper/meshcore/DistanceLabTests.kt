package com.hackathonmapper.meshcore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Track tab's distance comparison: each method's reading of one link, and a tape-measure trial.
 * Port of ios/MeshCore/Tests/MeshCoreTests/DistanceLabTests.swift.
 */
class DistanceLabTests {
    private val radio = RadioModel.standard

    @Test
    fun testEachMethodReadsItsOwnInput() {
        val lab = DistanceLab()
        lab.calibratedRadio = RadioModel(p0 = -63.0, n = 2.2, sigma = 5.0, range = 60.0, soft = 8.0)
        val inputs = DistanceInputs(
            uwb = 3.0, smoothedRSSI = radio.expectedRSSI(5.0), peerRSSI = -62.0, signalMap = 4.2,
            ownGPS = FloorPoint(x = 0.0, z = 0.0), ownGPSR95 = 3.0, peerGPS = FloorPoint(x = 3.0, z = 4.0), peerGPSR95 = 4.0,
        )
        val readings = lab.readings(peerId = "peer", inputs = inputs, now = 100.0)
        fun reading(method: DistanceMethod): DistanceReading {
            val found = readings.firstOrNull { it.method == method }
            assertNotNull(found)
            return found!!
        }

        assertEquals(
            listOf(DistanceMethod.uwb, DistanceMethod.signalMap, DistanceMethod.rssiCalibrated, DistanceMethod.rssiDefault, DistanceMethod.gps),
            readings.map { it.method },
        )
        val uwb = reading(DistanceMethod.uwb)
        assertEquals(3.0, uwb.meters, 0.0)
        assertEquals(3 - 1.96 * SignalMap.uwbSigma, uwb.low ?: 0.0, 1e-9)
        assertEquals(4.2, reading(DistanceMethod.signalMap).meters, 0.0)
        assertNull(reading(DistanceMethod.signalMap).low)
        val defaultModel = reading(DistanceMethod.rssiDefault)
        assertEquals(5.0, defaultModel.meters, 1e-9)
        assertTrue((defaultModel.low ?: 99.0) < 5)
        assertTrue((defaultModel.high ?: 0.0) > 5)
        // Both ends averaged, through the calibrated model.
        val mean = (radio.expectedRSSI(5.0) + -62) / 2
        assertEquals(lab.calibratedRadio.distance(mean), reading(DistanceMethod.rssiCalibrated).meters, 1e-9)
        val gps = reading(DistanceMethod.gps)
        assertEquals(5.0, gps.meters, 1e-9)
        assertEquals(0.0, gps.low ?: -1.0, 1e-9)
        assertEquals(10.0, gps.high ?: 0.0, 1e-9)
    }

    @Test
    fun testNothingMeasuredMeansNoReadings() {
        assertTrue(DistanceLab().readings(peerId = "peer", inputs = DistanceInputs(), now = 0.0).isEmpty())
    }

    /**
     * GhostCore's median filter: three raw samples in 4 s, a deep fade dropped as an outlier, and
     * samples resent by the next second's list counted once.
     */
    @Test
    fun testMedianFilterNeedsThreeSamplesDropsOutliersAndDeduplicates() {
        val lab = DistanceLab()
        lab.add(rawRSSI = listOf(Pair(-60.0, 10.0), Pair(-61.0, 11.0)), from = "peer")
        lab.add(rawRSSI = listOf(Pair(-60.0, 10.0), Pair(-61.0, 11.0)), from = "peer")
        assertNull(lab.readings(peerId = "peer", inputs = DistanceInputs(), now = 11.5).firstOrNull { it.method == DistanceMethod.rssiMedian })

        lab.add(rawRSSI = listOf(Pair(-61.0, 11.0), Pair(-60.0, 12.0), Pair(-90.0, 12.5)), from = "peer")
        val median = lab.readings(peerId = "peer", inputs = DistanceInputs(), now = 13.0).firstOrNull { it.method == DistanceMethod.rssiMedian }
        assertNotNull(median)
        assertEquals(Positioning.PathLossModel.defaultOutdoor.medianDistance(rssi = -60.0), median!!.meters, 1e-9)
        assertNotNull(median.low)

        // Outside the 4 s window the samples no longer count.
        assertNull(lab.readings(peerId = "peer", inputs = DistanceInputs(), now = 30.0).firstOrNull { it.method == DistanceMethod.rssiMedian })
    }

    @Test
    fun testTrialScoresEachMethodAgainstTheTapeMeasure() {
        val trial = DistanceTrial(peerId = "peer", peerLabel = "Otter 12", trueDistance = 4.0, startedAt = 100.0)
        trial.record(
            listOf(
                DistanceReading(method = DistanceMethod.uwb, meters = 4.1, low = 3.5, high = 4.7),
                DistanceReading(method = DistanceMethod.rssiDefault, meters = 6.0, low = 3.0, high = 12.0),
            ),
            at = 101.0,
        )
        trial.record(
            listOf(
                DistanceReading(method = DistanceMethod.uwb, meters = 3.9, low = 3.3, high = 4.5),
                DistanceReading(method = DistanceMethod.rssiDefault, meters = 2.0, low = 1.0, high = 3.9),
            ),
            at = 102.0,
        )
        trial.record(emptyList(), at = 103.0)
        assertEquals(2, trial.samples.size)

        val scores = trial.scores
        assertEquals(listOf(DistanceMethod.uwb, DistanceMethod.rssiDefault), scores.map { it.method })
        val uwb = scores.first { it.method == DistanceMethod.uwb }
        assertEquals(2, uwb.count)
        assertEquals(0.0, uwb.bias, 1e-9)
        assertEquals(0.1, uwb.meanAbsoluteError, 1e-9)
        assertEquals(0.1, uwb.rmse, 1e-9)
        assertEquals(1.0, uwb.coverage ?: 0.0, 1e-9)
        val rssi = scores.first { it.method == DistanceMethod.rssiDefault }
        assertEquals(2.0, rssi.meanAbsoluteError, 1e-9)
        assertEquals(2.0, rssi.rmse, 1e-9)
        assertEquals(0.5, rssi.coverage ?: 0.0, 1e-9)
    }

    @Test
    fun testTrialCSVHasOneColumnPerMethod() {
        val trial = DistanceTrial(peerId = "peer", peerLabel = "Otter, 12", trueDistance = 4.0, startedAt = 100.0)
        trial.record(
            listOf(DistanceReading(method = DistanceMethod.uwb, meters = 4.1), DistanceReading(method = DistanceMethod.rssiDefault, meters = 6.0)),
            at = 101.0,
        )
        assertEquals(
            "t_s,peer,true_m,uwb,signalMap,rssiCalibrated,rssiDefault,rssiMedian,gps\n" +
                "1.0,\"Otter, 12\",4.00,4.10,,,6.00,,\n",
            trial.csv(),
        )
    }
}
