package com.hackathonmapper.meshcore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

/** One check at a time on hand-made inputs, then the contract monitor end to end. */
class GNSSIntegrityTests {
    private fun fix(time: Double, x: Double, z: Double, accuracy: Double = 5.0, speed: Double? = null,
                    course: Double? = null, speedAccuracy: Double? = null): GNSSFix =
        GNSSFix(time = time, position = FloorPoint(x = x, z = z), accuracy = accuracy, speed = speed, course = course,
            speedAccuracy = speedAccuracy)

    private fun still(engine: GNSSIntegrityEngine, time: Double) {
        engine.addMotion(InertialDisplacement(start = time - 1, end = time, dx = 0.0, dz = 0.0, sigma = 0.02, stationary = true))
    }

    /** A phone lying still with motion data and steady fixes, for `seconds` seconds. */
    private fun trustedStillPhone(seconds: Int = 20): GNSSIntegrityEngine {
        val engine = GNSSIntegrityEngine()
        for (t in 1..seconds) {
            still(engine, t.toDouble())
            engine.assess(fix(t.toDouble(), if (t % 2 == 0) 1.0 else -1.0, 0.0))
        }
        return engine
    }

    @Test
    fun testGNSSAloneIsNeverTrusted() {
        val engine = GNSSIntegrityEngine()
        var last: GNSSIntegrityAssessment? = null
        for (t in 1..60) {
            last = engine.assess(fix(t.toDouble(), 1.4 * t, 0.0, speed = 1.4, course = 90.0))
            assertNotEquals(GNSSIntegrityStatus.trusted, last.status)
        }
        assertEquals(GNSSIntegrityStatus.insufficientEvidence, last?.status)
        assertEquals(listOf(GNSSReasonCode.insufficientEvidence), last?.reasons)
        assertNull("nothing independent bounds the error", last?.uncertainty?.minimumDetectableOffset)
        assertEquals(0.0, last!!.uncertainty.trustLower, 0.0)
        assertTrue(last.usableAsPosition)
    }

    @Test
    fun testInertialAgreementMakesTrusted() {
        val engine = trustedStillPhone()
        val last = engine.latest!!
        assertEquals(GNSSIntegrityStatus.trusted, last.status)
        assertEquals("GPS agrees with steps and compass", last.summary)
        assertTrue(last.evidence.any { it.check == GNSSCheck.inertial && it.independent })
        assertTrue((last.uncertainty.minimumDetectableOffset ?: Double.POSITIVE_INFINITY) <= 50)
        assertNotNull(last.uncertainty.minimumDetectableDriftRate)
    }

    @Test
    fun testJumpIsRejectedAtOnceAndNotCalledAnAttack() {
        val engine = trustedStillPhone()
        still(engine, 21.0)
        val jumped = engine.assess(fix(21.0, 400.0, 0.0))
        assertEquals(GNSSIntegrityStatus.rejected, jumped.status)
        assertTrue(jumped.reasons.contains(GNSSReasonCode.impossibleSpeed))
        assertTrue(jumped.reasons.contains(GNSSReasonCode.positionJump))
        assertTrue(jumped.reasons.contains(GNSSReasonCode.inertialDisagreement))
        assertFalse(jumped.spoofingConfirmed)
        assertTrue(jumped.summary, jumped.summary.endsWith("not proof of an attack"))
        assertTrue(jumped.possibleCauses.contains(GNSSPossibleCause.multipath))
        assertTrue(jumped.possibleCauses.contains(GNSSPossibleCause.receiverFault))
        assertNull(jumped.uncertainty.recommendedSigma)
        assertFalse(jumped.usableAsPosition)
        // The fix stays out of the reference, so the next one at the same place is still rejected.
        still(engine, 22.0)
        assertTrue(engine.assess(fix(22.0, 400.0, 0.0)).isAnomaly)
    }

