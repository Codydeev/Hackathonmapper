package com.hackathonmapper.meshcore

import java.util.UUID
import kotlin.math.hypot
import kotlin.math.min
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The signal map in GhostCore's positioning slot: the app's main map places lost phones the way
 * the dashboard and the Track tab do, UWB distances included (docs/AUDIT.md §1.1).
 */
class SignalMapPositioningTests {
    private val t0 = 1_793_000_000.0
    private val radio = RadioModel.standard

    private fun uuid(): String = UUID.randomUUID().toString().uppercase()

    private fun anchor(id: String, x: Double, z: Double, r95: Double, kind: PositionEstimate.Kind = PositionEstimate.Kind.declared): PositionEstimate {
        val measured = kind == PositionEstimate.Kind.measured
        return PositionEstimate(subjectId = id, timestamp = t0, frameId = "hervanta-v1", kind = kind,
            method = if (measured) PositionEstimate.Method.gnss else PositionEstimate.Method.manual,
            position = Position(x = x, y = 0.0, z = z),
            uncertainty = PositionUncertainty(r95 = r95), source = if (measured) EvidenceSource.gnss else EvidenceSource.manual,
            freshness = Freshness(maxAge = 15.0),
            provenance = Provenance(producerId = id, algorithm = "mesh-report@1", gnssDependent = measured))
    }

    private fun engine(): SignalMapPositioning = SignalMapPositioning(producerId = "phone-me", frameId = "hervanta-v1")

    /**
     * One GPS phone and a lost phone 3 m away by UWB whose RSSI reads 8 m: the lost phone is on a
     * ring of the UWB radius around it, shown as ambiguous, never as a confident spot.
     */
    @Test
    fun testUWBDistanceGivesARingAroundOneAnchor() {
        val placed = engine().place(
            anchors = listOf(anchor("gps", x = 10.0, z = 20.0, r95 = 15.0, kind = PositionEstimate.Kind.measured)), lost = listOf("lost"),
            links = listOf(LinkMeasurement(a = "gps", b = "lost", rssi = radio.expectedRSSI(8.0), uwb = 3.0)),
            observations = emptyList(), now = t0)
        val estimate = placed.firstOrNull()
        assertNotNull(estimate)
        estimate!!
        assertEquals("lost", estimate.subjectId)
        estimate.validate()
        assertEquals(PositionEstimate.Kind.estimated, estimate.kind)
        assertEquals(PositionEstimate.Method.multilateration, estimate.method)
        assertEquals(EvidenceSource.uwb, estimate.source)
        assertTrue(estimate.uncertainty.ambiguous)
        val p = estimate.position!!
        assertEquals(3.0, hypot(p.x - 10, p.z - 20), 0.01)
        assertTrue(estimate.uncertainty.r95 >= 3)
        assertTrue(estimate.provenance.contributors.contains("gps"))
    }

    /** Two typed anchors 10 m apart fix the group in the world: a point, not a ring. */
    @Test
    fun testTwoAnchorsPlaceAPointFromRSSI() {
        val truth = mapOf("a1" to Pair(0.0, 0.0), "a2" to Pair(10.0, 0.0), "p" to Pair(4.0, 3.0))
        fun measured(a: String, b: String): LinkMeasurement {
            val pa = truth.getValue(a)
            val pb = truth.getValue(b)
            return LinkMeasurement(a = a, b = b, rssi = radio.expectedRSSI(hypot(pa.first - pb.first, pa.second - pb.second)))
        }
        val placed = engine().place(anchors = listOf(anchor("a1", x = 0.0, z = 0.0, r95 = 0.5), anchor("a2", x = 10.0, z = 0.0, r95 = 0.5)),
            lost = listOf("p"), links = listOf(measured("a1", "p"), measured("a2", "p")), observations = emptyList(), now = t0)
        val estimate = placed.firstOrNull()
        assertNotNull(estimate)
        estimate!!
        assertEquals(EvidenceSource.bluetooth, estimate.source)
        assertFalse(estimate.uncertainty.ambiguous)
        val p = estimate.position!!
        // Two anchors leave a mirror image across their line; either is a correct reading.
        assertEquals(0.0, min(hypot(p.x - 4, p.z - 3), hypot(p.x - 4, p.z + 3)), 0.2)
    }

    /** No estimate without a way to an anchor: unlinked, or linked only to other lost phones. */
    @Test
    fun testNoEstimateWithoutAPathToAnAnchor() {
        val placed = engine().place(anchors = listOf(anchor("a", x = 0.0, z = 0.0, r95 = 1.0)), lost = listOf("alone", "p", "q"),
            links = listOf(LinkMeasurement(a = "p", b = "q", rssi = -65.0, uwb = 2.0)), observations = emptyList(), now = t0)
        assertTrue(placed.isEmpty())
    }

