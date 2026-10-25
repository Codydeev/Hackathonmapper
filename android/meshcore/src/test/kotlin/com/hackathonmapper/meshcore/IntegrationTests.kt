package com.hackathonmapper.meshcore

import java.io.File
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

private fun integrationUUID(): String = UUID.randomUUID().toString().uppercase()

private fun integrationNoThrow(message: String = "", block: () -> Unit) {
    try {
        block()
    } catch (e: Throwable) {
        throw AssertionError("$message: unexpected $e", e)
    }
}

/**
 * GhostCorePipeline rules from ARCHITECTURE.md §6: only trusted GNSS is published and anchors
 * others, rejected fixes stay visible but are never selected, scenario faults mark what they touch.
 */
class IntegrationTests {
    private val t0 = 1_793_000_000.0

    /** Returns whatever status the test sets, as a valid assessment of the latest fix. */
    private class StubIntegrity(var status: IntegrityAssessment.Status) : GhostIntegrityEngine {
        var fix: PositionEstimate? = null
        override fun ingest(fix: PositionEstimate) {
            this.fix = fix
        }

        override fun ingest(motion: MotionObservation) {}

        override fun assess(subjectId: String, evidence: List<PositionEstimate>, now: Double): IntegrityAssessment {
            val score = if (status == IntegrityAssessment.Status.trusted) 0.9 else 0.1
            return IntegrityAssessment(
                subjectId = subjectId, timestamp = now, frameId = "hervanta-v1", status = status, trustScore = score,
                uncertainty = IntegrityAssessment.TrustInterval(lower = 0.0, upper = score),
                reasons = if (status in listOf(IntegrityAssessment.Status.suspect, IntegrityAssessment.Status.rejected,
                        IntegrityAssessment.Status.degraded)
                ) listOf(IntegrityAssessment.Reason.positionJump) else emptyList(),
                evaluatedFix = if (status == IntegrityAssessment.Status.unavailable) null else fix,
                freshness = Freshness(maxAge = 5.0),
                provenance = Provenance(producerId = subjectId, algorithm = "stub@1", gnssDependent = true))
        }
    }

    private fun fix(id: String, x: Double, z: Double, at: Double): PositionEstimate =
        PositionEstimate(subjectId = id, timestamp = at, frameId = "hervanta-v1", kind = PositionEstimate.Kind.measured,
            method = PositionEstimate.Method.gnss,
            position = Position(x = x, y = 0.0, z = z), uncertainty = PositionUncertainty(r95 = 8.0),
            source = EvidenceSource.gnss, freshness = Freshness(maxAge = 30.0),
            provenance = Provenance(producerId = id, algorithm = "test@1", gnssDependent = true))

    private fun pipeline(integrity: GhostIntegrityEngine?): GhostCorePipeline =
        GhostCorePipeline(configuration = GhostCorePipeline.Configuration(selfId = "phone-a", frameId = "hervanta-v1"),
            integrity = integrity)

    @Test
    fun testWithoutIntegrityEngineGPSIsSharedButUnchecked() {
        val p = pipeline(null)
        p.ingest(fix = fix("phone-a", x = 3.0, z = 4.0, at = t0), receivedAt = t0)
        val out = p.step(now = t0 + 1)
        assertEquals(PositionSource.gps, out.publication.source)
        assertFalse(out.integrityEngineActive)
        val me = out.phones.firstOrNull { it.isSelf }
        assertEquals(PositionEstimate.Method.gnss, me?.selected?.method)
        assertNull("never faked as trusted", me?.integrity)
    }

    @Test
    fun testOnlyTrustedGPSIsPublished() {
        val cases = listOf(
            Triple(IntegrityAssessment.Status.trusted, PositionSource.gps, true),
            Triple(IntegrityAssessment.Status.insufficientEvidence, PositionSource.none, true),
            Triple(IntegrityAssessment.Status.degraded, PositionSource.none, true),
            Triple(IntegrityAssessment.Status.suspect, PositionSource.none, false),
            Triple(IntegrityAssessment.Status.rejected, PositionSource.none, false),
        )
        for ((status, published, shownAsGNSS) in cases) {
            val p = pipeline(StubIntegrity(status))
            p.ingest(fix = fix("phone-a", x = 3.0, z = 4.0, at = t0), receivedAt = t0)
            val out = p.step(now = t0 + 1)
            assertEquals("$status", published, out.publication.source)
            val me = out.phones.firstOrNull { it.isSelf }
            assertEquals("$status", shownAsGNSS, me?.selected?.method == PositionEstimate.Method.gnss)
            assertEquals("$status",
                status in listOf(IntegrityAssessment.Status.insufficientEvidence, IntegrityAssessment.Status.degraded),
                me?.gnssUnconfirmed)
            assertNotNull("the raw fix stays visible", me?.rawFix)
            assertEquals(status, me?.integrity?.status)
        }
    }