    @Test
    fun testFixesThatStopGoStaleThenUnavailable() {
        val engine = trustedStillPhone()
        still(engine, 21.0)
        assertEquals(GNSSIntegrityStatus.trusted, engine.assess(21.0).status)
        val aging = engine.assess(26.0)
        assertEquals(GNSSIntegrityStatus.degraded, aging.status)
        assertEquals(listOf(GNSSReasonCode.staleFix), aging.reasons)
        assertTrue("uncertainty grows with age", aging.uncertainty.recommendedSigma!! > 2 * 5 / 1.515)
        val gone = engine.assess(51.0)
        assertEquals(GNSSIntegrityStatus.unavailable, gone.status)
        assertEquals(listOf(GNSSReasonCode.staleFix), gone.reasons)
    }

    @Test
    fun testLateFixIsStale() {
        val engine = trustedStillPhone()
        still(engine, 30.0)
        val late = engine.assess(fix(20.5, 0.0, 0.0), 30.0)
        assertEquals(GNSSIntegrityStatus.degraded, late.status)
        assertTrue(late.reasons.contains(GNSSReasonCode.staleFix))
    }

    @Test
    fun testPoorAccuracyDegradesAndHopelessAccuracyIsUnavailable() {
        val engine = trustedStillPhone()
        still(engine, 21.0)
        val coarse = engine.assess(fix(21.0, 0.0, 0.0, accuracy = 40.0))
        assertEquals(GNSSIntegrityStatus.degraded, coarse.status)
        assertEquals(listOf(GNSSReasonCode.degradedAccuracy), coarse.reasons)
        assertEquals("GPS accuracy 40 m", coarse.summary)
        still(engine, 22.0)
        val hopeless = engine.assess(fix(22.0, 0.0, 0.0, accuracy = 150.0))
        assertEquals(GNSSIntegrityStatus.unavailable, hopeless.status)
        assertEquals(listOf(GNSSReasonCode.degradedAccuracy), hopeless.reasons)
    }

    @Test
    fun testInvalidFixIsIgnored() {
        val engine = GNSSIntegrityEngine()
        val first = engine.assess(fix(1.0, 0.0, 0.0, accuracy = -1.0))
        assertEquals(GNSSIntegrityStatus.unavailable, first.status)
        assertEquals(listOf(GNSSReasonCode.invalidFix), first.reasons)
    }

    @Test
    fun testTimestampGoingBackIsRejected() {
        val engine = trustedStillPhone()
        still(engine, 21.0)
        val replayed = engine.assess(fix(15.0, 0.0, 0.0), 21.0)
        assertEquals(GNSSIntegrityStatus.rejected, replayed.status)
        assertTrue(replayed.reasons.contains(GNSSReasonCode.timestampInconsistent))
    }

    @Test
    fun testImpossibleAccelerationFromReportedVelocity() {
        val engine = GNSSIntegrityEngine()
        for (t in 1..10) {
            engine.assess(fix(t.toDouble(), 0.0, 1.4 * t, speed = 1.4, course = 0.0, speedAccuracy = 0.3))
        }
        // 1.4 to 6.5 m/s in half a second: fast, but not too fast; the change is what is impossible.
        val burst = engine.assess(fix(10.5, 0.0, 14.7, speed = 6.5, course = 0.0, speedAccuracy = 0.3))
        assertTrue("${burst.reasons}", burst.reasons.contains(GNSSReasonCode.impossibleAcceleration))
        assertFalse(burst.reasons.contains(GNSSReasonCode.impossibleSpeed))
        assertTrue(burst.isAnomaly)
    }

    @Test
    fun testStillPhoneWhoseGPSWandersOff() {
        val engine = trustedStillPhone()
        var flagged: GNSSIntegrityAssessment? = null
        for (t in 21..120) {
            if (flagged != null) break
            still(engine, t.toDouble())
            val assessment = engine.assess(fix(t.toDouble(), 0.5 * (t - 20), 0.0))
            if (assessment.isAnomaly) flagged = assessment
        }
        val caught = flagged!!
        assertTrue("${caught.reasons}", caught.reasons.contains(GNSSReasonCode.inertialDisagreement) ||
            caught.reasons.contains(GNSSReasonCode.slowDrift) || caught.reasons.contains(GNSSReasonCode.positionJump))
        assertTrue("0.5 m/s drift on a still phone is caught before 30 m", caught.fix!!.position.x < 30)
    }

