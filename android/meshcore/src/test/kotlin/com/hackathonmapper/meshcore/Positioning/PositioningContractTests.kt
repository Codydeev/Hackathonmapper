package com.hackathonmapper.meshcore

import com.hackathonmapper.meshcore.Positioning as PZ
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import kotlin.math.PI
import kotlin.math.sin

/**
 * The engine's output must be valid GhostCore records, and relayed records must only anchor
 * this phone when the contract allows it.
 */
class PositioningContractTests {
    private val clock = PZ.Clock(unixMinusMonotonic = 1_793_000_000.0)

    private companion object {
        /** contract/fixtures, read in place (Gradle passes the repository root). */
        val fixtures: File = File(System.getProperty("repo.root") ?: "../..", "contract/fixtures")
    }

    private fun map(e: PZ.Estimate, upstream: List<Provenance> = emptyList()): PositionEstimate {
        val record = PZ.ContractMapping.positionEstimate(e, subjectId = "phone-b", clock = clock, upstream = upstream)
        record.validate()
        val decoded = MeshJson.decodeFromString(PositionEstimate.serializer(), MeshJson.encodeToString(PositionEstimate.serializer(), record))
        assertEquals(record, decoded)
        return record
    }

    private fun anchorRSSI(e: PZ.Engine, spots: List<Pair<String, PZ.Vec2>>, truth: PZ.Vec2, until: Double) {
        for ((id, p) in spots) {
            e.ingest(anchor = PZ.Anchor(id = id, position = p, sigma = 3.3, kind = PZ.Anchor.Kind.gnss, measuredAt = 0.0))
            val value = PZ.PathLossModel.defaultOutdoor.expectedRSSI(distance = p.distance(to = truth))
            var t = 0.0
            while (t <= until) {
                e.ingest(rssi = PZ.RSSISample(peerId = id, rssi = value, t = t, channel = PZ.RSSIChannel.advertisement))
                t += 0.2
            }
        }
    }

    @Test
    fun testEveryMethodMapsToAValidRecord() {
        val gnss = PZ.Engine(selfId = "phone-b", frameId = "hervanta-v1")
        gnss.ingest(gnss = PZ.GNSSFix(t = 5.0, position = PZ.Vec2(x = 3.0, z = 4.0), horizontalAccuracy = 5.0, trusted = true))
        val measured = map(gnss.estimate(at = 5.0))
        assertEquals(PositionEstimate.Kind.measured, measured.kind)
        assertEquals(PositionEstimate.Method.gnss, measured.method)
        assertEquals(PositionSource.gps, measured.dashboardSource)
        assertTrue(measured.provenance.gnssDependent)
        assertEquals(1_793_000_005.0, measured.timestamp, 0.0)

        val dr = map(gnss.estimate(at = 30.0))
        assertEquals(PositionEstimate.Kind.estimated, dr.kind)
        assertEquals(PositionEstimate.Method.deadReckoning, dr.method)
        assertEquals("an estimate is never shown as a GPS fix", PositionSource.none, dr.dashboardSource)
        assertEquals(1_793_000_005.0, dr.lastAbsoluteAt)

        val one = PZ.Engine(selfId = "phone-b", frameId = "hervanta-v1")
        anchorRSSI(one, listOf("phone-a" to PZ.Vec2.zero), truth = PZ.Vec2(x = 9.0, z = 8.0), until = 9.0)
        val proximity = map(one.estimate(at = 9.0))
        assertEquals(PositionEstimate.Method.proximity, proximity.method)
        assertTrue("a disc is not a point claim", proximity.uncertainty.ambiguous)
        assertNull(proximity.candidates)
        assertEquals(EvidenceSource.bluetooth, proximity.source)

        val two = PZ.Engine(selfId = "phone-b", frameId = "hervanta-v1")
        anchorRSSI(two, listOf("phone-a" to PZ.Vec2.zero, "phone-c" to PZ.Vec2(x = 20.0, z = 0.0)), truth = PZ.Vec2(x = 10.0, z = 8.0), until = 9.0)
        val ambiguous = map(two.estimate(at = 9.0))
        assertTrue(ambiguous.uncertainty.ambiguous)
        assertEquals(2, ambiguous.candidates?.size)

        val three = PZ.Engine(selfId = "phone-b", frameId = "hervanta-v1")
        anchorRSSI(
            three, listOf("phone-a" to PZ.Vec2.zero, "phone-c" to PZ.Vec2(x = 30.0, z = 0.0), "phone-d" to PZ.Vec2(x = 15.0, z = 26.0)),
            truth = PZ.Vec2(x = 14.0, z = 9.0), until = 9.0,
        )
        val upstream = listOf("phone-a", "phone-c", "phone-d").map {
            Provenance(producerId = it, algorithm = "gnss-integrity@1", gnssDependent = true)
        }
        val multi = map(three.estimate(at = 9.0), upstream = upstream)
        assertEquals(PositionEstimate.Method.multilateration, multi.method)
        assertFalse(multi.uncertainty.ambiguous)
        assertEquals(setOf("phone-b", "phone-a", "phone-c", "phone-d"), multi.provenance.contributors.toSet())
        assertTrue(multi.provenance.gnssDependent)

        val nothing = PZ.Engine(selfId = "phone-b", frameId = "hervanta-v1")
        val unavailable = map(nothing.estimate(at = 1.0))
        assertEquals(PositionEstimate.Kind.unavailable, unavailable.kind)
        assertNull(unavailable.position)

        val declared = PZ.Engine(selfId = "phone-b", frameId = "hervanta-v1")
        declared.declare(position = PZ.Vec2(x = 1.0, z = 2.0), sigma = 1.0, at = 1.0)
        assertEquals(PositionEstimate.Kind.declared, map(declared.estimate(at = 1.0)).kind)
    }

