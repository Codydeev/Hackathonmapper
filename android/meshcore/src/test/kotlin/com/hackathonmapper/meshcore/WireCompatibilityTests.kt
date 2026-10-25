package com.hackathonmapper.meshcore

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Pins the wire format to what the Swift app produces and accepts (wire format version 5), so
 * iPhones and Android phones share one mesh. The JSON inputs are written the way Swift's
 * `JSONEncoder` emits them: integral doubles without a fraction (`1`, not `1.0`), `/` escaped as
 * `\/`, nil optionals omitted, keys in no particular order, `Data` as padded base64.
 */
class WireCompatibilityTests {
    private val epoch = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    private fun bytes(vararg values: Int): ByteArray = ByteArray(values.size) { values[it].toByte() }
    private fun utf8(text: String): ByteArray = text.encodeToByteArray()
    private fun json(data: ByteArray): JsonObject = MeshJson.parseToJsonElement(data.decodeToString()).jsonObject

    // MARK: Frame header

    @Test
    fun frameHeaderIsTypeThenBigEndianUInt32Length() {
        assertArrayEquals(bytes(2, 0, 0, 0, 2, 0x6F, 0x6B), Framing.encode(utf8("ok"), FrameType.position))
        assertArrayEquals(bytes(1, 0, 0, 1, 0x2C), Framing.encode(ByteArray(300), FrameType.hello)!!.copyOfRange(0, 5))
        assertArrayEquals(bytes(3, 0, 0, 0, 1, 0xAB), Framing.encode(bytes(0xAB), FrameType.rangingToken))
        assertArrayEquals(bytes(4, 0, 0, 0x10, 0), Framing.encode(ByteArray(4_096), FrameType.rangingFix)!!.copyOfRange(0, 5))
        assertArrayEquals(bytes(5, 0, 0, 0, 2, 0x7B, 0x7D), Framing.encode(utf8("{}"), FrameType.relayMessage))
        assertArrayEquals(bytes(6, 0, 0, 0x0C, 0), Framing.encode(ByteArray(3_072), FrameType.relaySummary)!!.copyOfRange(0, 5))
        assertArrayEquals(bytes(7, 0, 0, 0, 1, 0x20), Framing.encode(bytes(0x20), FrameType.record))
        assertEquals(5 + 4_096, Framing.encode(ByteArray(4_096), FrameType.position)!!.size)
        assertEquals(5, Framing.headerLength)
        assertEquals(4_096, Framing.maxPayload)
        // website/scripts/meshproto-check.ts: the dashboard's own encoder.
        assertArrayEquals(bytes(2, 0, 0, 0, 3, 97, 98, 99), Framing.encode(utf8("abc"), FrameType.position))
    }

    @Test
    fun frameTypeRawValuesMatchSwift() {
        assertEquals(listOf(1, 2, 3, 4, 5, 6, 7), FrameType.entries.map { it.rawValue })
        assertEquals(FrameType.hello, FrameType.fromRawValue(1))
        assertEquals(FrameType.rangingFix, FrameType.fromRawValue(4))
        assertEquals(FrameType.relayMessage, FrameType.fromRawValue(5))
        assertEquals(FrameType.relaySummary, FrameType.fromRawValue(6))
        assertEquals(FrameType.record, FrameType.fromRawValue(7))
        assertNull(FrameType.fromRawValue(0))
        assertNull(FrameType.fromRawValue(8))
    }

    @Test
    fun relayFramesAreTypedNotSkipped() {
        // Wire v5 phones parse frames 5-7; the dashboard's node (meshproto.ts) skips them like a v3 phone.
        val envelope = Framing.encode(utf8("{\"e\":1}"), FrameType.relayMessage)!!
        val summary = Framing.encode(utf8("{\"s\":1}"), FrameType.relaySummary)!!
        val record = Framing.encode(utf8("relay record"), FrameType.record)!!
        val known = Framing.encode(utf8("kept"), FrameType.position)!!
        val frames = FrameAssembler().append(envelope + summary + record + known)
        assertEquals(listOf(FrameType.relayMessage, FrameType.relaySummary, FrameType.record, FrameType.position), frames.map { it.type })
        assertEquals("relay record", frames[2].payload.decodeToString())
    }

    @Test
    fun swiftFramedStreamReassemblesAtEveryChunkSize() {
        // A Hello and a position frame exactly as an iPhone sends them.
        val hello = utf8("""{"protocolVersion":5,"frameId":"hervanta-v1","deviceId":"phone-a","label":"Lab \/ 1"}""")
        val position = utf8(swiftPacketJson)
        val stream = bytes(1, 0, 0, 0, hello.size) + hello +
            bytes(2, 0, 0, (position.size shr 8) and 255, position.size and 255) + position
        for (size in 1..stream.size) {
            val assembler = FrameAssembler()
            val frames = mutableListOf<Frame>()
            for (start in 0 until stream.size step size) {
                frames += assembler.append(stream.copyOfRange(start, minOf(start + size, stream.size)), now = 0.0)
            }
            assertEquals("chunk size $size", listOf(Frame(FrameType.hello, hello), Frame(FrameType.position, position)), frames)
            assertFalse(assembler.hasPartialFrame)
        }
        val assembler = FrameAssembler()
        val frames = assembler.append(stream)
        assertEquals("phone-a", Hello.decode(frames[0].payload).deviceId)
        assertEquals(42L, MeshPacket.decode(frames[1].payload).update.sequence)
    }