    @Test
    fun testPeersPlacedByGPSCanObjectButNeverVerify() {
        val engine = GNSSIntegrityEngine()
        val layout = listOf("a" to 10.0, "b" to -8.0, "c" to 0.0)
        fun hear(time: Double) {
            for ((id, x) in layout) {
                engine.addPeer(PeerProximity(time = time, peerId = id, peerPosition = FloorPoint(x = x, z = 5.0), peerSigma = 3.0,
                    origin = EvidenceOrigin.gnssDerived, maxRange = 30.0))
            }
        }
        for (t in 1..30) {
            hear(t.toDouble())
            val assessment = engine.assess(fix(t.toDouble(), 0.0, 0.0))
            assertNotEquals(GNSSIntegrityStatus.trusted, assessment.status)
        }
        val agreeing = engine.latest!!
        assertEquals(GNSSIntegrityStatus.insufficientEvidence, agreeing.status)
        assertTrue(agreeing.reasons.contains(GNSSReasonCode.peerEvidenceNotIndependent))
        assertEquals("GPS unchecked: peers agree, but they use GPS too", agreeing.summary)

        val fresh = GNSSIntegrityEngine()
        for ((id, x) in layout) {
            fresh.addPeer(PeerProximity(time = 1.0, peerId = id, peerPosition = FloorPoint(x = x, z = 5.0), peerSigma = 3.0,
                origin = EvidenceOrigin.gnssDerived, maxRange = 30.0))
        }
        val far = fresh.assess(fix(1.0, 300.0, 0.0))
        assertTrue(far.isAnomaly)
        assertEquals(GNSSReasonCode.peerDisagreement, far.reasons.firstOrNull())
        assertTrue(far.possibleCauses.contains(GNSSPossibleCause.peerOrAnchorError))
    }

    @Test
    fun testOnePeerOutOfThreeCannotCondemnAFix() {
        val engine = GNSSIntegrityEngine()
        engine.addPeer(PeerProximity(time = 1.0, peerId = "a", peerPosition = FloorPoint(x = 5.0, z = 0.0), peerSigma = 3.0,
            origin = EvidenceOrigin.gnssDerived, maxRange = 30.0))
        engine.addPeer(PeerProximity(time = 1.0, peerId = "b", peerPosition = FloorPoint(x = -5.0, z = 0.0), peerSigma = 3.0,
            origin = EvidenceOrigin.gnssDerived, maxRange = 30.0))
        engine.addPeer(PeerProximity(time = 1.0, peerId = "c", peerPosition = FloorPoint(x = 900.0, z = 0.0), peerSigma = 3.0,
            origin = EvidenceOrigin.gnssDerived, maxRange = 30.0))
        assertFalse(engine.assess(fix(1.0, 0.0, 0.0)).isAnomaly)
    }

    @Test
    fun testSurveyedBeaconIsIndependentEvidence() {
        val engine = GNSSIntegrityEngine()
        for (t in 1..10) {
            engine.addPeer(PeerProximity(time = t.toDouble(), peerId = "beacon", peerPosition = FloorPoint(x = 8.0, z = 0.0),
                peerSigma = 1.0, origin = EvidenceOrigin.surveyed, maxRange = 25.0))
            engine.assess(fix(t.toDouble(), 0.0, 0.0))
        }
        assertEquals(GNSSIntegrityStatus.trusted, engine.latest?.status)
        assertEquals("GPS agrees with a surveyed beacon", engine.latest?.summary)
    }

