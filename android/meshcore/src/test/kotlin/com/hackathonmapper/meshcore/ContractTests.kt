package com.hackathonmapper.meshcore

import java.io.File
import java.util.UUID
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The GhostCore contract: golden fixtures in contract/fixtures/ (shared with
 * website/scripts/ghostcore-check.ts) decode, validate and round-trip; the invalid ones are refused;
 * freshness, uncertainty, provenance and relay rules behave as ARCHITECTURE.md describes.
 */
class ContractTests {
    companion object {
        private val fixtures = File(System.getProperty("repo.root") ?: "..", "contract/fixtures")

        private fun type(name: String): KSerializer<out GhostRecord> = when (name.split("-").first()) {
            "peer" -> PeerObservation.serializer()
            "position", "provenance" -> PositionEstimate.serializer()
            "integrity" -> IntegrityAssessment.serializer()
            "motion" -> MotionObservation.serializer()
            "prediction" -> Prediction.serializer()
            else -> RelayMessage.serializer()
        }
    }

    private fun data(name: String): String = File(fixtures, name).readText()

    private fun <T : GhostRecord> decode(serializer: KSerializer<T>, name: String): T {
        val record = MeshJson.decodeFromString(serializer, data(name))
        record.validate()
        return record
    }

    private fun roundTrip(type: KSerializer<out GhostRecord>, text: String) {
        @Suppress("UNCHECKED_CAST")
        val serializer = type as KSerializer<GhostRecord>
        val record = MeshJson.decodeFromString(serializer, text)
        record.validate()
        assertEquals(record, MeshJson.decodeFromString(serializer, MeshJson.encodeToString(serializer, record)))
    }

    private fun assertNoThrow(message: String = "", block: () -> Unit) {
        try {
            block()
        } catch (e: Throwable) {
            throw AssertionError("$message: unexpected $e", e)
        }
    }

    @Test
    fun testValidFixturesDecodeValidateAndRoundTrip() {
        val names = (fixtures.list() ?: emptyArray()).filter { it.endsWith(".json") }.sorted()
        assertEquals(9, names.size)
        for (name in names) {
            assertNoThrow(name) { roundTrip(type(name), data(name)) }
        }
    }

    @Test
    fun testInvalidFixturesAreRefused() {
        val folder = File(fixtures, "invalid")
        val names = (folder.list() ?: emptyArray()).filter { it.endsWith(".json") }
        assertEquals(10, names.size)
        for (name in names) {
            val wrapper = MeshJson.parseToJsonElement(File(folder, name).readText()) as? JsonObject
            val record = MeshJson.encodeToString(kotlinx.serialization.json.JsonElement.serializer(), wrapper!!.getValue("record"))
            val type: KSerializer<out GhostRecord> = when ((wrapper["type"] as? JsonPrimitive)?.content) {
                "PeerObservation" -> PeerObservation.serializer()
                "PositionEstimate" -> PositionEstimate.serializer()
                "IntegrityAssessment" -> IntegrityAssessment.serializer()
                "Prediction" -> Prediction.serializer()
                else -> RelayMessage.serializer()
            }
            val expect = (wrapper["expect"] as? JsonPrimitive)?.content
            val error = try {
                roundTrip(type, record)
                null
            } catch (e: Throwable) {
                e
            }
            if (error == null) fail("$name: accepted")
            when {
                expect == "decode" && error is SerializationException -> Unit
                expect != null && error is GhostCoreContractError.invalid -> assertEquals(name, expect, error.field)
                else -> fail("$name: unexpected $error")
            }
        }
    }

    @Test
    fun testIntegrityCannotSaySpoofed() {
        val words = IntegrityAssessment.Status.entries.map { it.rawValue } + IntegrityAssessment.Reason.entries.map { it.rawValue }
        assertFalse(words.any { it.lowercase().contains("spoof") || it.lowercase().contains("attack") })
    }

    @Test
    fun testRejectedAssessmentKeepsTheRawFixAndMayNotAnchor() {
        val rejected = decode(IntegrityAssessment.serializer(), "integrity-rejected-jump.json")
        assertFalse(rejected.mayAnchorOthers)
        assertEquals(PositionEstimate.Method.gnss, rejected.evaluatedFix?.method)
        assertEquals(rejected.evaluatedFix?.timestamp, rejected.fixTimestamp)
        assertTrue(decode(IntegrityAssessment.serializer(), "integrity-trusted.json").mayAnchorOthers)
    }