    @Test
    fun partialHeaderWaitsForMoreBytes() {
        val assembler = FrameAssembler()
        assertEquals(emptyList<Frame>(), assembler.append(bytes(2, 0, 0, 0), now = 0.0))
        assertTrue(assembler.hasPartialFrame)
        assertEquals(listOf(Frame(FrameType.position, utf8("ok"))), assembler.append(bytes(2) + utf8("ok") + bytes(1, 0), now = 1.0))
        // The trailing two bytes start the next frame.
        assertTrue(assembler.hasPartialFrame)
    }

    @Test
    fun unknownTypesAreSkippedIncludingHighTypeBytes() {
        val known = Framing.encode(utf8("ok"), FrameType.position)!!
        for (type in listOf(8, 9, 0x7F, 0x80, 0xFF)) {
            val assembler = FrameAssembler()
            val frames = assembler.append(bytes(type, 0, 0, 0, 3) + utf8("new") + known)
            assertEquals("type $type", listOf(Frame(FrameType.position, utf8("ok"))), frames)
            assertFalse(assembler.hasPartialFrame)
        }
        // A skipped frame may also arrive in pieces.
        val assembler = FrameAssembler()
        assertEquals(emptyList<Frame>(), assembler.append(bytes(0xFF, 0, 0, 0, 3) + utf8("ne")))
        assertEquals(listOf(Frame(FrameType.position, utf8("ok"))), assembler.append(utf8("w") + known))
    }

    @Test
    fun typeZeroAndBadLengthsAreRejected() {
        val rejected = listOf(
            bytes(0, 0, 0, 0, 2) + utf8("ok"),      // type 0, even with a valid length
            bytes(2, 0, 0, 0, 0),                   // empty payload
            bytes(2, 0, 0, 0x10, 0x01),             // 4,097 bytes
            bytes(2, 0x80, 0, 0, 0),                // 2^31 (must not read as negative)
            bytes(2, 0xFF, 0xFF, 0xFF, 0xFF),       // UInt32.max
            bytes(0xFF, 0, 0, 0x10, 0x01),          // unknown type does not excuse the length limit
        )
        for (data in rejected) {
            val assembler = FrameAssembler()
            try {
                assembler.append(data)
                fail("accepted ${data.joinToString()}")
            } catch (e: MeshCoreError) {
                assertEquals(MeshCoreError.invalidFrame, e)
            }
            assertFalse(assembler.hasPartialFrame)
        }
    }

    @Test
    fun maximumPayloadAndBufferLimit() {
        val full = ByteArray(4_096) { 7 }
        val big = Framing.encode(full, FrameType.position)!!
        assertEquals(listOf(Frame(FrameType.position, full)), FrameAssembler().append(big))
        // The 8 KiB buffer limit applies to the bytes held after appending a chunk, before parsing:
        // exactly 8,192 bytes are accepted, one more is rejected even if every frame is complete.
        val second = Framing.encode(ByteArray(8_192 - big.size - 5), FrameType.hello)!!
        assertEquals(8_192, big.size + second.size)
        assertEquals(2, FrameAssembler().append(big + second).size)
        val tooMuch = FrameAssembler()
        try {
            tooMuch.append(big + second + bytes(2))
            fail("accepted more than maxBuffered")
        } catch (e: MeshCoreError) {
            assertEquals(MeshCoreError.invalidFrame, e)
        }
        assertFalse(tooMuch.hasPartialFrame)
        assertEquals(8_192, FrameAssembler.maxBuffered)
        assertEquals(10.0, FrameAssembler.timeout, 0.0)
    }

    @Test
    fun outboxChunksAreSequentialSlicesOfTheFrame() {
        val framed = Framing.encode(utf8(swiftPacketJson), FrameType.position)!!
        val outbox = LinkOutbox()
        outbox.enqueue(framed, key = "position:phone-a")
        val received = FrameAssembler()
        val frames = mutableListOf<Frame>()
        while (true) {
            val chunk = outbox.nextChunk(maxLength = 182) ?: break
            assertTrue(chunk.size <= 182)
            frames += received.append(chunk)
            outbox.chunkSent()
        }
        assertEquals(listOf(Frame(FrameType.position, utf8(swiftPacketJson))), frames)
        // maxLength below 1 still makes progress (Swift: max(1, maxLength)).
        outbox.enqueue(bytes(1, 2), key = "a")
        assertArrayEquals(bytes(1), outbox.nextChunk(maxLength = 0))
    }

    // MARK: JSON from Swift

    /** A relayed packet as Swift's JSONEncoder writes it. */
    private val swiftPacketJson =
        """{"schemaVersion":5,"frameId":"hervanta-v1","hopsRemaining":4,"path":["phone-b"],""" +
            """"update":{"id":"phone-a","label":"Lab \/ 📡","epochId":"$epoch","sequence":42,"role":"mobile",""" +
            """"position":{"x":1,"y":0,"z":-2.5},"positionMode":"floor","accuracyMeters":3,""" +
            """"neighbors":[{"id":"phone-b","rssi":-61,"ageMs":250,"uwbDistanceM":3.14},{"id":"phone-c"}],"positionSource":"gps"}}"""