    @Test
    fun testContinuityLostAfterLongRejectionUntilIndependentPositionAgrees() {
        val engine = GNSSIntegrityEngine()
        for (t in 1..10) engine.assess(fix(t.toDouble(), 0.0, 0.0))
        assertEquals(GNSSIntegrityStatus.rejected, engine.assess(fix(11.0, 400.0, 0.0)).status)
        var back: GNSSIntegrityAssessment? = null
        for (t in 12..600) {
            if (back != null) break
            val assessment = engine.assess(fix(t.toDouble(), 400.0, 0.0))
            if (!assessment.isAnomaly) back = assessment
        }
        // Without motion the reference loosens until 400 m is reachable; GNSS is taken back, but
        // never as trusted.
        val returned = back!!
        assertEquals(GNSSIntegrityStatus.insufficientEvidence, returned.status)
        assertTrue("${returned.reasons}", returned.reasons.contains(GNSSReasonCode.continuityLost))
        assertEquals("GPS consistent again after an anomaly; not re-verified yet", returned.summary)

        val time = returned.time + 1
        engine.addPositionEvidence(PositionEvidence(time = time, position = FloorPoint(x = 402.0, z = 1.0), sigma = 2.0,
            origin = EvidenceOrigin.surveyed))
        assertEquals(GNSSIntegrityStatus.trusted, engine.assess(fix(time, 400.0, 0.0)).status)
    }

    @Test
    fun testRecoveryIsNeverInstant() {
        val engine = trustedStillPhone()
        for (t in 21..40) {
            still(engine, t.toDouble())
            engine.assess(fix(t.toDouble(), 60.0, 0.0))
        }
        assertTrue(engine.latest!!.isAnomaly)
        val statuses = mutableListOf<GNSSIntegrityStatus>()
        var sawRecovering = false
        for (t in 41..70) {
            still(engine, t.toDouble())
            val assessment = engine.assess(fix(t.toDouble(), if (t % 2 == 0) 1.0 else -1.0, 0.0))
            statuses.add(assessment.status)
            sawRecovering = sawRecovering || assessment.reasons.contains(GNSSReasonCode.recovering)
        }
        assertTrue(sawRecovering)
        assertFalse("$statuses", statuses.take(5).contains(GNSSIntegrityStatus.trusted))
        assertEquals(GNSSIntegrityStatus.trusted, statuses.last())
    }

    @Test
    fun testIndependentPositionEstimateObjects() {
        val engine = GNSSIntegrityEngine()
        engine.addPositionEvidence(PositionEvidence(time = 1.0, position = FloorPoint(x = 120.0, z = 0.0), sigma = 5.0,
            origin = EvidenceOrigin.surveyed))
        val assessment = engine.assess(fix(1.0, 0.0, 0.0))
        assertTrue(assessment.isAnomaly)
        assertTrue(assessment.reasons.contains(GNSSReasonCode.independentEvidenceDisagreement))
    }

    @Test
    fun testDistanceOutsideHeadingAndStepBias() {
        val angle = 10 * Math.PI / 180
        // Inside the fan: 100 m north with a 5° heading error and 5 % scale error.
        val inside = GNSSIntegrityEngine.distanceOutsideBias(gx = 105 * sin(0.087), gz = 105 * cos(0.087), ix = 0.0, iz = 100.0,
            maxAngle = angle, maxScale = 0.08)
        assertEquals(0.0, inside, 1e-9)
        // Straight ahead but 30 % too far: 22 m beyond the 8 % scale allowance.
        assertEquals(22.0, GNSSIntegrityEngine.distanceOutsideBias(gx = 0.0, gz = 130.0, ix = 0.0, iz = 100.0,
            maxAngle = angle, maxScale = 0.08), 1e-9)
        // 50 m sideways after 100 m: 26.57° off, so 16.57° beyond the 10° edge: 111.8 m · sin 16.57°.
        val sideways = GNSSIntegrityEngine.distanceOutsideBias(gx = 50.0, gz = 100.0, ix = 0.0, iz = 100.0,
            maxAngle = angle, maxScale = 0.08)
        assertEquals(hypot(50.0, 100.0) * sin(atan2(50.0, 100.0) - angle), sideways, 1e-9)
        // No inertial motion: the whole GNSS displacement counts.
        assertEquals(5.0, GNSSIntegrityEngine.distanceOutsideBias(gx = 3.0, gz = 4.0, ix = 0.0, iz = 0.0,
            maxAngle = angle, maxScale = 0.08), 0.0)
    }