    @Test
    fun testTypedSpotWinsAndIsDeclared() {
        val p = pipeline(null)
        p.declared = GhostCorePipeline.Declared(Position(x = 1.0, y = 0.0, z = 2.0), 3.0)
        p.ingest(fix = fix("phone-a", x = 3.0, z = 4.0, at = t0), receivedAt = t0)
        val out = p.step(now = t0 + 1)
        assertEquals(PositionSource.manual, out.publication.source)
        assertEquals(PositionEstimate.Kind.declared, out.phones.firstOrNull { it.isSelf }?.selected?.kind)
    }

    @Test
    fun testFaultsShiftDriftAndDropFixesAndMarkThemSimulated() {
        val faults = GNSSFaults()
        val clean = fix("phone-a", x = 0.0, z = 0.0, at = t0 + 10)
        assertEquals(clean, faults.apply(to = clean))
        faults.apply(ScenarioInput.gnssJump(subjectId = "phone-a", dx = 400.0, dz = 0.0), t0)
        val jumped = faults.apply(to = clean)!!
        assertEquals(400.0, jumped.position?.x)
        assertTrue(jumped.provenance.simulated)
        integrationNoThrow { jumped.validate() }
        faults.apply(ScenarioInput.gnssClear(subjectId = "phone-a"), t0)
        faults.apply(ScenarioInput.gnssDrift(subjectId = "phone-a", metersPerSecond = 1.0, bearingDegrees = 90.0), t0)
        assertEquals(10.0, faults.apply(to = clean)!!.position!!.x, 1e-9)
        assertEquals(0.0, faults.apply(to = clean)!!.position!!.z, 1e-9)
        faults.apply(ScenarioInput.gnssOutage(subjectId = "phone-a", active = true), t0)
        assertNull(faults.apply(to = clean))
    }

    @Test
    fun testScenarioInputsOnlyActOnTheirOwnPhone() {
        val p = pipeline(null)
        p.apply(ScenarioInput.gnssOutage(subjectId = "phone-b", active = true), t0)
        assertFalse(p.faults.isActive)
        p.apply(ScenarioInput.gnssOutage(subjectId = "phone-a", active = true), t0)
        p.ingest(fix = fix("phone-a", x = 3.0, z = 4.0, at = t0), receivedAt = t0)
        assertNull(p.step(now = t0 + 1).phones.firstOrNull { it.isSelf }?.rawFix)
    }

    @Test
    fun testScenarioInputJSONRoundTrips() {
        val inputs: List<ScenarioInput> = listOf(
            ScenarioInput.gnssOutage(subjectId = "a", active = true), ScenarioInput.gnssJump(subjectId = "a", dx = 1.0, dz = -2.0),
            ScenarioInput.gnssDrift(subjectId = "a", metersPerSecond = 1.0, bearingDegrees = 90.0), ScenarioInput.gnssClear(subjectId = "a"),
            ScenarioInput.peerLink(subjectId = "a", peerId = "b", up = false),
        )
        val serializer = kotlinx.serialization.builtins.ListSerializer(ScenarioInput.serializer())
        val data = MeshJson.encodeToString(serializer, inputs)
        assertEquals(inputs, MeshJson.decodeFromString(serializer, data))
    }

    @Test
    fun testPeerGPSReportAnchorsAndIsMeasured() {
        val p = pipeline(null)
        val report = DeviceUpdate(id = "phone-b", label = "B", epochId = integrationUUID(), sequence = 1, role = "mobile",
            position = Position(x = 10.0, y = 0.0, z = 0.0), positionMode = "floor", accuracyMeters = 5.0,
            positionSource = PositionSource.gps)
        p.ingest(report = report, receivedAt = t0)
        val b = p.step(now = t0 + 1).phones.firstOrNull { it.id == "phone-b" }
        assertEquals(PositionEstimate.Kind.measured, b?.selected?.kind)
        // accuracyMeters on the wire is already a 95 % radius.
        assertEquals(5.0, b?.selected?.uncertainty?.r95 ?: 0.0, 1e-9)
        integrationNoThrow { b?.selected?.validate() }
    }