    @Test
    fun decodesSwiftPacket() {
        val packet = MeshPacket.decode(utf8(swiftPacketJson))
        assertEquals(5, packet.schemaVersion)
        assertEquals("hervanta-v1", packet.frameId)
        assertEquals(4, packet.hopsRemaining)
        assertEquals(listOf("phone-b"), packet.path)
        val expected = DeviceUpdate(
            id = "phone-a", label = "Lab / 📡", epochId = epoch, sequence = 42, role = "mobile",
            position = Position(x = 1.0, y = 0.0, z = -2.5), positionMode = "floor", accuracyMeters = 3.0,
            neighbors = listOf(NeighborObservation(id = "phone-b", rssi = -61, ageMs = 250, uwbDistanceM = 3.14), NeighborObservation(id = "phone-c")),
            positionSource = PositionSource.gps,
        )
        assertEquals(expected, packet.update)
    }

    @Test
    fun decodesKeysInAnyOrderEscapesAndUnknownKeys() {
        val reordered = """ { "update" : { "positionMode":"3d", "position":{"z":3,"y":2,"x":1,"w":9},
            "role":"anchor","sequence":0,"epochId":"${epoch.lowercase()}","id":"phone-a",
            "label":"📡 é","futureField":{"nested":[1,2,{"a":null}]},"accuracyMeters":1e2 },
            "path":[], "hopsRemaining":0, "frameId":"frame", "schemaVersion":5, "extra":true } """
        val packet = MeshPacket.decode(utf8(reordered))
        assertEquals("📡 é", packet.update.label)
        assertEquals(epoch.lowercase(), packet.update.epochId)
        assertEquals(Position(x = 1.0, y = 2.0, z = 3.0), packet.update.position)
        assertEquals(100.0, packet.update.accuracyMeters!!, 0.0)
        assertNull(packet.update.neighbors)
        assertNull(packet.update.positionSource)
    }

    @Test
    fun explicitNullsDecodeAsAbsentOptionals() {
        val text = """{"schemaVersion":5,"frameId":"f","hopsRemaining":1,"path":[],"update":{"id":"d","label":null,""" +
            """"epochId":"$epoch","sequence":1,"role":"mobile","position":{"x":0,"y":0,"z":0},"positionMode":"3d",""" +
            """"accuracyMeters":null,"neighbors":null,"positionSource":null}}"""
        val update = MeshPacket.decode(utf8(text)).update
        assertNull(update.label)
        assertNull(update.accuracyMeters)
        assertNull(update.neighbors)
        assertNull(update.positionSource)
    }

    @Test
    fun wireV5NeighborUWBDistanceAndSources() {
        val base = json(utf8(swiftPacketJson))
        val update = base["update"]!!.jsonObject
        fun withNeighbors(neighbors: String, source: String = "gps"): ByteArray {
            val replaced = JsonObject(
                update + ("neighbors" to MeshJson.parseToJsonElement(neighbors)) + ("positionSource" to JsonPrimitive(source)),
            )
            return utf8(JsonObject(base + ("update" to replaced)).toString())
        }
        // Swift's synthesized decoder keeps the value as sent; only `init` rounds.
        val unrounded = MeshPacket.decode(withNeighbors("""[{"id":"phone-b","uwbDistanceM":3.14159}]"""))
        assertEquals(3.14159, unrounded.update.neighbors!![0].uwbDistanceM!!, 0.0)
        assertEquals(3.14159, MeshPacket.decode(unrounded.encoded()).update.neighbors!![0].uwbDistanceM!!, 0.0)
        assertEquals(200.0, MeshPacket.decode(withNeighbors("""[{"id":"phone-b","uwbDistanceM":2e2}]""")).update.neighbors!![0].uwbDistanceM!!, 0.0)
        assertNull(MeshPacket.decode(withNeighbors("""[{"id":"phone-b","uwbDistanceM":null}]""")).update.neighbors!![0].uwbDistanceM)
        assertRejected("uwbDistanceM above 200 m") { MeshPacket.decode(withNeighbors("""[{"id":"phone-b","uwbDistanceM":200.001}]""")) }
        assertRejected("negative uwbDistanceM") { MeshPacket.decode(withNeighbors("""[{"id":"phone-b","uwbDistanceM":-1}]""")) }
        assertRejected("uwbDistanceM as a string") { MeshPacket.decode(withNeighbors("""[{"id":"phone-b","uwbDistanceM":"3"}]""")) }
        assertRejected("neighbor without id") { MeshPacket.decode(withNeighbors("""[{"uwbDistanceM":3}]""")) }
        // Version 4 sources.
        assertEquals(PositionSource.uwb, MeshPacket.decode(withNeighbors("[]", source = "uwb")).update.positionSource)
        assertEquals(PositionSource.fused, MeshPacket.decode(withNeighbors("[]", source = "fused")).update.positionSource)
        assertRejected("unknown source") { MeshPacket.decode(withNeighbors("[]", source = "magic")) }
        // Older wire versions are refused, so they never strip `uwbDistanceM` on a relay.
        for (version in listOf(3, 4, 6)) {
            assertRejected("schemaVersion $version") {
                MeshPacket.decode(utf8(JsonObject(base + ("schemaVersion" to JsonPrimitive(version))).toString()))
            }
        }
    }

