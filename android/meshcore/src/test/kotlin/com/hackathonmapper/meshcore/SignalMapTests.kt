package com.hackathonmapper.meshcore

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.min

class SignalMapTests {
    /** Written by `website/scripts/signalmap-check.ts --write-golden` from the TypeScript solver. */
    @Serializable
    private data class GoldenCase(val name: String, val input: Input, val output: SignalMapResult) {
        @Serializable
        data class Input(
            val ids: List<String>,
            val links: List<SignalLink>,
            val priors: List<SignalPrior>,
            val radio: RadioModel,
            val previous: Map<String, FloorPoint>? = null,
            val calibrate: Boolean,
        )
    }

    /** The golden file is the Swift test's own (single source); Gradle passes its path. */
    private fun goldenCases(): List<GoldenCase> {
        val path = System.getProperty("signalmap.golden")
            ?: "../../ios/MeshCore/Tests/MeshCoreTests/signalmap-golden.json"
        return goldenJson.decodeFromString(File(path).readText())
    }

    private val radio = RadioModel.standard

    private val goldenJson = Json { ignoreUnknownKeys = true }

    private fun link(a: String, b: String, meters: Double): SignalLink =
        SignalLink(a = a, b = b, rssi = radio.expectedRSSI(meters))

    /** The phone and the dashboard must draw the same map from the same reports. */
    @Test
    fun testMatchesTypeScriptGoldenCases() {
        val cases = goldenCases()
        assertTrue(cases.size >= 8)
        for (golden in cases) {
            val input = golden.input
            val result = SignalMap.solve(
                ids = input.ids, links = input.links, priors = input.priors, radio = input.radio,
                previous = input.previous, calibrate = input.calibrate,
            )
            val expected = golden.output
            assertEquals(golden.name, expected.nodes.map { it.id }, result.nodes.map { it.id })
            assertEquals(golden.name, expected.radio.p0, result.radio.p0, 1e-9)
            assertEquals(golden.name, expected.radio.n, result.radio.n, 1e-9)
            for ((node, want) in result.nodes.zip(expected.nodes)) {
                val label = "${golden.name} ${node.id}"
                assertEquals(label, want.x, node.x, 1e-6)
                assertEquals(label, want.z, node.z, 1e-6)
                assertEquals(label, want.r95, node.r95, 1e-6)
                assertEquals(label, want.placed, node.placed)
                assertEquals(label, want.hasPrior, node.hasPrior)
                assertEquals(label, want.component, node.component)
                assertEquals(label, want.frame, node.frame)
                assertEquals(label, want.degree, node.degree)
                assertEquals(label, want.ringCenter, node.ringCenter)
                assertEquals(label, want.ringRadius ?: -1.0, node.ringRadius ?: -1.0, 1e-6)
                assertEquals(label, want.hops, node.hops)
            }
            assertEquals(golden.name, expected.links.size, result.links.size)
            for ((edge, want) in result.links.zip(expected.links)) {
                assertEquals(golden.name, want.a, edge.a)
                assertEquals(golden.name, want.b, edge.b)
                assertEquals(golden.name, want.measured, edge.measured, 1e-9)
                assertEquals(golden.name, want.layout, edge.layout, 1e-6)
            }
        }
    }

    @Test
    fun testRadioModelDistanceRoundTrip() {
        for (d in listOf(1.0, 2.5, 10.0, 40.0)) {
            assertEquals(d, radio.distance(radio.expectedRSSI(d)), 1e-9)
        }
        assertEquals(SignalMap.minDistance, SignalMap.range(20.0, radio), 0.0)
        assertEquals(SignalMap.maxDistance, SignalMap.range(-200.0, radio), 0.0)
        assertEquals(radio.n, PathLossModel.default.exponent, 0.0)
    }

    /** Measured triangle without any placed phone: the map keeps every measured distance. */
    @Test
    fun testRelativeLayoutKeepsMeasuredDistances() {
        val result = SignalMap.solve(
            ids = listOf("a", "b", "c"),
            links = listOf(link("a", "b", 3.0), link("a", "c", 4.0), link("b", "c", 5.0)),
            priors = emptyList(), radio = radio,
        )
        for (edge in result.links) assertEquals(edge.measured, edge.layout, 0.01)
        assertTrue(result.nodes.all { it.frame == SignalFrame.relative && it.placed })
        val nodes = result.nodes.associateBy { it.id }
        assertNull("a relative map has no place in the world", SignalMap.placeInWorld(nodes["a"]!!, nodes))
    }