    @Test
    fun testNoWordingClaimsSpoofing() {
        for (status in GNSSIntegrityStatus.entries) assertFalse(status.rawValue.lowercase().contains("spoof"))
        for (reason in GNSSReasonCode.entries) assertFalse(reason.rawValue.lowercase().contains("spoof"))
        for (scenario in GNSSScenario.library) {
            val world = GNSSSimulatedWorld(scenario, 1u)
            for (assessment in GNSSFaultHarness.run(world, GNSSDetectorConfig.full).assessments) {
                assertFalse(assessment.summary, assessment.summary.lowercase().contains("spoof"))
                assertTrue(assessment.summary.length <= 160)
                assertFalse(assessment.spoofingConfirmed)
                if (assessment.possibleCauses.contains(GNSSPossibleCause.spoofing)) {
                    assertTrue("spoofing is never the only candidate", assessment.possibleCauses.size > 1)
                }
                if (assessment.isAnomaly) assertFalse(assessment.reasons.isEmpty())
            }
        }
    }

    // MARK: Contract monitor

    private val epoch = 1_793_000_000.0

    /** Feeds a simulated world through the monitor in the pipeline's order. */
    private fun replay(world: GNSSSimulatedWorld, monitor: GNSSIntegrityMonitor,
                       beacons: Boolean = true): List<IntegrityAssessment> =
        (1..world.scenario.duration).map { second ->
            val inputs = world.contractInputs(second, subjectId = monitor.subjectId, epoch = epoch)
            inputs.motion?.let { monitor.ingest(motion = it) }
            for (peer in inputs.peers) {
                if (beacons || peer.position.provenance.gnssDependent) {
                    monitor.ingest(peer = peer.observation, peerPosition = peer.position,
                        peerStatus = IntegrityAssessment.Status.trusted)
                }
            }
            val now = epoch + second
            inputs.fix?.let { monitor.assess(fix = it, now = now) } ?: monitor.assess(now = now)
        }

    @Test
    fun testMonitorRecordsAreValidAndMatchTheEngine() {
        val names = listOf("clean walk", "S2 jump 400 m", "S3 drift 1 m/s", "S4 drift removed", "jamming 60 s",
            "fixes 15 s late", "dropout 60 s", "common-mode drift 0.5 m/s, anchor at 600 s", "clean walk, urban multipath")
        for (name in names) {
            val scenario = GNSSScenario.named(name)!!
            val world = GNSSSimulatedWorld(scenario, 2u)
            val native = GNSSFaultHarness.run(world, GNSSDetectorConfig.full).assessments
            val records = replay(world, GNSSIntegrityMonitor(subjectId = "phone-c"))
            var matches = 0
            for ((index, record) in records.withIndex()) {
                try {
                    record.validate()
                } catch (error: Exception) {
                    throw AssertionError("$name t=${index + 1}: $record", error)
                }
                assertTrue(record.provenance.simulated)
                assertEquals("gnss-integrity@1", record.provenance.algorithm)
                if (record.status == IntegrityAssessment.Status.unavailable) assertNull(record.evaluatedFix)
                val fix = world.fixes[index + 1]
                if (fix != null && record.status != IntegrityAssessment.Status.unavailable) {
                    assertEquals(fix.position.x, record.evaluatedFix?.position?.x ?: Double.NaN, 1e-9)
                }
                if (record.status.rawValue == native[index].status.rawValue) matches += 1
            }
            // The contract carries no speed accuracy, so the acceleration check is a little looser.
            assertTrue(name, matches.toDouble() / records.size.toDouble() >= 0.99)
        }
    }