    @Test
    fun protocolVersionMatchesTheAppAndTheDashboardNode() {
        // Same check as website/scripts/meshproto-check.ts: the version moves on every side together.
        val root = java.io.File(System.getProperty("repo.root"))
        val models = java.io.File(root, "ios/MeshCore/Sources/MeshCore/Models.swift").readText()
        val swift = Regex("""enum MeshProtocol \{[^}]*?static let version = (\d+)""").find(models)
        assertNotNull("MeshProtocol.version not found in Models.swift", swift)
        assertEquals(MeshProtocol.version, swift!!.groupValues[1].toInt())
        val meshproto = java.io.File(root, "website/src/meshproto.ts").readText()
        val dashboard = Regex("""export const MESH_PROTOCOL_VERSION = (\d+);""").find(meshproto)
        assertNotNull("MESH_PROTOCOL_VERSION not found in meshproto.ts", dashboard)
        assertEquals(MeshProtocol.version, dashboard!!.groupValues[1].toInt())
        val contract = java.io.File(root, "website/shared/contract.ts").readText()
        val maxUWB = Regex("""MAX_UWB_DISTANCE_M\s*=\s*([\d_.]+)""").find(contract)
        assertNotNull("MAX_UWB_DISTANCE_M not found in contract.ts", maxUWB)
        assertEquals(DashboardContract.maxUWBDistanceMeters, maxUWB!!.groupValues[1].replace("_", "").toDouble(), 0.0)
    }

    // MARK: Dashboard mesh node (website/src/meshproto.ts, vectors from scripts/meshproto-check.ts)

    /** `JSON.stringify` of meshproto-check's `packet(sequence, extra)`. */
    private fun dashboardPacket(
        sequence: Int,
        path: String = "[]",
        hopsRemaining: Int = 4,
        frameId: String = "hervanta-v1",
        epochId: String = epoch,
    ): MeshPacket = MeshPacket.decode(
        utf8(
            """{"schemaVersion":5,"frameId":"$frameId","hopsRemaining":$hopsRemaining,"path":$path,""" +
                """"update":{"id":"phone-a","epochId":"$epochId","sequence":$sequence,"role":"mobile",""" +
                """"position":{"x":1,"y":0,"z":2},"positionMode":"floor"}}""",
        ),
    )

    @Test
    fun dashboardHelloAndPacketsDecode() {
        // encodeHello: JSON.stringify({ protocolVersion, ...hello }).
        val framed = bytes(1, 0, 0, 0, 0) + utf8("""{"protocolVersion":5,"frameId":"hervanta-v1","deviceId":"dashboard-1234","label":"Dashboard"}""")
        framed[4] = (framed.size - 5).toByte()
        val frames = FrameAssembler().append(framed)
        val hello = Hello.decode(frames.single().payload)
        assertEquals(MeshProtocol.version, hello.protocolVersion)
        assertEquals("dashboard-1234", hello.deviceId)
        assertEquals("Dashboard", hello.label)
        assertEquals(1L, dashboardPacket(1).update.sequence)
        assertRejected("own id on the path") { dashboardPacket(1, path = "[\"phone-a\"]") }
    }

    @Test
    fun dashboardRelayVectorsMatchMeshStore() {
        // PacketStore in meshproto.ts mirrors MeshStore.ingest; same inputs, same outcomes.
        val store = MeshStore(frameId = "hervanta-v1", selfId = "dashboard-1")
        val relay = store.ingest(dashboardPacket(5, path = "[\"phone-b\"]"), now = 0.0)
        assertEquals(3, relay?.hopsRemaining)
        assertEquals(listOf("phone-b", "dashboard-1"), relay?.path)
        assertNull("duplicate sequence", store.ingest(dashboardPacket(5), now = 0.0))
        assertNull("older sequence", store.ingest(dashboardPacket(4), now = 0.0))
        assertNull("accepted but not relayed", store.ingest(dashboardPacket(6, hopsRemaining = 0), now = 0.0))
        assertEquals(6L, store.latest["phone-a"]?.sequence)
        assertNull("already passed through us", store.ingest(dashboardPacket(7, path = "[\"dashboard-1\"]"), now = 0.0))
        // The dashboard drops another frame silently; MeshStore reports it.
        assertRejected("other frame") { store.ingest(dashboardPacket(8, frameId = "other"), now = 0.0) }

        val epochs = MeshStore(frameId = "hervanta-v1", selfId = "dashboard-1")
        epochs.ingest(dashboardPacket(10), now = 0.0)
        assertNotNull(epochs.ingest(dashboardPacket(1, epochId = "11111111-2222-3333-4444-555555555555"), now = 0.0))
        assertNull("a retired epoch cannot come back", epochs.ingest(dashboardPacket(11), now = 0.0))
    }

    // MARK: Relay frames (5, 6) from Swift

    private val messageId = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
    private val ackId = "0E984725-C51C-4BF4-9960-E1C80E27ABA0"