    @Test
    fun testPeerAssessmentArrivesOverTheMeshAndAges() {
        val p = pipeline(null)
        val assessment = StubIntegrity(IntegrityAssessment.Status.rejected).assess(subjectId = "phone-c", evidence = emptyList(), now = t0)
        p.ingest(report = DeviceUpdate(id = "phone-c", epochId = integrationUUID(), sequence = 1, role = "mobile",
            position = Position(x = 0.0, y = 0.0, z = 0.0), positionMode = "floor",
            positionSource = PositionSource.none), receivedAt = t0)
        val message = RelayMessage(originId = "phone-c", epochId = integrationUUID(), sequence = 1, timestamp = t0,
            frameId = "hervanta-v1", hopsRemaining = 3, path = listOf("phone-b"),
            freshness = Freshness(ageAtHandoff = 2.0, maxAge = 5.0), payload = RelayMessage.Payload.integrity(assessment))
        p.ingest(record = message, receivedAt = t0 + 1)
        assertEquals(IntegrityAssessment.Status.rejected,
            p.step(now = t0 + 2).phones.firstOrNull { it.id == "phone-c" }?.integrity?.status)
        // 2 s old on arrival + 3 s here = 5 s: still current; one more second and it is stale.
        assertNotNull(p.step(now = t0 + 4).phones.firstOrNull { it.id == "phone-c" }?.integrity)
        assertNull(p.step(now = t0 + 4.5).phones.firstOrNull { it.id == "phone-c" }?.integrity)
        // The phone's own assessment goes out as a record.
        val q = pipeline(StubIntegrity(IntegrityAssessment.Status.trusted))
        q.ingest(fix = fix("phone-a", x = 1.0, z = 1.0, at = t0), receivedAt = t0)
        val out = q.step(now = t0 + 1)
        val own = out.records.firstOrNull() as? RelayMessage.Payload.integrity ?: return fail("no record")
        assertEquals("phone-a", own.value.subjectId)
    }

    @Test
    fun testOwnPositioningEstimateIsUsedWhileFreshAndOnlyIfInferred() {
        val p = pipeline(null)
        val dr = PositionEstimate(subjectId = "phone-a", timestamp = t0, frameId = "hervanta-v1", kind = PositionEstimate.Kind.estimated,
            method = PositionEstimate.Method.deadReckoning, position = Position(x = 5.0, y = 0.0, z = 6.0),
            uncertainty = PositionUncertainty(r95 = 4.0), source = EvidenceSource.inertial, freshness = Freshness(maxAge = 3.0),
            provenance = Provenance(producerId = "phone-a", algorithm = "pdr@1", gnssDependent = true))
        p.ingest(ownEstimate = dr, receivedAt = t0)
        val me = p.step(now = t0 + 1).phones.firstOrNull { it.isSelf }
        assertEquals(PositionEstimate.Method.deadReckoning, me?.selected?.method)
        assertEquals(dr, me?.estimate)
        assertNull("stale after maxAge", p.step(now = t0 + 5).phones.firstOrNull { it.isSelf }?.estimate)
        // A measured fix through this door is ignored: GNSS comes in as a raw fix and is judged first.
        p.ingest(ownEstimate = fix("phone-a", x = 1.0, z = 1.0, at = t0 + 6), receivedAt = t0 + 6)
        assertNull(p.step(now = t0 + 7).phones.firstOrNull { it.isSelf }?.estimate)
    }

