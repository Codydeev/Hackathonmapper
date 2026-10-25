package com.hackathonmapper.meshcore

import com.hackathonmapper.meshcore.Positioning as PZ
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.hypot

/**
 * The peer locator in the pipeline's positioning slot, against today's BluetoothEstimator, on every
 * contract scenario (headless ScenarioWorld, synthetic). Acceptance for swapping it in: every
 * gating expectation passes, S5-c improves, S1-c and S6-b do not get worse, with the baseline
 * engines and with every merged GhostCore engine.
 *
 * With two anchors 14 m apart, B walking away in S5 has a mirror twin, so the honest estimate is
 * ambiguous and its region centre moves in a direction B does not. A predictor that took that
 * centre's motion as B's velocity would suffer; the last test checks the region reading.
 */
class PositioningPeerLocatorTests {
    private companion object {
        /** contract/scenarios, read in place (Gradle passes the repository root). */
        val folder: File = File(System.getProperty("repo.root") ?: "../..", "contract/scenarios")
    }

    private fun scenarios(): List<Scenario> =
        (folder.list() ?: emptyArray()).filter { it.endsWith(".json") }.sorted()
            .map { MeshJson.decodeFromString(Scenario.serializer(), File(folder, it).readText()) }

    /** "held 62% of 141 s" -> 0.62 */
    private fun fraction(r: ScenarioWorld.Result): Double? {
        val match = Regex("""held (\d+)%""").find(r.detail) ?: return null
        return match.groupValues[1].toDoubleOrNull()?.let { it / 100 }
    }

    private fun world(scenario: Scenario, locator: Boolean, ghostcore: Boolean): ScenarioWorld {
        val positioning: ((String, String) -> GhostPositioningEngine)? =
            if (locator) { id, frame -> PZ.PeerLocator(producerId = id, frameId = frame) } else null
        return if (ghostcore) {
            ScenarioWorld(
                scenario = scenario, integrity = { id, frame -> GNSSIntegrityMonitor(subjectId = id, frameId = frame) },
                positioning = positioning, prediction = { id, frame -> GhostPredictor(producerId = id, frameId = frame) },
            )
        } else {
            ScenarioWorld(scenario = scenario, positioning = positioning)
        }
    }

    @Test
    fun testPeerLocatorAgainstTheEstimatorOnEveryScenario() {
        val compared = setOf("S1-c", "S5-c", "S6-b")
        for (ghostcore in listOf(false, true)) {
            val label = if (ghostcore) "ghostcore engines" else "baseline engines"
            val lines = mutableListOf(
                "", "### PeerLocator vs BluetoothEstimator, $label (synthetic)",
                "| expectation | estimator | peer locator |", "|---|---|---|",
            )
            val before = HashMap<String, Double>()
            val after = HashMap<String, Double>()
            for (scenario in scenarios()) {
                val old = world(scenario, locator = false, ghostcore = ghostcore).run()
                val new = world(scenario, locator = true, ghostcore = ghostcore).run()
                assertEquals("$label ${scenario.id}: ${new.gateFailures.map { "${it.id} ${it.detail}" }}", emptyList<ScenarioWorld.Result>(), new.gateFailures)
                for ((o, n) in old.results.zip(new.results)) {
                    if (!(compared.contains(o.id) || o.outcome != n.outcome)) continue
                    lines.add("| ${o.id} | ${o.outcome.rawValue}: ${o.detail} | ${n.outcome.rawValue}: ${n.detail} |")
                    fraction(o)?.let { before[o.id] = it } ?: before.remove(o.id)
                    fraction(n)?.let { after[n.id] = it } ?: after.remove(n.id)
                }
            }
            println(lines.joinToString("\n"))
            assertTrue("$label: S1-c must not get worse", (after["S1-c"] ?: 0.0) >= (before["S1-c"] ?: 1.0))
            assertTrue("$label: S6-b must not get worse", (after["S6-b"] ?: 0.0) >= (before["S6-b"] ?: 1.0))
            assertTrue("$label: S5-c must improve", (after["S5-c"] ?: 0.0) > (before["S5-c"] ?: 1.0))
        }
    }