    /** A relayed envelope as Swift's JSONEncoder writes it (declaration order, `/` escaped). */
    private val swiftEnvelopeJson =
        """{"schemaVersion":1,"messageId":"$messageId","originId":"phone-a","destinationId":"phone-c",""" +
            """"kind":"text","body":"need water \/ 2","createdAt":1800000000000,"ageMs":45000,"ttlMs":600000,""" +
            """"hopsRemaining":5,"path":["phone-b"]}"""

    @Test
    fun decodesSwiftRelayEnvelope() {
        val envelope = RelayEnvelope.decode(utf8(swiftEnvelopeJson))
        val expected = RelayEnvelope(
            messageId = messageId, originId = "phone-a", destinationId = "phone-c", kind = "text", body = "need water / 2",
            createdAt = 1_800_000_000_000.0, ageMs = 45_000, ttlMs = 600_000, hopsRemaining = 5, path = listOf("phone-b"),
        )
        assertEquals(expected, envelope)
        assertNull(envelope.acknowledges)
        assertFalse(envelope.isReceipt)
        assertEquals(1_800_000_000.0, envelope.timestamp!!, 0.0)
        assertEquals(45.0, envelope.freshness.ageAtHandoff, 0.0)
        assertEquals(600.0, envelope.freshness.maxAge, 0.0)

        // Swift's UUID decoding accepts lowercase and re-encodes uppercase.
        val lower = RelayEnvelope.decode(utf8(swiftEnvelopeJson.replace(messageId, messageId.lowercase())))
        assertEquals(messageId, lower.messageId)
        val receipt = RelayEnvelope.decode(
            utf8(
                """{"schemaVersion":1,"messageId":"$messageId","originId":"phone-c","destinationId":"phone-a",""" +
                    """"kind":"receipt","body":"{\"path\":[\"phone-b\"],\"ageMs\":45000}","ageMs":0,"ttlMs":600000,""" +
                    """"hopsRemaining":6,"path":[],"acknowledges":"${ackId.lowercase()}"}""",
            ),
        )
        assertEquals(ackId, receipt.acknowledges)
        assertTrue(receipt.isReceipt)
        assertEquals(RelayReceiptInfo(path = listOf("phone-b"), ageMs = 45_000), RelayReceiptInfo.decode(receipt.body))

        for (bad in listOf("not-a-uuid", "6F9619FF8B86D011B42D00C04FC964FF", "{$messageId}")) {
            assertRejected("messageId $bad") { RelayEnvelope.decode(utf8(swiftEnvelopeJson.replace(messageId, bad))) }
        }
    }

    @Test
    fun relayEnvelopeRequiredKeysAndTypes() {
        val base = json(utf8(swiftEnvelopeJson))
        for (key in listOf("schemaVersion", "messageId", "originId", "kind", "body", "ageMs", "ttlMs", "hopsRemaining", "path")) {
            assertRejected("envelope without $key") { RelayEnvelope.decode(utf8(JsonObject(base - key).toString())) }
        }
        for (key in listOf("destinationId", "createdAt")) {
            RelayEnvelope.decode(utf8(JsonObject(base - key).toString()))
        }
        assertRejected("schemaVersion 2") { RelayEnvelope.decode(utf8(JsonObject(base + ("schemaVersion" to JsonPrimitive(2))).toString())) }
        assertRejected("fractional ageMs") { RelayEnvelope.decode(utf8(JsonObject(base + ("ageMs" to JsonPrimitive(1.5))).toString())) }
        try {
            RelayEnvelope.decode(ByteArray(RelayEnvelope.maxEncodedSize + 1) { 32 })
            fail("accepted an oversized envelope")
        } catch (e: RelayError) {
            assertEquals(RelayError.tooLarge, e)
        }
    }

    @Test
    fun kotlinRelayJsonHasSwiftKeys() {
        val envelope = RelayEnvelope(originId = "phone-a", kind = "text", body = "x", ttlMs = 1_000, hopsRemaining = 2)
        val obj = json(envelope.encoded())
        assertEquals(setOf("schemaVersion", "messageId", "originId", "kind", "body", "ageMs", "ttlMs", "hopsRemaining", "path"), obj.keys)
        assertIntegerLiteral("1", obj["schemaVersion"])
        assertIntegerLiteral("0", obj["ageMs"])
        assertEquals(envelope.messageId.uppercase(), envelope.messageId)
        assertNotNull(canonicalUUID(envelope.messageId))
        val full = RelayEnvelope.decode(utf8(swiftEnvelopeJson))
        assertEquals(normalizeNumbers(json(utf8(swiftEnvelopeJson))).toString(), normalizeNumbers(json(full.encoded())).toString())

        val summary = json(RelaySummary(have = listOf(messageId)).encoded())
        assertEquals(setOf("schemaVersion", "have"), summary.keys)
        assertEquals(RelaySummary(have = listOf(messageId)), RelaySummary.decode(utf8("""{"have":["${messageId.lowercase()}"],"schemaVersion":1}""")))
        assertRejected("summary without schemaVersion") { RelaySummary.decode(utf8("""{"have":[]}""")) }
        assertRejected("summary with a bad id") { RelaySummary.decode(utf8("""{"have":["x"],"schemaVersion":1}""")) }
        assertEquals(setOf("path", "ageMs"), json(utf8(RelayReceiptInfo(path = emptyList(), ageMs = 0).encodedBody())).keys)
    }

