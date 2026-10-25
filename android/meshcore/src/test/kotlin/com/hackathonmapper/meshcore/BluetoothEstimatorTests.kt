package com.hackathonmapper.meshcore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Known-geometry checks matching website/scripts/estimator-check.ts: three placed neighbours pin
 * a phone down, one leaves only a ring, and uncertainty grows with every Bluetooth hop.
 * Port of ios/MeshCore/Tests/MeshCoreTests/BluetoothEstimatorTests.swift.
 */
class BluetoothEstimatorTests {
    private data class Point(val x: Double, val z: Double)

    private class Outcome(val error: Double, val r95: Double, val hops: Int?)

    private class Scenario(val error: Double, val r95: Double, val inside: Double, val hops: List<Int?>)

    /** mulberry32, as in the check script, for repeatable RSSI noise. */
    private class Noise(var state: UInt) {
        fun next(): Double {
            state += 0x6d2b79f5u
            var t = state
            t = (t xor (t shr 15)) * (t or 1u)
            t = t xor (t + ((t xor (t shr 7)) * (t or 61u)))
            return (t xor (t shr 14)).toDouble() / 4_294_967_296.0
        }

        fun gauss(): Double = sqrt(-2 * ln(max(next(), 1e-12))) * cos(2 * PI * next())
    }

    /**
     * Runs `seconds` of updates with realistic RSSI noise and returns the last estimate of `target`.
     * With `gpsUntil`, the lost phones are anchors (had GPS) for that many seconds first.
     */
    private fun run(
        anchors: Map<String, Point>,
        lost: Map<String, Point>,
        target: String,
        seed: UInt,
        seconds: Int = 60,
        gpsUntil: Int = 0,
    ): Outcome {
        val radio = RadioModel.outdoors
        val noise = Noise(seed)
        val options = BluetoothEstimator.Options()
        options.seed = seed + 1u
        val estimator = BluetoothEstimator(options = options)
        val all = lost + anchors // anchors win, as `merging { first, _ in first }`
        val ids = all.keys.sorted()
        var last: BluetoothEstimate? = null
        for (t in 0 until seconds) {
            val measurements = mutableListOf<LinkMeasurement>()
            for (i in ids.indices) {
                for (j in (i + 1) until ids.size) {
                    val a = all[ids[i]]!!
                    val b = all[ids[j]]!!
                    val d = hypot(a.x - b.x, a.z - b.z)
                    if (noise.next() > radio.hearProbability(d)) continue
                    val rssi = radio.expectedRSSI(d) + radio.sigma * 0.8 * noise.gauss()
                    measurements.add(LinkMeasurement(a = ids[i], b = ids[j], rssi = rssi))
                }
            }
            val placed = (if (t < gpsUntil) all else anchors).keys.sorted().map { id ->
                EstimatorAnchor(id = id, x = all[id]!!.x, z = all[id]!!.z, accuracy = 5.0)
            }
            val unplaced = if (t < gpsUntil) emptyList() else lost.keys.sorted()
            last = estimator.update(anchors = placed, lost = unplaced, measurements = measurements)[target]
        }
        val estimate = last
        assertNotNull("no estimate for $target", estimate)
        val truth = all[target]!!
        return Outcome(error = hypot(estimate!!.x - truth.x, estimate.z - truth.z), r95 = estimate.r95, hops = estimate.hops)
    }

    private fun median(values: List<Double>): Double = values.sorted()[values.size / 2]

    private fun scenario(
        anchors: Map<String, Point>,
        lost: Map<String, Point>,
        target: String,
        seconds: Int = 60,
        gpsUntil: Int = 0,
    ): Scenario {
        val results = (1..8).map { seed ->
            run(anchors, lost, target, seed.toUInt(), seconds, gpsUntil)
        }
        val inside = results.count { it.error <= it.r95 }.toDouble() / results.size.toDouble()
        return Scenario(median(results.map { it.error }), median(results.map { it.r95 }), inside, results.map { it.hops })
    }

    private val triangle = mapOf("a" to Point(0.0, 0.0), "b" to Point(50.0, 0.0), "c" to Point(25.0, 45.0))
    private val chainAnchors = mapOf("a" to Point(0.0, 0.0), "b" to Point(0.0, 40.0))
    private val chainLost = mapOf("m" to Point(40.0, 20.0), "x" to Point(80.0, 20.0))

    @Test
    fun testThreeAnchorsPinThePhoneDown() {
        val three = scenario(triangle, mapOf("x" to Point(22.0, 15.0)), "x")
        assertTrue("error ${three.error}", three.error < 15)
        assertTrue("inside ${three.inside}", three.inside >= 0.7)
        assertTrue(three.hops.all { it == 1 })
    }