    /** A ±20 m GPS phone 2 m from a fixed anchor is drawn 2 m from it, not where GPS put it. */
    @Test
    fun testPlacedPhonesAgreeWithTheirBluetoothRanges() {
        val result = SignalMap.solve(
            ids = listOf("anchor", "gps", "lost"),
            links = listOf(link("anchor", "gps", 2.0), link("anchor", "lost", 3.0), link("gps", "lost", 3.6)),
            priors = listOf(SignalPrior(id = "anchor", x = 0.0, z = 0.0, r95 = 0.5), SignalPrior(id = "gps", x = 12.0, z = 6.0, r95 = 20.0)),
            radio = radio,
        )
        val nodes = result.nodes.associateBy { it.id }
        val anchor = assertNotNullAndGet(SignalMap.placeInWorld(nodes["anchor"]!!, nodes))
        val gps = assertNotNullAndGet(SignalMap.placeInWorld(nodes["gps"]!!, nodes))
        val lost = assertNotNullAndGet(SignalMap.placeInWorld(nodes["lost"]!!, nodes))
        assertEquals(2.0, hypot(gps.x - anchor.x, gps.z - anchor.z), 0.3)
        assertEquals(3.0, hypot(lost.x - anchor.x, lost.z - anchor.z), 0.3)
        // One precise phone and a GPS phone 2 m away don't fix the orientation: rings, honestly.
        assertEquals(SignalFrame.pinned, nodes["gps"]!!.frame)
        assertTrue(lost.ambiguous)
        assertEquals(3.0, lost.ringRadius ?: 0.0, 0.3)
        assertEquals(24, SignalMap.ringPoints(lost).size)
        assertFalse(anchor.ambiguous)
    }

    /** Two fixed anchors 10 m apart anchor the group in the world. */
    @Test
    fun testTwoAnchorsPlaceTheGroupInTheWorld() {
        val truth = mapOf("a1" to Pair(0.0, 0.0), "a2" to Pair(10.0, 0.0), "p" to Pair(4.0, 3.0))
        fun measured(a: String, b: String): SignalLink =
            link(a, b, hypot(truth[a]!!.first - truth[b]!!.first, truth[a]!!.second - truth[b]!!.second))
        val result = SignalMap.solve(
            ids = listOf("a1", "a2", "p"), links = listOf(measured("a1", "p"), measured("a2", "p")),
            priors = listOf(SignalPrior(id = "a1", x = 0.0, z = 0.0, r95 = 0.5), SignalPrior(id = "a2", x = 10.0, z = 0.0, r95 = 0.5)),
            radio = radio,
        )
        val nodes = result.nodes.associateBy { it.id }
        val p = assertNotNullAndGet(nodes["p"])
        assertEquals(SignalFrame.world, p.frame)
        assertEquals(1, p.hops)
        val placed = assertNotNullAndGet(SignalMap.placeInWorld(p, nodes))
        assertFalse(placed.ambiguous)
        // Two anchors leave a mirror image across their line; either is a correct reading.
        assertEquals(0.0, min(hypot(placed.x - 4, placed.z - 3), hypot(placed.x - 4, placed.z + 3)), 0.2)
    }

    @Test
    fun testUnlinkedPhoneWithoutPositionIsUnplaced() {
        val result = SignalMap.solve(
            ids = listOf("alone", "a", "b"), links = listOf(link("a", "b", 2.0)), priors = emptyList(), radio = radio,
        )
        val alone = result.nodes.first { it.id == "alone" }
        assertFalse(alone.placed)
        assertNull(SignalMap.placeInWorld(alone, emptyMap()))
        // One link gives a distance, not a direction.
        assertEquals("a", result.nodes.first { it.id == "b" }.ringCenter)
    }

    /** A room frame whose +z points east: walking east is +z, walking north is -x. */
    @Test
    fun testGeoFrameBearingTurnsTheFrame() {
        val origin = GeoFrame.Origin(latitude = 61.4499, longitude = 23.8560, bearingDegrees = 90.0)
        val meter = 1 / (6_371_008.8 * Math.PI / 180)
        val east = GeoFrame.project(origin, origin.latitude, origin.longitude + 10 * meter / cos(origin.latitude * Math.PI / 180))
        assertEquals(0.0, east.x, 1e-6)
        assertEquals(10.0, east.z, 1e-6)
        val north = GeoFrame.project(origin, origin.latitude + 10 * meter, origin.longitude)
        assertEquals(-10.0, north.x, 1e-6)
        assertEquals(0.0, north.z, 1e-6)
        val back = GeoFrame.unproject(origin, north.x, north.z)
        assertEquals(origin.latitude + 10 * meter, back.latitude, 1e-12)
        assertEquals(origin.longitude, back.longitude, 1e-12)
        assertEquals("north (+z)", GeoFrame.forwardName(frameId = GeoFrame.defaultFrameId))
        assertEquals("right", GeoFrame.axisNames(frameId = "room-without-origin").x)
    }

    @Test
    fun testWarmStartKeepsTheMapStill() {
        val links = listOf(
            link("a", "b", 3.0), link("a", "c", 4.0), link("b", "c", 5.0), link("c", "d", 2.0),
            link("b", "d", 4.5),
        )
        val ids = listOf("a", "b", "c", "d")
        val first = SignalMap.solve(ids = ids, links = links, priors = emptyList(), radio = radio)
        val previous = first.nodes.associate { it.id to FloorPoint(x = it.x, z = it.z) }
        val second = SignalMap.solve(ids = ids, links = links, priors = emptyList(), radio = radio, previous = previous)
        for ((a, b) in first.nodes.zip(second.nodes)) {
            assertEquals(a.x, b.x, 0.01)
            assertEquals(a.z, b.z, 0.01)
        }
    }

    /** XCTUnwrap. */
    private fun <T> assertNotNullAndGet(value: T?): T {
        assertNotNull(value)
        return value!!
    }
}