    @Test
    fun testFreshnessAddsHoldTimesThenLocalAge() {
        val produced = Freshness(ageAtHandoff = 0.4, maxAge = 10.0)
        val relayed = produced.handedOn(heldFor = 1.1).handedOn(heldFor = 0.5)
        assertEquals(2.0, relayed.ageAtHandoff, 1e-9)
        assertEquals(5.0, relayed.age(receivedAt = 100.0, now = 103.0), 1e-9)
        assertFalse(relayed.isStale(receivedAt = 100.0, now = 108.0))
        assertTrue(relayed.isStale(receivedAt = 100.0, now = 108.5))
        // A receiver clock that reads earlier than the receipt never makes a record younger.
        assertEquals(2.0, relayed.age(receivedAt = 100.0, now = 99.0), 1e-9)
    }

    @Test
    fun testUncertaintyConversions() {
        assertEquals(2.4477, PositionUncertainty.r95(fromSigma = 1.0), 1e-4)
        assertEquals(16.21, PositionUncertainty.r95(fromRadius68 = 10.0), 0.01)
        val isotropic = PositionUncertainty(covariance = FloorCovariance(xx = 4.0, xz = 0.0, zz = 4.0))
        assertEquals(2 * 2.4477, isotropic.r95, 1e-3)
        // An ellipse is covered by the circle around its long axis.
        val ellipse = FloorCovariance(xx = 9.0, xz = 0.0, zz = 1.0)
        assertEquals(3 * 2.4477, PositionUncertainty(covariance = ellipse).r95, 1e-3)
    }

    @Test
    fun testProvenanceFlagsPropagateAndContributorsMerge() {
        val gps = Provenance(producerId = "phone-a", algorithm = "corelocation@1", gnssDependent = true)
        val sim = Provenance(producerId = "phone-c", algorithm = "scenario@1", gnssDependent = false, simulated = true)
        val derived = Provenance.derived(producerId = "phone-b", algorithm = "ghostcore-proximity@1", from = listOf(gps, sim))
        assertTrue(derived.gnssDependent)
        assertTrue(derived.simulated)
        assertEquals(listOf("phone-b", "phone-a", "phone-c"), derived.contributors)
        assertTrue(derived.contains(device = "phone-a"))
        assertNoThrow { derived.validate() }

        val many = (0 until 30).map { Provenance(producerId = "p$it", algorithm = "x@1", gnssDependent = false) }
        val capped = Provenance.derived(producerId = "me", algorithm = "x@1", from = many)
        assertEquals(GhostCoreContract.maxContributors, capped.contributors.size)
        assertEquals("me", capped.contributors.first())
        assertFalse(capped.gnssDependent)
    }

    @Test
    fun testRelayCopyKeepsIdentityAndRefusesLoops() {
        val message = decode(RelayMessage.serializer(), "relay-integrity.json")
        val copy = message.relayed(by = "phone-a", heldFor = 0.3)
        assertNotNull(copy)
        copy!!
        assertEquals(message.messageId, copy.messageId)
        assertEquals(message.originId, copy.originId)
        assertEquals(message.epochId, copy.epochId)
        assertEquals(message.sequence, copy.sequence)
        assertEquals(message.payload, copy.payload)
        assertEquals(message.hopsRemaining - 1, copy.hopsRemaining)
        assertEquals(listOf("phone-b", "phone-a"), copy.path)
        assertEquals(message.freshness.ageAtHandoff + 0.3, copy.freshness.ageAtHandoff, 1e-9)
        assertNoThrow { copy.validate() }
        assertNull("already on the path", message.relayed(by = "phone-b", heldFor = 0.0))
        assertNull("back to its origin", message.relayed(by = "phone-c", heldFor = 0.0))
        assertEquals(EvidenceSource.fusion, copy.source)
        assertEquals("phone-c", copy.provenance.producerId)
    }