    @Test
    fun testOneAnchorLeavesARing() {
        val three = scenario(triangle, mapOf("x" to Point(22.0, 15.0)), "x")
        val one = scenario(mapOf("a" to Point(0.0, 0.0)), mapOf("x" to Point(35.0, 10.0)), "x")
        assertTrue("one ${one.r95} three ${three.r95}", one.r95 >= 2 * three.r95)
    }

    @Test
    fun testSecondHopIsLessCertain() {
        val three = scenario(triangle, mapOf("x" to Point(22.0, 15.0)), "x")
        val chain = scenario(chainAnchors, chainLost, "x")
        assertTrue("chain ${chain.r95} three ${three.r95}", chain.r95 > three.r95)
        // X is 82 m from both anchors: some seconds it hears one directly, some seconds nobody.
        assertTrue(chain.hops.contains(2))
    }

    @Test
    fun testPhoneThatHadGPSStaysPlaced() {
        val lostLater = scenario(chainAnchors, chainLost, "x", seconds = 80, gpsUntil = 20)
        assertTrue("error ${lostLater.error}", lostLater.error < 20)
        assertTrue("inside ${lostLater.inside}", lostLater.inside >= 0.7)
    }

    @Test
    fun testPhoneWithoutAnyLinkGetsNoEstimate() {
        val estimator = BluetoothEstimator()
        val result = estimator.update(
            anchors = listOf(EstimatorAnchor(id = "a", x = 0.0, z = 0.0, accuracy = 3.0)),
            lost = listOf("x"), measurements = emptyList(),
        )
        assertNull(result["x"])
    }

    @Test
    fun testRadioModelDistanceRoundTrip() {
        val radio = RadioModel.outdoors
        for (d in listOf(1.0, 5.0, 20.0, 60.0)) {
            assertEquals(d, radio.distance(radio.expectedRSSI(d)), 1e-9)
        }
        assertEquals(0.5, radio.hearProbability(radio.range), 1e-12)
    }

    // Input from mesh reports

    private val epoch = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    private fun report(
        id: String,
        source: PositionSource?,
        x: Double = 0.0,
        z: Double = 0.0,
        accuracy: Double? = null,
        neighbors: List<NeighborObservation>,
    ): DeviceUpdate = DeviceUpdate(
        id = id, epochId = epoch, sequence = 1, role = "mobile", position = Position(x = x, y = 0.0, z = z),
        positionMode = "floor", accuracyMeters = accuracy, neighbors = neighbors, positionSource = source,
    )

    @Test
    fun testInputSplitsPlacedAndLostPhones() {
        val now = currentTime()
        val reports = listOf(
            report("gps", PositionSource.gps, x = 3.0, z = 4.0, accuracy = 6.0, neighbors = emptyList()),
            report("old", null, x = 1.0, z = 2.0, neighbors = emptyList()),
            report("lost", PositionSource.none, neighbors = emptyList()),
            report("gone", PositionSource.gps, neighbors = emptyList()),
        )
        val receivedAt = mapOf("gps" to now, "old" to now, "lost" to now, "gone" to now - 60)
        val input = BluetoothEstimator.input(
            reports = reports, receivedAt = receivedAt, now = now, reportMaxAge = 15.0, linkMaxAge = 6.0,
        )
        assertEquals(
            listOf(
                EstimatorAnchor(id = "gps", x = 3.0, z = 4.0, accuracy = 6.0),
                EstimatorAnchor(id = "old", x = 1.0, z = 2.0, accuracy = null),
            ),
            input.anchors,
        )
        assertEquals(listOf("lost"), input.lost)
    }

    @Test
    fun testInputAveragesBothEndsAndDropsOldLinks() {
        val now = currentTime()
        val reports = listOf(
            report(
                "a", PositionSource.gps,
                neighbors = listOf(NeighborObservation(id = "b", rssi = -60, ageMs = 500), NeighborObservation(id = "c", rssi = null, ageMs = 0)),
            ),
            report(
                "b", PositionSource.none,
                neighbors = listOf(NeighborObservation(id = "a", rssi = -70, ageMs = 0), NeighborObservation(id = "c", rssi = -80, ageMs = 5_000)),
            ),
            report("c", PositionSource.gps, neighbors = emptyList()),
        )
        // b's report is 2 s old, so its 5 s old link to c is past the 6 s limit.
        val receivedAt = mapOf("a" to now, "b" to now - 2, "c" to now)
        val input = BluetoothEstimator.input(
            reports = reports, receivedAt = receivedAt, now = now, reportMaxAge = 15.0, linkMaxAge = 6.0,
        )
        assertEquals(listOf(LinkMeasurement(a = "a", b = "b", rssi = -65.0)), input.measurements)
    }
}