    @Test
    fun testFusedAndUWBReportsMapHonestlyAndOnlyMeasuredAnchors() {
        val p = pipeline(null)
        fun report(id: String, source: PositionSource, x: Double, neighbors: List<NeighborObservation> = emptyList()): DeviceUpdate =
            DeviceUpdate(id = id, epochId = integrationUUID(), sequence = 1, role = "mobile",
                position = Position(x = x, y = 0.0, z = 0.0), positionMode = "floor", accuracyMeters = 4.0,
                neighbors = neighbors, positionSource = source)
        p.ingest(report = report("phone-f", PositionSource.fused, x = 5.0), receivedAt = t0)
        p.ingest(report = report("phone-u", PositionSource.uwb, x = 9.0), receivedAt = t0)
        p.ingest(report = report("phone-l", PositionSource.none, x = 0.0,
            neighbors = listOf(NeighborObservation(id = "phone-f", rssi = -65, ageMs = 0))), receivedAt = t0)
        val phones = p.step(now = t0 + 1).phones
        assertEquals(PositionEstimate.Kind.estimated, phones.firstOrNull { it.id == "phone-f" }?.selected?.kind)
        assertEquals(PositionEstimate.Method.fusion, phones.firstOrNull { it.id == "phone-f" }?.selected?.method)
        assertEquals(PositionEstimate.Kind.measured, phones.firstOrNull { it.id == "phone-u" }?.selected?.kind)
        assertEquals(PositionEstimate.Method.uwb, phones.firstOrNull { it.id == "phone-u" }?.selected?.method)
        // The lost phone hears only the fused phone, which may not anchor it.
        assertNull(phones.firstOrNull { it.id == "phone-l" }?.estimate)
    }

    @Test
    fun testLostPeerBecomesAGrowingPredictionThenRecovers() {
        val p = pipeline(null)
        p.ingest(report = DeviceUpdate(id = "phone-b", epochId = integrationUUID(), sequence = 1, role = "mobile",
            position = Position(x = 10.0, y = 0.0, z = 0.0), positionMode = "floor", accuracyMeters = 5.0,
            positionSource = PositionSource.gps), receivedAt = t0)
        p.step(now = t0 + 1)
        val lost = p.step(now = t0 + 40).phones.firstOrNull { it.id == "phone-b" }
        assertEquals(PositionEstimate.Kind.predicted, lost?.selected?.kind)
        val later = p.step(now = t0 + 100).phones.firstOrNull { it.id == "phone-b" }
        assertTrue((later?.selected?.uncertainty?.r95 ?: 0.0) > (lost?.selected?.uncertainty?.r95 ?: Double.POSITIVE_INFINITY))
        integrationNoThrow { later?.prediction?.validate() }
        p.ingest(report = DeviceUpdate(id = "phone-b", epochId = integrationUUID(), sequence = 1, role = "mobile",
            position = Position(x = 12.0, y = 0.0, z = 0.0), positionMode = "floor", accuracyMeters = 5.0,
            positionSource = PositionSource.gps), receivedAt = t0 + 101)
        assertEquals(PositionEstimate.Kind.measured, p.step(now = t0 + 102).phones.firstOrNull { it.id == "phone-b" }?.selected?.kind)
    }
}

/**
 * Every scenario in contract/scenarios/ runs headless through ScenarioWorld with today's engines.
 * Gating expectations must pass; the others are reported (contract/scenarios/run.sh prints them;
 * on Android they are printed to the test's standard output).
 */
class ScenarioTests {
    companion object {
        val folder = File(System.getProperty("repo.root") ?: "..", "contract/scenarios")
    }

    @Test
    fun testScenariosRunAndGatingExpectationsHold() {
        val names = (folder.list() ?: emptyArray()).filter { it.endsWith(".json") }.sorted()
        assertFalse(names.isEmpty())
        val failures = mutableListOf<String>()
        for (name in names) {
            val scenario = MeshJson.decodeFromString(Scenario.serializer(), File(folder, name).readText())
            // Baseline engines only (build 7's estimator and walking circle, no integrity), and every
            // merged GhostCore engine, as the app runs them: integrity monitor, PeerLocator, GhostPredictor.
            val worlds = listOf(
                "baseline" to ScenarioWorld(scenario = scenario),
                "ghostcore" to ScenarioWorld(scenario = scenario,
                    integrity = { id, frame -> GNSSIntegrityMonitor(subjectId = id, frameId = frame) },
                    positioning = { id, frame -> Positioning.PeerLocator(producerId = id, frameId = frame) },
                    prediction = { id, frame -> GhostPredictor(producerId = id, frameId = frame) }),
            )
            for ((label, world) in worlds) {
                val report = world.run()
                println(report.table.replace("scenario|", "scenario|$label|"))
                if (report.gateFailures.isNotEmpty()) failures.add("$label ${scenario.id}: ${report.gateFailures.map { it.id }}")
            }
        }
        assertEquals(emptyList<String>(), failures)
    }
}