    @Test
    fun requiredKeysAreRequiredLikeSwiftSynthesizedDecoding() {
        val base = json(utf8(swiftPacketJson))
        for (key in listOf("schemaVersion", "frameId", "hopsRemaining", "path", "update")) {
            assertRejected("packet without $key") { MeshPacket.decode(utf8(JsonObject(base - key).toString())) }
        }
        val update = base["update"]!!.jsonObject
        for (key in listOf("id", "epochId", "sequence", "role", "position", "positionMode")) {
            val packet = JsonObject(base + ("update" to JsonObject(update - key)))
            assertRejected("update without $key") { MeshPacket.decode(utf8(packet.toString())) }
        }
        // Wrong JSON types and nulls in required fields are errors, as in Swift.
        for ((key, value) in listOf<Pair<String, JsonElement>>(
            "sequence" to JsonPrimitive("42x"), "sequence" to JsonPrimitive(1.5), "id" to JsonPrimitive(5),
            "role" to kotlinx.serialization.json.JsonNull, "neighbors" to JsonPrimitive("peer"),
        )) {
            val packet = JsonObject(base + ("update" to JsonObject(update + (key to value))))
            assertRejected("update.$key = $value") { MeshPacket.decode(utf8(packet.toString())) }
        }
        assertRejected("invalid UTF-8") { MeshPacket.decode(utf8(swiftPacketJson).also { it[it.size - 20] = 0xFF.toByte() }) }
        assertRejected("trailing garbage") { MeshPacket.decode(utf8("$swiftPacketJson x")) }
        // Trailing whitespace is fine (the size-limit test pads with spaces).
        MeshPacket.decode(utf8("$swiftPacketJson \n"))
    }

    @Test
    fun largeSwiftIntegersDecode() {
        val update = json(utf8(swiftPacketJson))["update"]!!.jsonObject
        val base = json(utf8(swiftPacketJson))
        val max = JsonObject(base + ("update" to JsonObject(update + ("sequence" to JsonPrimitive(9_007_199_254_740_991L)))))
        assertEquals(9_007_199_254_740_991L, MeshPacket.decode(utf8(max.toString())).update.sequence)
        val over = JsonObject(base + ("update" to JsonObject(update + ("sequence" to JsonPrimitive(9_007_199_254_740_992L)))))
        assertRejected("sequence above 2^53 - 1") { MeshPacket.decode(utf8(over.toString())) }
    }

    @Test
    fun epochMustBeACanonicalUUIDInEitherCase() {
        fun withEpoch(value: String) = DeviceUpdate(
            id = "d", epochId = value, sequence = 0, role = "mobile",
            position = Position(x = 0.0, y = 0.0, z = 0.0), positionMode = "3d",
        )
        withEpoch(epoch).validate()
        withEpoch(epoch.lowercase()).validate()
        withEpoch("aAaAaAaA-bbbb-CCCC-dDdD-eeeeEEEEeeee").validate()
        for (invalid in listOf(
            "1-1-1-1-1",                                   // java.util.UUID.fromString accepts this
            "AAAAAAAABBBBCCCCDDDDEEEEEEEEEEEE",
            "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}",
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE",
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEEE",
            "GAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            " $epoch",
        )) {
            assertRejected(invalid) { withEpoch(invalid).validate() }
        }
    }

    @Test
    fun idsMatchSwiftWhitespaceTrimming() {
        // CharacterSet.whitespacesAndNewlines: Z* categories, U+0009...U+000D, U+0085.
        for (id in listOf(" a", "a ", "\ta", "a\n", "a\r", "\u000Ba", "a\u000C", "\u0085a", " a", "a ", " a", "a ", "　a")) {
            assertFalse("'${id.map { it.code }}' should be invalid", DashboardContract.isValidId(id))
        }
        // Not whitespace to Swift (Java's isWhitespace says otherwise for U+001C...U+001F).
        for (id in listOf("a\u001F", "\u001Ca", "​a", "a b", "📡")) {
            assertTrue("'${id.map { it.code }}' should be valid", DashboardContract.isValidId(id))
        }
        assertTrue(DashboardContract.isValidId("x".repeat(64)))
        assertFalse(DashboardContract.isValidId("📡".repeat(33)))   // 66 UTF-16 units
        assertTrue(DashboardContract.isValidId("📡".repeat(32)))
    }

    @Test
    fun labelTruncationKeepsWholeCharacters() {
        // "e" + combining acute accent is one Character (2 UTF-16 units) in Swift.
        assertEquals("é".repeat(20), DashboardContract.truncatedLabel("é".repeat(25)))
        assertEquals("x".repeat(39), DashboardContract.truncatedLabel("x".repeat(39) + "é"))
    }