    @Test
    fun testMotionSummaryMapsToAValidMotionObservation() {
        val e = PZ.Engine(selfId = "phone-b", frameId = "hervanta-v1")
        e.declare(position = PZ.Vec2.zero, sigma = 1.0, at = 0.0)
        e.ingest(compass = PZ.CompassSample(t = 0.0, heading = 0.0, sigma = PZ.degrees(5.0)))
        var t = 0.02
        while (t < 10) {
            e.ingest(
                motion = PZ.MotionSample(
                    t = t, gravity = PZ.Vec3(0.0, 0.0, -1.0),
                    userAcceleration = PZ.Vec3(0.0, 0.0, 0.3 * sin(2 * PI * 1.8 * t)), rotationRate = PZ.Vec3(0.0, 0.0, 0.0),
                ),
            )
            t += 0.02
        }
        val record = PZ.ContractMapping.motionObservation(
            e.motionSummary(at = t, window = 5.0), subjectId = "phone-b", frameId = "hervanta-v1", clock = clock,
        )
        record.validate()
        assertEquals(9.0, (record.steps ?: 0).toDouble(), 1.0)
        assertTrue("walking north", record.displacement!!.z > 5)
        assertFalse(record.stationary)
    }

    private fun relayed(
        id: String,
        kind: PositionEstimate.Kind = PositionEstimate.Kind.measured,
        method: PositionEstimate.Method = PositionEstimate.Method.gnss,
        contributors: List<String>? = null,
        ambiguous: Boolean = false,
        age: Double = 1.0,
    ): PositionEstimate {
        val source = if (kind == PositionEstimate.Kind.measured) EvidenceSource.gnss else EvidenceSource.fusion
        return PositionEstimate(
            subjectId = id, timestamp = 1_793_000_100.0, frameId = "hervanta-v1", kind = kind, method = method,
            position = Position(x = 10.0, y = 0.0, z = 5.0), uncertainty = PositionUncertainty(r95 = 8.1, ambiguous = ambiguous),
            source = source, freshness = Freshness(ageAtHandoff = age, maxAge = 10.0),
            provenance = Provenance(producerId = id, algorithm = "test@1", contributors = contributors ?: listOf(id), gnssDependent = true),
        )
    }

    private fun integrity(id: String, status: IntegrityAssessment.Status): IntegrityAssessment =
        IntegrityAssessment(
            subjectId = id, timestamp = 1_793_000_100.0, frameId = "hervanta-v1", status = status, trustScore = 0.9,
            uncertainty = IntegrityAssessment.TrustInterval(lower = 0.8, upper = 0.95),
            reasons = if (status == IntegrityAssessment.Status.trusted) emptyList() else listOf(IntegrityAssessment.Reason.positionJump),
            freshness = Freshness(maxAge = 5.0),
            provenance = Provenance(producerId = id, algorithm = "gnss-integrity@1", gnssDependent = true),
        )

    @Test
    fun testGNSSAnchorNeedsATrustedIntegrityAssessment() {
        val p = relayed("phone-a")
        assertEquals(
            PZ.ContractMapping.AnchorDecision.refused("no integrity assessment"),
            PZ.ContractMapping.anchor(from = p, integrity = null, selfId = "phone-b", receivedAt = 50.0),
        )
        assertEquals(
            PZ.ContractMapping.AnchorDecision.refused("GNSS not trusted: suspect"),
            PZ.ContractMapping.anchor(from = p, integrity = integrity("phone-a", IntegrityAssessment.Status.suspect), selfId = "phone-b", receivedAt = 50.0),
        )
        assertEquals(
            "an assessment about another phone does not count",
            PZ.ContractMapping.AnchorDecision.refused("no integrity assessment"),
            PZ.ContractMapping.anchor(from = p, integrity = integrity("phone-c", IntegrityAssessment.Status.trusted), selfId = "phone-b", receivedAt = 50.0),
        )
        val decision = PZ.ContractMapping.anchor(
            from = p, integrity = integrity("phone-a", IntegrityAssessment.Status.trusted), selfId = "phone-b", receivedAt = 50.0,
        )
        val a = (decision as? PZ.ContractMapping.AnchorDecision.anchor)?.value ?: return fail("$decision")
        assertEquals(PZ.Anchor.Kind.gnss, a.kind)
        assertEquals("receipt time minus the age it already had, never the sender's clock", 49.0, a.measuredAt, 0.0)
        assertEquals(8.1 / PositionUncertainty.sigmaTo95, a.sigma, 1e-9)
        assertTrue(a.gnssDependent)
    }