    @Test
    fun testMonitorUsesIndependenceFromProvenance() {
        fun estimate(time: Double, gnssDependent: Boolean): PositionEstimate =
            PositionEstimate(subjectId = "phone-b", timestamp = time, frameId = "hervanta-v1",
                kind = PositionEstimate.Kind.estimated, method = PositionEstimate.Method.particle,
                position = Position(x = 2.0, y = 0.0, z = 1.0), uncertainty = PositionUncertainty(r95 = 8.0),
                source = EvidenceSource.bluetooth, freshness = Freshness(maxAge = 5.0),
                provenance = Provenance(producerId = "phone-a", algorithm = "bluetooth-estimator@1",
                    contributors = listOf("phone-a", "phone-b"), gnssDependent = gnssDependent))
        fun raw(time: Double): PositionEstimate =
            PositionEstimate(subjectId = "phone-b", timestamp = time, frameId = "hervanta-v1",
                kind = PositionEstimate.Kind.measured, method = PositionEstimate.Method.gnss,
                position = Position(x = 0.0, y = 0.0, z = 0.0), uncertainty = PositionUncertainty(r95 = 8.0),
                source = EvidenceSource.gnss, freshness = Freshness(maxAge = 30.0),
                provenance = Provenance(producerId = "phone-b", algorithm = "corelocation@1", gnssDependent = true))
        for (gnssDependent in listOf(true, false)) {
            val monitor = GNSSIntegrityMonitor(subjectId = "phone-b")
            var record: IntegrityAssessment? = null
            for (t in 1..10) {
                val now = epoch + t
                monitor.ingest(fix = raw(now))
                record = monitor.assess(subjectId = "phone-b", evidence = listOf(estimate(now, gnssDependent)), now = now)
            }
            record!!.validate()
            assertEquals(if (gnssDependent) IntegrityAssessment.Status.insufficientEvidence
                else IntegrityAssessment.Status.trusted, record.status)
            assertEquals(!gnssDependent, record.mayAnchorOthers)
            assertEquals(!gnssDependent, record.evidence.firstOrNull { it.check == "positionEvidence" }?.independent)
            if (gnssDependent) assertTrue(record.reasons.contains(IntegrityAssessment.Reason.peerEvidenceNotIndependent))
            assertNotNull(monitor.displayR95)
        }
    }

    /** Own estimates are named as own, and ones built from this phone's own GNSS are not evidence. */
    @Test
    fun testOwnEstimatesAreNamedByWhereTheyCameFrom() {
        fun raw(time: Double, x: Double): PositionEstimate =
            PositionEstimate(subjectId = "phone-b", timestamp = time, frameId = "hervanta-v1",
                kind = PositionEstimate.Kind.measured, method = PositionEstimate.Method.gnss,
                position = Position(x = x, y = 0.0, z = 0.0), uncertainty = PositionUncertainty(r95 = 8.0),
                source = EvidenceSource.gnss, freshness = Freshness(maxAge = 30.0),
                provenance = Provenance(producerId = "phone-b", algorithm = "corelocation@1", gnssDependent = true))
        fun own(time: Double, method: PositionEstimate.Method, inputs: List<ProvenanceInput>,
                contributors: List<String> = listOf("phone-b"), producer: String = "phone-b",
                gnssDependent: Boolean): PositionEstimate =
            PositionEstimate(subjectId = "phone-b", timestamp = time, frameId = "hervanta-v1",
                kind = PositionEstimate.Kind.estimated, method = method,
                position = Position(x = 0.0, y = 0.0, z = 0.0), uncertainty = PositionUncertainty(r95 = 8.0),
                source = if (method == PositionEstimate.Method.deadReckoning) EvidenceSource.inertial else EvidenceSource.fusion,
                freshness = Freshness(maxAge = 5.0),
                provenance = Provenance(producerId = producer, algorithm = "position-engine@1", inputs = inputs,
                    contributors = contributors, gnssDependent = gnssDependent))
        fun judge(estimate: (Double) -> PositionEstimate): IntegrityAssessment {
            val monitor = GNSSIntegrityMonitor(subjectId = "phone-b")
            var record: IntegrityAssessment? = null
            for (t in 1..3) {
                val now = epoch + t
                monitor.ingest(fix = raw(now, x = 120.0))
                record = monitor.assess(subjectId = "phone-b", evidence = listOf(estimate(now)), now = now)
            }
            record!!.validate()
            return record
        }
        // Dead reckoning seeded by this phone's own fix (the positioning engine records it unnamed): circular.
        val seeded = judge {
            own(it, PositionEstimate.Method.deadReckoning, listOf(ProvenanceInput(source = EvidenceSource.gnss)),
                gnssDependent = true)
        }
        assertFalse(seeded.evidence.any { it.check == "positionEvidence" })
        // Depends on GNSS, but no peer took part: this phone's own GNSS again.
        val ownGNSS = judge {
            own(it, PositionEstimate.Method.fusion, listOf(ProvenanceInput(source = EvidenceSource.inertial)),
                gnssDependent = true)
        }
        assertFalse(ownGNSS.evidence.any { it.check == "positionEvidence" })
        // Dead reckoning from a declared spot: this phone's own, and independent of GNSS.
        val declared = judge {
            own(it, PositionEstimate.Method.deadReckoning, listOf(ProvenanceInput(source = EvidenceSource.manual)),
                gnssDependent = false)
        }
        assertTrue(declared.status in listOf(IntegrityAssessment.Status.suspect, IntegrityAssessment.Status.rejected))
        assertTrue(declared.reasons.contains(IntegrityAssessment.Reason.independentEvidenceDisagreement))
        assertFalse(declared.reasons.contains(IntegrityAssessment.Reason.peerDisagreement))
        assertEquals("GPS 120 m from this phone's own position estimate; not proof of an attack", declared.summary)
        assertEquals(true, declared.evidence.firstOrNull { it.check == "positionEvidence" }?.independent)
        // Placed from peers that use GPS: peer-based, objects but is not independent.
        val peerBased = judge {
            own(it, PositionEstimate.Method.multilateration,
                listOf(ProvenanceInput(source = EvidenceSource.bluetooth, id = "phone-a"),
                    ProvenanceInput(source = EvidenceSource.gnss, id = "phone-a")),
                contributors = listOf("phone-b", "phone-a"), gnssDependent = true)
        }
        assertTrue(peerBased.reasons.contains(IntegrityAssessment.Reason.peerDisagreement))
        assertEquals("GPS 120 m from the peer-based position estimate; not proof of an attack", peerBased.summary)
        assertEquals(false, peerBased.evidence.firstOrNull { it.check == "positionEvidence" }?.independent)
    }