    @Test
    fun decodesSwiftHello() {
        val hello = Hello.decode(utf8("""{"protocolVersion":5,"frameId":"hervanta-v1","deviceId":"phone-a"}"""))
        assertEquals(Hello(frameId = "hervanta-v1", deviceId = "phone-a", label = null), hello)
        val labeled = Hello.decode(utf8("""{"label":"Lab \/ 📡","deviceId":"phone-a","frameId":"hervanta-v1","protocolVersion":5,"new":1}"""))
        assertEquals("Lab / 📡", labeled.label)
        // The version is checked by the caller, so another version still decodes.
        assertEquals(2, Hello.decode(utf8("""{"protocolVersion":2,"frameId":"f","deviceId":"d"}""")).protocolVersion)
        assertRejected("missing protocolVersion") { Hello.decode(utf8("""{"frameId":"f","deviceId":"d"}""")) }
        assertRejected("missing deviceId") { Hello.decode(utf8("""{"protocolVersion":5,"frameId":"f"}""")) }
        try {
            Hello.decode(ByteArray(513) { 32 })
            fail("accepted 513 bytes")
        } catch (e: MeshCoreError) {
            assertEquals(MeshCoreError.invalidHello, e)
        }
        try {
            Hello.decode(utf8("""{"protocolVersion":5,"frameId":"f","deviceId":" d"}"""))
            fail("accepted padded id")
        } catch (e: MeshCoreError) {
            assertEquals(MeshCoreError.invalidHello, e)
        }
    }

    @Test
    fun decodesSwiftRangingToken() {
        val token = RangingToken.decode(utf8("""{"token":"AQID","isAnchor":true}"""))
        assertArrayEquals(bytes(1, 2, 3), token.token)
        assertTrue(token.isAnchor)
        // JSONEncoder escapes "/" in base64 too.
        assertArrayEquals(bytes(0xFF, 0xFF, 0xFF), RangingToken.decode(utf8("""{"isAnchor":false,"token":"\/\/\/\/"}""")).token)
        assertArrayEquals(bytes(1, 2), RangingToken.decode(utf8("""{"token":"AQI=","isAnchor":false}""")).token)
        // Data(base64Encoded:) needs padding and rejects characters outside the alphabet.
        for (bad in listOf("AQI", "AQ I=", "AQI=\n", "A*I=", "")) {
            assertRejected("token '$bad'") { RangingToken.decode(utf8("""{"token":"$bad","isAnchor":false}""")) }
        }
        assertRejected("missing isAnchor") { RangingToken.decode(utf8("""{"token":"AQID"}""")) }
        try {
            RangingToken.decode(ByteArray(4_097) { 32 })
            fail("accepted 4,097 bytes")
        } catch (e: MeshCoreError) {
            assertEquals(MeshCoreError.invalidRanging, e)
        }
    }

    @Test
    fun decodesSwiftRangingFix() {
        val fix = RangingFix.decode(utf8(
            """{"anchorId":"anchor","targetId":"target","position":{"x":10,"y":1,"z":22},"accuracyMeters":0.82,"distanceMeters":2}""",
        ))
        assertEquals(
            RangingFix(anchorId = "anchor", targetId = "target", position = Position(x = 10.0, y = 1.0, z = 22.0), accuracyMeters = 0.82, distanceMeters = 2.0),
            fix,
        )
        try {
            RangingFix.decode(utf8("""{"anchorId":"a","targetId":"a","position":{"x":0,"y":0,"z":0},"accuracyMeters":1,"distanceMeters":1}"""))
            fail("accepted anchorId == targetId")
        } catch (e: MeshCoreError) {
            assertEquals(MeshCoreError.invalidRanging, e)
        }
        // Matches the accuracy Swift computes for a 2 m measurement: 2 sin 15° + 0.3, rounded to cm.
        assertEquals(0.82, AnchorGeometry.accuracy(distance = 2.0), 0.0)
    }

    // MARK: JSON from Kotlin

    @Test
    fun kotlinPacketJsonHasSwiftKeysAndOmitsNulls() {
        val minimal = MeshPacket(
            frameId = "frame", hopsRemaining = 4,
            update = DeviceUpdate(id = "d", epochId = epoch, sequence = 7, role = "mobile", position = Position(x = 1.0, y = 0.0, z = 2.0), positionMode = "floor"),
        )
        val obj = json(minimal.encoded())
        assertEquals(setOf("schemaVersion", "frameId", "hopsRemaining", "path", "update"), obj.keys)
        assertEquals(JsonArray(emptyList()), obj["path"])
        val update = obj["update"]!!.jsonObject
        assertEquals(setOf("id", "epochId", "sequence", "role", "position", "positionMode"), update.keys)
        assertFalse(minimal.encoded().decodeToString().contains("null"))
        // Integer fields are written as JSON integers (Swift's Int decoding rejects a fraction).
        assertIntegerLiteral("5", obj["schemaVersion"])
        assertIntegerLiteral("4", obj["hopsRemaining"])
        assertIntegerLiteral("7", update["sequence"])

        val full = MeshPacket.decode(utf8(swiftPacketJson))
        val fullObj = json(full.encoded())
        val fullUpdate = fullObj["update"]!!.jsonObject
        assertEquals(
            setOf("id", "label", "epochId", "sequence", "role", "position", "positionMode", "accuracyMeters", "neighbors", "positionSource"),
            fullUpdate.keys,
        )
        assertEquals("gps", fullUpdate["positionSource"]!!.jsonPrimitive.content)
        val neighbors = fullUpdate["neighbors"] as JsonArray
        assertEquals(setOf("id", "rssi", "ageMs", "uwbDistanceM"), neighbors[0].jsonObject.keys)
        assertEquals("3.14", neighbors[0].jsonObject["uwbDistanceM"]!!.jsonPrimitive.content)
        assertEquals(setOf("id"), neighbors[1].jsonObject.keys)
        assertIntegerLiteral("-61", neighbors[0].jsonObject["rssi"])
        assertIntegerLiteral("250", neighbors[0].jsonObject["ageMs"])
        // Same document as Swift's once numbers are compared numerically and keys sorted.
        assertEquals(normalizeNumbers(json(utf8(swiftPacketJson))).toString(), normalizeNumbers(fullObj).toString())
        assertEquals(full.update, MeshPacket.decode(full.encoded()).update)
    }