    @Test
    fun testLoopsRegionsAndPredictionsNeverAnchor() {
        val loop = relayed("phone-c", kind = PositionEstimate.Kind.estimated, method = PositionEstimate.Method.fusion, contributors = listOf("phone-c", "phone-b"))
        assertEquals(
            PZ.ContractMapping.AnchorDecision.refused("depends on this phone"),
            PZ.ContractMapping.anchor(from = loop, integrity = null, selfId = "phone-b", receivedAt = 50.0),
        )
        val ring = relayed("phone-c", kind = PositionEstimate.Kind.estimated, method = PositionEstimate.Method.proximity, ambiguous = true)
        assertEquals(
            PZ.ContractMapping.AnchorDecision.refused("no single position"),
            PZ.ContractMapping.anchor(from = ring, integrity = null, selfId = "phone-b", receivedAt = 50.0),
        )
        val estimated = relayed("phone-c", kind = PositionEstimate.Kind.estimated, method = PositionEstimate.Method.fusion, contributors = listOf("phone-c", "phone-a"))
        val decision = PZ.ContractMapping.anchor(from = estimated, integrity = null, selfId = "phone-b", receivedAt = 50.0)
        val a = (decision as? PZ.ContractMapping.AnchorDecision.anchor)?.value ?: return fail("$decision")
        assertEquals(PZ.Anchor.Kind.estimated, a.kind)
        assertEquals(listOf("phone-c", "phone-a"), a.dependsOn)
    }

    @Test
    fun testPeerObservationSamplesAreTimedOnTheRightClock() {
        val fixture = MeshJson.decodeFromString(PeerObservation.serializer(), File(fixtures, "peer-observation.json").readText())
        // Our own snapshot (observer phone-b): spread over its window, ending at its timestamp.
        val own = PZ.ContractMapping.rssiSamples(from = fixture, selfId = "phone-b", receivedAt = 0.0, clock = clock)
        assertEquals(listOf(-71.0, -74.0, -69.0), own.map { it.rssi })
        assertEquals(listOf("phone-a", "phone-a", "phone-a"), own.map { it.peerId })
        assertEquals(clock.monotonic(fixture.timestamp), own.last().t, 1e-9)
        assertEquals(fixture.window, own.last().t - own.first().t, 1e-9)
        assertEquals(PZ.RSSIChannel.connection, own.firstOrNull()?.channel)

        // The same snapshot received by phone-a is phone-b hearing phone-a's signal: reciprocal.
        val reciprocal = PZ.ContractMapping.rssiSamples(from = fixture, selfId = "phone-a", receivedAt = 200.0, clock = clock)
        assertEquals(listOf("phone-b", "phone-b", "phone-b"), reciprocal.map { it.peerId })
        assertEquals(PZ.RSSIChannel.reciprocal, reciprocal.firstOrNull()?.channel)
        assertEquals(200 - fixture.freshness.ageAtHandoff, reciprocal.last().t, 1e-9)

        assertTrue(PZ.ContractMapping.rssiSamples(from = fixture, selfId = "phone-c", receivedAt = 0.0, clock = clock).isEmpty())
    }

    @Test
    fun testLogRecordsRoundTripAndReplayIdentically() {
        val walk = SyntheticWalk()
        walk.duration = 90.0
        walk.gnssUntil = 30.0
        walk.anchors = SyntheticWalk.fourCornerAnchors(seed = 1uL)
        val records = walk.generate().records
        val decoded = PZ.LogRecord.decodeLines(PZ.LogRecord.encodeLines(records))
        assertEquals(records, decoded)
        val a = PZ.Replay.run(records, engine = PZ.Engine(selfId = "phone-b", frameId = "hervanta-v1"))
        val b = PZ.Replay.run(decoded, engine = PZ.Engine(selfId = "phone-b", frameId = "hervanta-v1"))
        assertEquals(a.map { it.estimate }, b.map { it.estimate })
        assertTrue("one estimate a second", a.size >= 90)
    }
}