    /**
     * The pipeline's protocol on top of the monitor. On iOS the conformance lives in the integration
     * lead's files, so the Swift test wraps instead of using it; the wrapper is kept here likewise.
     */
    private class MonitorEngine(subjectId: String, frameId: String) : GhostIntegrityEngine {
        val monitor = GNSSIntegrityMonitor(subjectId = subjectId, frameId = frameId)
        override fun ingest(fix: PositionEstimate) = monitor.ingest(fix = fix)
        override fun ingest(motion: MotionObservation) = monitor.ingest(motion = motion)
        override fun assess(subjectId: String, evidence: List<PositionEstimate>, now: Double): IntegrityAssessment =
            monitor.assess(subjectId = subjectId, evidence = evidence, now = now)
    }

    /** contract/scenarios through the real GhostCorePipeline with this engine as its integrity engine. */
    @Test
    fun testContractScenariosWithThisEngine() {
        val folder = File(System.getProperty("repo.root") ?: "../..", "contract/scenarios")
        val names = (folder.list() ?: emptyArray()).filter { it.endsWith(".json") }.sorted()
        assertFalse(names.isEmpty())
        for (name in names) {
            val text = File(folder, name).readText()
            val scenario = MeshJson.decodeFromString(Scenario.serializer(), text)
            val report = ScenarioWorld(scenario = scenario, integrity = { subject, frame -> MonitorEngine(subject, frame) }).run()
            println(report.table)
            assertEquals("${scenario.id}: ${report.gateFailures.map { it.id }}", emptyList<ScenarioWorld.Result>(),
                report.gateFailures)
            assertFalse(report.results.any { it.outcome == ScenarioWorld.Outcome.pending && it.detail.contains("integrity") })
        }
    }

    @Test
    fun testMonitorWithoutFixIsUnavailable() {
        val monitor = GNSSIntegrityMonitor(subjectId = "phone-b")
        val record = monitor.assess(now = epoch)
        record.validate()
        assertEquals(IntegrityAssessment.Status.unavailable, record.status)
        assertEquals(listOf(IntegrityAssessment.Reason.noFix), record.reasons)
        assertNull(record.evaluatedFix)
        assertNull(monitor.displayR95)
    }
}