    private fun gnssAnchor(id: String, x: Double, z: Double, at: Double, contributors: List<String>? = null): PositionEstimate =
        PositionEstimate(
            subjectId = id, timestamp = at, frameId = "hervanta-v1", kind = PositionEstimate.Kind.measured,
            method = PositionEstimate.Method.gnss, position = Position(x = x, y = 0.0, z = z),
            uncertainty = PositionUncertainty(r95 = 8.1), source = EvidenceSource.gnss, freshness = Freshness(maxAge = 30.0),
            provenance = Provenance(producerId = id, algorithm = "gnss@1", contributors = contributors ?: listOf(id), gnssDependent = true),
        )

    private fun link(anchor: String, ax: Double, az: Double, to: PZ.Vec2): LinkMeasurement =
        LinkMeasurement(
            a = anchor, b = "phone-b",
            rssi = PZ.PathLossModel.defaultOutdoor.expectedRSSI(distance = hypot(to.x - ax, to.z - az)),
        )

    @Test
    fun testKindsProvenanceAndRefusals() {
        val truth = PZ.Vec2(x = 14.0, z = 9.0)
        val spots = listOf(Triple("phone-a", 0.0, 0.0), Triple("phone-c", 30.0, 0.0), Triple("phone-d", 15.0, 26.0))

        // One anchor: a disc, flagged ambiguous, never a point claim; listed with its id as GNSS.
        val one = PZ.PeerLocator(producerId = "phone-a", frameId = "hervanta-v1")
        var e: PositionEstimate? = null
        for (s in 0 until 10) {
            val now = 1_793_000_000 + s.toDouble()
            e = one.place(
                anchors = listOf(gnssAnchor("phone-a", 0.0, 0.0, at = now)), lost = listOf("phone-b"),
                links = listOf(link("phone-a", 0.0, 0.0, to = truth)), observations = emptyList(), now = now,
            ).firstOrNull()
        }
        assertNotNull(e)
        val disc = e!!
        disc.validate()
        assertEquals(PositionEstimate.Method.proximity, disc.method)
        assertTrue(disc.uncertainty.ambiguous)
        assertNull(disc.candidates)
        assertTrue(disc.uncertainty.r95 >= hypot(truth.x, truth.z))
        assertEquals("phone-a", disc.provenance.producerId)
        assertTrue("the placed phone's own link readings count", disc.provenance.contains(device = "phone-b"))
        assertTrue(disc.provenance.inputs.any { it.source == EvidenceSource.gnss && it.id == "phone-a" && it.used })

        // Three well-placed anchors: a point.
        val three = PZ.PeerLocator(producerId = "phone-a", frameId = "hervanta-v1")
        for (s in 0 until 10) {
            val now = 1_793_000_000 + s.toDouble()
            e = three.place(
                anchors = spots.map { gnssAnchor(it.first, it.second, it.third, at = now) }, lost = listOf("phone-b"),
                links = spots.map { link(it.first, it.second, it.third, to = truth) }, observations = emptyList(), now = now,
            ).firstOrNull()
        }
        assertNotNull(e)
        val point = e!!
        assertEquals(PositionEstimate.Method.multilateration, point.method)
        assertFalse(point.uncertainty.ambiguous)
        assertTrue(hypot(point.position!!.x - truth.x, point.position!!.z - truth.z) < point.uncertainty.r95)
        assertEquals(setOf("phone-a", "phone-c", "phone-d"), point.provenance.inputs.filter { it.source == EvidenceSource.gnss }.mapNotNull { it.id }.toSet())

        // An anchor whose own position rests on the lost phone is not used.
        val loop = PZ.PeerLocator(producerId = "phone-a", frameId = "hervanta-v1")
        val out = loop.place(
            anchors = listOf(gnssAnchor("phone-c", 30.0, 0.0, at = 1_793_000_000.0, contributors = listOf("phone-c", "phone-b"))),
            lost = listOf("phone-b"), links = listOf(link("phone-c", 30.0, 0.0, to = truth)), observations = emptyList(), now = 1_793_000_000.0,
        )
        assertTrue(out.isEmpty())
    }