    @Test
    fun testRelayMessagesFitOneMeshPacket() {
        for (name in listOf("relay-integrity.json", "relay-observations.json")) {
            val message = decode(RelayMessage.serializer(), name)
            assertTrue(name, message.encoded().size <= GhostCoreContract.maxRelayBytes)
            assertEquals(message, RelayMessage.decode(message.encoded()))
        }
        // Sixteen full snapshots do not fit; the relay has to split them.
        val observation = decode(PeerObservation.serializer(), "peer-observation.json")
        val message = decode(RelayMessage.serializer(), "relay-observations.json")
        val full = RelayMessage(messageId = message.messageId, originId = message.originId, epochId = message.epochId,
            sequence = 58, timestamp = message.timestamp, frameId = message.frameId,
            hopsRemaining = 4, freshness = message.freshness,
            payload = RelayMessage.Payload.observations(List(16) { observation }))
        try {
            full.encoded()
            fail("sixteen snapshots fit")
        } catch (e: GhostCoreContractError) {
            assertEquals(GhostCoreContractError.tooLarge, e)
        }
    }

    @Test
    fun testPredictionTravelsWithoutItsCloud() {
        val prediction = decode(Prediction.serializer(), "prediction-kalman.json")
        assertEquals(60.0, prediction.horizon, 1e-9)
        val make = { p: Prediction ->
            RelayMessage(originId = "phone-a", epochId = UUID.randomUUID().toString().uppercase(), sequence = 1,
                timestamp = p.timestamp, frameId = p.frameId, hopsRemaining = 4, freshness = Freshness(maxAge = 15.0),
                payload = RelayMessage.Payload.prediction(p))
        }
        assertTrue(runCatching { make(prediction).validate() }.isFailure)
        assertNoThrow { make(prediction.withoutCloud).validate() }
        val asPosition = prediction.asPositionEstimate
        assertNoThrow { asPosition.validate() }
        assertEquals(PositionEstimate.Kind.predicted, asPosition.kind)
        assertEquals(PositionSource.none, asPosition.dashboardSource)
    }

    @Test
    fun testOnlyMeasuredGNSSReachesTheDashboardAsGPS() {
        assertEquals(PositionSource.gps, decode(PositionEstimate.serializer(), "position-gnss-raw.json").dashboardSource)
        assertEquals(PositionSource.none, decode(PositionEstimate.serializer(), "position-ble-ambiguous.json").dashboardSource)
        val provenance = Provenance(producerId = "phone-a", algorithm = "typed@1", gnssDependent = false)
        val typed = PositionEstimate(subjectId = "phone-a", timestamp = 1_793_001_600.0, frameId = "hervanta-v1",
            kind = PositionEstimate.Kind.declared, method = PositionEstimate.Method.manual, position = Position(x = 1.0, y = 0.0, z = 2.0),
            uncertainty = PositionUncertainty(r95 = 2.0), source = EvidenceSource.manual,
            freshness = Freshness(maxAge = 30.0), provenance = provenance)
        assertNoThrow { typed.validate() }
        assertEquals(PositionSource.manual, typed.dashboardSource)
        // Wire v4 has a uwb source; a measured UWB fix is not a typed spot.
        val ranged = PositionEstimate(subjectId = "phone-a", timestamp = 1_793_001_600.0, frameId = "hervanta-v1",
            kind = PositionEstimate.Kind.measured, method = PositionEstimate.Method.uwb, position = Position(x = 1.0, y = 0.0, z = 2.0),
            uncertainty = PositionUncertainty(r95 = 0.5), source = EvidenceSource.uwb,
            freshness = Freshness(maxAge = 30.0), provenance = provenance)
        assertNoThrow { ranged.validate() }
        assertEquals(PositionSource.uwb, ranged.dashboardSource)
    }

    @Test
    fun testFrameIdsFollowTheDashboardPattern() {
        assertTrue(GhostCoreContract.isValidFrameId("hervanta-v1"))
        assertTrue(GhostCoreContract.isValidFrameId("demo.room_2"))
        assertFalse(GhostCoreContract.isValidFrameId(""))
        assertFalse(GhostCoreContract.isValidFrameId("hervanta v1"))
        assertFalse(GhostCoreContract.isValidFrameId("hervantä"))
        assertFalse(GhostCoreContract.isValidFrameId("a".repeat(65)))
    }
}