    @Test
    fun kotlinHelloRangingJsonHasSwiftKeys() {
        assertEquals(setOf("protocolVersion", "frameId", "deviceId"), json(Hello(frameId = "f", deviceId = "d", label = null).encoded()).keys)
        val labeled = json(Hello(frameId = "f", deviceId = "d", label = "L").encoded())
        assertEquals(setOf("protocolVersion", "frameId", "deviceId", "label"), labeled.keys)
        assertIntegerLiteral("5", labeled["protocolVersion"])

        val token = json(RangingToken(token = bytes(1, 2), isAnchor = true).encoded())
        assertEquals("AQI=", token["token"]!!.jsonPrimitive.content)
        assertEquals("true", token["isAnchor"]!!.jsonPrimitive.content)
        assertEquals(setOf("token", "isAnchor"), token.keys)

        val fix = json(RangingFix(anchorId = "a", targetId = "b", position = Position(x = 1.0, y = 2.0, z = 3.0), accuracyMeters = 0.5, distanceMeters = 4.0).encoded())
        assertEquals(setOf("anchorId", "targetId", "position", "accuracyMeters", "distanceMeters"), fix.keys)
        assertEquals(setOf("x", "y", "z"), fix["position"]!!.jsonObject.keys)
    }

    @Test
    fun positionSourceRawValues() {
        assertEquals(listOf("gps", "manual", "none", "uwb", "fused"), PositionSource.entries.map { it.rawValue })
        for (source in PositionSource.entries) {
            assertEquals("\"${source.rawValue}\"", MeshJson.encodeToString(PositionSource.serializer(), source))
            assertEquals(source, PositionSource.fromRawValue(source.rawValue))
        }
    }

    @Test
    fun contractConstantsMatchSwift() {
        assertEquals(5, MeshProtocol.version)
        assertEquals(8, MeshProtocol.maxPathLength)
        assertEquals(64, DashboardContract.maxIdLength)
        assertEquals(40, DashboardContract.maxLabelLength)
        assertEquals(10_000.0, DashboardContract.maxCoordinate, 0.0)
        assertEquals(1_000.0, DashboardContract.maxAccuracyMeters, 0.0)
        assertEquals(16, DashboardContract.maxNeighbors)
        assertEquals(-127..20, DashboardContract.rssiRange)
        assertEquals(86_400_000, DashboardContract.maxAgeMs)
        assertEquals(200.0, DashboardContract.maxUWBDistanceMeters, 0.0)
        assertEquals(1, RelayEnvelope.schemaVersion)
        assertEquals(1_024, RelayEnvelope.maxBodyBytes)
        assertEquals(900_000, RelayEnvelope.maxTTLMs)
        assertEquals(8, RelayEnvelope.maxHops)
        assertEquals(3_072, RelayEnvelope.maxEncodedSize)
        assertEquals("receipt", RelayEnvelope.receiptKind)
        assertEquals(64, RelaySummary.maxIds)
        assertEquals(512, Hello.maxEncodedSize)
        assertEquals(1_024, RangingToken.maxTokenSize)
        assertEquals(3.0, RangingFix.maxAge, 0.0)
        assertEquals("hervanta-v1", GeoFrame.defaultFrameId)
        assertEquals(mapOf("hervanta-v1" to GeoFrame.Origin(61.4499, 23.8560, 0.0)), GeoFrame.origins)
        assertEquals("north (+z)", GeoFrame.forwardName("hervanta-v1"))
        assertEquals("forward (+z)", GeoFrame.forwardName("demo-room-v1"))
        assertEquals(GeoFrame.AxisNames("east", "north"), GeoFrame.axisNames("hervanta-v1"))
        assertEquals(GeoFrame.AxisNames("right", "forward"), GeoFrame.axisNames("demo-room-v1"))
    }

    // MARK: Helpers

    private fun assertIntegerLiteral(expected: String, element: JsonElement?) {
        val primitive = element as? JsonPrimitive ?: return fail("not a primitive: $element")
        assertFalse(primitive.isString)
        assertEquals(expected, primitive.content)
    }

    /** Rewrites every number as its Double value so `1` and `1.0` compare equal. */
    private fun normalizeNumbers(element: JsonElement): JsonElement = when (element) {
        is JsonObject -> JsonObject(element.mapValues { normalizeNumbers(it.value) }.toSortedMap())
        is JsonArray -> JsonArray(element.map { normalizeNumbers(it) })
        is JsonPrimitive -> if (!element.isString && element.content.toDoubleOrNull() != null) JsonPrimitive(element.content.toDouble()) else element
    }

    private fun assertRejected(what: String, body: () -> Unit) {
        try {
            body()
        } catch (e: Exception) {
            return
        }
        fail("accepted: $what")
    }
}