    @Test
    fun testRememberedFixIsNeverReportedAsMeasured() {
        val locator = PZ.PeerLocator(producerId = "phone-a", frameId = "hervanta-v1")
        val t0 = 1_793_000_000.0
        locator.place(
            anchors = listOf(gnssAnchor("phone-a", 0.0, 0.0, at = t0), gnssAnchor("phone-b", 15.0, 10.0, at = t0)), lost = emptyList(),
            links = emptyList(), observations = emptyList(), now = t0,
        )
        val lost = locator.place(
            anchors = listOf(gnssAnchor("phone-a", 0.0, 0.0, at = t0 + 1)), lost = listOf("phone-b"),
            links = listOf(link("phone-a", 0.0, 0.0, to = PZ.Vec2(x = 15.0, z = 10.0))), observations = emptyList(), now = t0 + 1,
        ).firstOrNull()
        assertNotNull(lost)
        lost!!
        assertEquals(PositionEstimate.Kind.estimated, lost.kind)
        assertNotEquals(EvidenceSource.gnss, lost.source)
        assertTrue(hypot(lost.position!!.x - 15, lost.position!!.z - 10) < lost.uncertainty.r95)
    }

    /**
     * What S5-c is when Ghost Mode takes an ambiguous estimate as a region (no velocity from its
     * moving centre) instead of a point. Test-only wrapper; the predictor itself is not changed.
     */
    private class AmbiguityAware(id: String, frame: String) : GhostPredictionEngine {
        val ghost = GhostPredictor(producerId = id, frameId = frame)
        val circle = WalkingCirclePrediction(producerId = id)
        val lastAmbiguous = HashMap<String, Boolean>()

        override fun observe(estimate: PositionEstimate, receivedAt: Double) {
            val e = estimate
            if (e.kind == PositionEstimate.Kind.predicted || e.kind == PositionEstimate.Kind.unavailable) return
            lastAmbiguous[e.subjectId] = e.uncertainty.ambiguous
            circle.observe(e, receivedAt = receivedAt)
            if (!e.uncertainty.ambiguous) ghost.observe(e, receivedAt = receivedAt)
        }

        override fun observe(motion: MotionObservation) {
            ghost.observe(motion)
        }

        override fun predict(subjectId: String, now: Double): Prediction? =
            if (lastAmbiguous[subjectId] == true) circle.predict(subjectId = subjectId, now = now)
            else ghost.predict(subjectId = subjectId, now = now)
    }

    @Test
    fun testS5WithAPredictorThatRespectsAmbiguity() {
        val scenario = scenarios().first { it.id == "S5" }
        val lines = mutableListOf(
            "", "### S5 with a predictor that treats ambiguous estimates as regions (synthetic, informational)",
            "| positioning | S5-a | S5-b | S5-c |", "|---|---|---|---|",
        )
        val held = HashMap<Boolean, Double>()
        for (locator in listOf(false, true)) {
            val report = ScenarioWorld(
                scenario = scenario, integrity = { id, frame -> GNSSIntegrityMonitor(subjectId = id, frameId = frame) },
                positioning = if (locator) { id, frame -> PZ.PeerLocator(producerId = id, frameId = frame) } else null,
                prediction = { id, frame -> AmbiguityAware(id, frame) },
            ).run()
            assertEquals(emptyList<ScenarioWorld.Result>(), report.gateFailures)
            report.results.firstOrNull { it.id == "S5-c" }?.let { fraction(it) }?.let { held[locator] = it }
            val cells = report.results.map { "${it.outcome.rawValue}: ${it.detail}" }
            lines.add("| ${if (locator) "peer locator" else "estimator"} | " + cells.joinToString(" | ") + " |")
        }
        println(lines.joinToString("\n"))
        assertTrue((held[true] ?: 0.0) >= 0.9)
        assertTrue((held[true] ?: 0.0) > (held[false] ?: 1.0))
    }
}