    /**
     * Wire v5 reports through the whole pipeline: the UWB distances in `neighbors` reach the
     * engine, and the lost phone is selected on its ring.
     */
    @Test
    fun testPipelineCarriesUWBDistancesFromReports() {
        val p = GhostCorePipeline(configuration = GhostCorePipeline.Configuration(selfId = "phone-me", frameId = "hervanta-v1"),
            positioning = engine())
        fun report(id: String, source: PositionSource, x: Double, neighbors: List<NeighborObservation>): DeviceUpdate =
            DeviceUpdate(id = id, epochId = uuid(), sequence = 1, role = "mobile",
                position = Position(x = x, y = 0.0, z = 0.0), positionMode = "floor", accuracyMeters = 5.0,
                neighbors = neighbors, positionSource = source)
        p.ingest(report = report("phone-g", PositionSource.gps, x = 20.0,
            neighbors = listOf(NeighborObservation(id = "phone-l", rssi = -82, ageMs = 0, uwbDistanceM = 3.02))), receivedAt = t0)
        p.ingest(report = report("phone-l", PositionSource.none, x = 0.0,
            neighbors = listOf(NeighborObservation(id = "phone-g", rssi = -82, ageMs = 0, uwbDistanceM = 2.98))), receivedAt = t0)
        val output = p.step(now = t0 + 1)
        val link = output.links.firstOrNull()
        assertNotNull(link)
        assertEquals(3.0, link!!.uwb ?: 0.0, 1e-9)
        val lost = output.phones.firstOrNull { it.id == "phone-l" }?.selected
        assertNotNull(lost)
        assertEquals(PositionEstimate.Method.multilateration, lost!!.method)
        assertEquals(EvidenceSource.uwb, lost.source)
        val position = lost.position!!
        assertEquals(3.0, hypot(position.x - 20, position.z), 0.01)
    }

    /** A fused phone is an estimate, never an anchor, so a phone hearing only it stays unplaced. */
    @Test
    fun testFusedPhoneDoesNotAnchor() {
        val p = GhostCorePipeline(configuration = GhostCorePipeline.Configuration(selfId = "phone-me", frameId = "hervanta-v1"),
            positioning = engine())
        p.ingest(report = DeviceUpdate(id = "phone-f", epochId = uuid(), sequence = 1, role = "mobile",
            position = Position(x = 5.0, y = 0.0, z = 0.0), positionMode = "floor", accuracyMeters = 4.0,
            positionSource = PositionSource.fused), receivedAt = t0)
        p.ingest(report = DeviceUpdate(id = "phone-l", epochId = uuid(), sequence = 1, role = "mobile",
            position = Position(x = 0.0, y = 0.0, z = 0.0), positionMode = "floor",
            neighbors = listOf(NeighborObservation(id = "phone-f", rssi = -65, ageMs = 0)),
            positionSource = PositionSource.none), receivedAt = t0)
        assertNull(p.step(now = t0 + 1).phones.firstOrNull { it.id == "phone-l" }?.estimate)
    }

    /** Both ends' UWB distances average into the pair's link; RSSI-only reports leave it nil. */
    @Test
    fun testEstimatorInputAveragesUWBPerPair() {
        fun report(id: String, neighbors: List<NeighborObservation>): DeviceUpdate =
            DeviceUpdate(id = id, epochId = uuid(), sequence = 1, role = "mobile",
                position = Position(x = 0.0, y = 0.0, z = 0.0), positionMode = "floor", neighbors = neighbors,
                positionSource = PositionSource.none)
        val now = t0
        val input = BluetoothEstimator.input(
            reports = listOf(report("a", listOf(NeighborObservation(id = "b", rssi = -60, uwbDistanceM = 2.0),
                NeighborObservation(id = "c", rssi = -70))),
                report("b", listOf(NeighborObservation(id = "a", rssi = -62, uwbDistanceM = 2.2)))),
            receivedAt = mapOf("a" to now, "b" to now), now = now, reportMaxAge = 15.0, linkMaxAge = 6.0)
        val ab = input.measurements.firstOrNull { it.a == "a" && it.b == "b" }
        assertEquals(-61.0, ab?.rssi ?: 0.0, 1e-9)
        assertEquals(2.1, ab?.uwb ?: 0.0, 1e-9)
        assertNull(input.measurements.firstOrNull { it.a == "a" && it.b == "c" }?.uwb)
    }
}
