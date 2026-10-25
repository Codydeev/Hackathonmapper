package com.hackathonmapper.meshcore

import java.util.UUID
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.sin
import kotlin.math.sqrt
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Port of ios/MeshCore/Tests/MeshCoreTests/MeshCoreTests.swift. */
class MeshCoreTests {
    private val epoch = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    private val nextEpoch = "11111111-2222-3333-4444-555555555555"

    private fun update(
        id: String = "device",
        label: String? = null,
        epochId: String? = null,
        sequence: Long = 0,
        role: String = "mobile",
        position: Position = Position(x = 1.0, y = 2.0, z = 3.0),
        positionMode: String = "3d",
        accuracyMeters: Double? = null,
        neighbors: List<NeighborObservation>? = null,
    ): DeviceUpdate = DeviceUpdate(
        id = id, label = label, epochId = epochId ?: epoch, sequence = sequence,
        role = role, position = position, positionMode = positionMode,
        accuracyMeters = accuracyMeters, neighbors = neighbors,
    )

    private fun packet(update: DeviceUpdate, hops: Int = 8, frame: String = "frame"): MeshPacket =
        MeshPacket(frameId = frame, hopsRemaining = hops, update = update)

    private fun bytes(text: String): ByteArray = text.encodeToByteArray()

    @Test
    fun testPositionAndOptionalDefaults() {
        val position = Position(x = 1.0, y = 2.0, z = 3.0)
        assertEquals(position, MeshJson.decodeFromString(Position.serializer(), MeshJson.encodeToString(Position.serializer(), position)))
        val value = update()
        assertNull(value.label)
        assertNull(value.accuracyMeters)
        value.validate()
    }

    @Test
    fun testAllPublicRolesAndModes() {
        for (role in listOf("anchor", "mobile", "gateway")) {
            update(role = role).validate()
            update(
                role = role, position = Position(x = 1.0, y = 0.0, z = 3.0),
                positionMode = "floor", accuracyMeters = 0.0,
            ).validate()
        }
    }

    @Test
    fun testUpdateValidation() {
        val invalid = listOf(
            update(id = ""),
            update(id = "x".repeat(129)),
            update(label = "x".repeat(129)),
            update(epochId = "not-a-uuid"),
            update(sequence = -1),
            update(sequence = 9_007_199_254_740_992),
            update(role = "unknown"),
            update(positionMode = "2d"),
            update(positionMode = "floor"),
            update(accuracyMeters = -0.1),
            update(accuracyMeters = Double.POSITIVE_INFINITY),
            update(accuracyMeters = Double.NaN),
        )
        for (value in invalid) assertThrows { value.validate() }
        for (coordinate in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            for (position in listOf(
                Position(x = coordinate, y = 0.0, z = 0.0),
                Position(x = 0.0, y = coordinate, z = 0.0),
                Position(x = 0.0, y = 0.0, z = coordinate),
            )) {
                assertThrows { update(position = position).validate() }
            }
        }
        update(
            id = "x".repeat(64),
            label = "x".repeat(40),
            sequence = 9_007_199_254_740_991,
        ).validate()
        assertThrows { update(id = "é".repeat(65)).validate() }
    }

    @Test
    fun testValidationMatchesDashboardContract() {
        // Each of these would make the dashboard reject the gateway's whole batch.
        val invalid = listOf(
            update(id = "x".repeat(65)),
            update(id = " padded"),
            update(label = "x".repeat(41)),
            update(label = "📡".repeat(21)),
            update(position = Position(x = 10_000.1, y = 0.0, z = 0.0)),
            update(position = Position(x = 0.0, y = 0.0, z = -10_000.1)),
            update(accuracyMeters = 1_000.1),
        )
        for (value in invalid) assertThrows { value.validate() }
        update(
            label = "📡".repeat(20),
            position = Position(x = 10_000.0, y = -10_000.0, z = 10_000.0),
            accuracyMeters = 1_000.0,
        ).validate()
    }

    @Test
    fun testNeighborValidation() {
        val valid = NeighborObservation(id = "peer", rssi = -60, ageMs = 250)
        update(neighbors = emptyList()).validate()
        update(neighbors = listOf(valid, NeighborObservation(id = "other"))).validate()
        update(neighbors = (0 until 16).map { NeighborObservation(id = "peer-$it") }).validate()

        val invalid: List<List<NeighborObservation>> = listOf(
            (0 until 17).map { NeighborObservation(id = "peer-$it") },
            listOf(NeighborObservation(id = "")),
            listOf(NeighborObservation(id = "x".repeat(65))),
            listOf(NeighborObservation(id = "device")),
            listOf(valid, valid),
            listOf(NeighborObservation(id = "peer", rssi = -128)),
            listOf(NeighborObservation(id = "peer", rssi = 21)),
            listOf(NeighborObservation(id = "peer", ageMs = -1)),
            listOf(NeighborObservation(id = "peer", ageMs = 86_400_001)),
        )
        for (neighbors in invalid) assertThrows { update(neighbors = neighbors).validate() }
    }

    @Test
    fun testNeighborsRoundTripAndAreOptionalOnTheWire() {
        val withNeighbors = packet(update(neighbors = listOf(NeighborObservation(id = "peer", rssi = -60))))
        assertEquals(withNeighbors.update, MeshPacket.decode(withNeighbors.encoded()).update)

        // Packets from app builds without the field still decode, and null is omitted on encode.
        val legacy = packet(update()).encoded()
        assertFalse(legacy.decodeToString().contains("neighbors"))
        assertNull(MeshPacket.decode(legacy).update.neighbors)
    }

    @Test
    fun testLabelTruncationCountsUTF16Units() {
        assertEquals("short", DashboardContract.truncatedLabel("short"))
        assertEquals(40, DashboardContract.truncatedLabel("x".repeat(50)).length)
        val emoji = DashboardContract.truncatedLabel("📡".repeat(30))
        assertEquals("📡".repeat(20), emoji)
        // A character that would straddle the limit is dropped whole, never split.
        assertEquals("x".repeat(39), DashboardContract.truncatedLabel("x".repeat(39) + "📡"))
    }

    @Test
    fun testPacketRoundTrip() {
        val original = packet(update(label = "Gateway", role = "gateway", accuracyMeters = 1.5))
        val decoded = MeshPacket.decode(original.encoded())
        assertEquals(MeshProtocol.version, decoded.schemaVersion)
        assertEquals(original.frameId, decoded.frameId)
        assertEquals(8, decoded.hopsRemaining)
        assertEquals(original.update, decoded.update)
    }

    @Test
    fun testPacketValidationAndDecodeValidation() {
        for (invalid in listOf(
            packet(update(), hops = -1), packet(update(), hops = 9),
            packet(update(), frame = ""),
            packet(update(), frame = "x".repeat(129)),
            packet(update(role = "bad")),
        )) {
            assertThrows { invalid.validate() }
            assertThrows { invalid.encoded() }
            val data = MeshJson.encodeToString(MeshPacket.serializer(), invalid).encodeToByteArray()
            assertThrows { MeshPacket.decode(data) }
        }
        packet(update(), hops = 0).validate()
        packet(update(), frame = "x".repeat(128)).validate()
        val obj = MeshJson.parseToJsonElement(packet(update()).encoded().decodeToString()).jsonObject
        val unsupported = JsonObject(obj + ("schemaVersion" to JsonPrimitive(1))).toString().encodeToByteArray()
        assertThrows { MeshPacket.decode(unsupported) }
        val missing = JsonObject(obj - "schemaVersion").toString().encodeToByteArray()
        assertThrows { MeshPacket.decode(missing) }
        assertThrows { MeshPacket.decode(bytes("not json")) }
    }

    @Test
    fun testDecodeSizeLimitIncludesExactBoundary() {
        val data = packet(update()).encoded()
        var atLimit = data + ByteArray(4_096 - data.size) { 32 }
        assertEquals(update(), MeshPacket.decode(atLimit).update)
        atLimit += byteArrayOf(32)
        assertThrowsError(MeshCoreError.packetTooLarge) { MeshPacket.decode(atLimit) }
    }

    @Test
    fun testDuplicateAndOutOfOrderUpdatesDoNotAlterRelay() {
        val store = MeshStore(frameId = "frame", selfId = "self")
        val newest = update(sequence = 5)
        assertEquals(7, store.ingest(packet(newest))?.hopsRemaining)
        assertNull(store.ingest(packet(newest, hops = 0)))
        assertNull(store.ingest(packet(update(sequence = 4))))
        assertEquals(newest, store.latest["device"])
        assertEquals(7, store.relayPackets["device"]?.hopsRemaining)
        assertEquals(6L, store.ingest(packet(update(sequence = 6)))?.update?.sequence)
    }

    @Test
    fun testRetiredEpochsCannotReturnEvenWithHigherSequence() {
        val store = MeshStore(frameId = "frame", selfId = "self")
        store.ingest(packet(update(sequence = 100)))
        val current = update(epochId = nextEpoch, sequence = 0)
        store.ingest(packet(current))
        assertNull(store.ingest(packet(update(sequence = 101))))
        assertNull(store.ingest(packet(update(epochId = epoch.lowercase(), sequence = 102))))
        assertEquals(current, store.latest["device"])
        assertEquals(current, store.relayPackets["device"]?.update)
    }

    @Test
    fun testEpochIdentityIsCaseInsensitive() {
        val store = MeshStore(frameId = "frame", selfId = "self")
        store.ingest(packet(update(sequence = 5)))
        assertNull(store.ingest(packet(update(epochId = epoch.lowercase(), sequence = 4))))
        assertNotNull(store.ingest(packet(update(epochId = epoch.lowercase(), sequence = 6))))
    }

    @Test
    fun testTTLAndAntiEntropyCacheNeverResetHops() {
        val store = MeshStore(frameId = "frame", selfId = "self")
        val peer = MeshStore(frameId = "frame", selfId = "peer")
        val relay = assertNotNullValue(store.ingest(packet(update(), hops = 1)))
        assertEquals(0, relay.hopsRemaining)
        repeat(3) {
            val cached = assertNotNullValue(store.relayPackets["device"])
            assertEquals(0, cached.hopsRemaining)
            assertNull(peer.ingest(MeshPacket.decode(cached.encoded())))
            assertTrue(peer.relayPackets.isEmpty())
            assertEquals(update(), peer.latest["device"])
        }
        val exhausted = update(sequence = 1)
        assertNull(store.ingest(packet(exhausted, hops = 0)))
        assertEquals(exhausted, store.latest["device"])
        assertTrue(store.relayPackets.isEmpty())
        assertNull(store.ingest(packet(exhausted, hops = 8)))
        assertTrue(store.relayPackets.isEmpty())
    }

    @Test
    fun testFrameAndInvalidPacketsDoNotMutateStore() {
        val store = MeshStore(frameId = "frame", selfId = "self")
        store.ingest(packet(update()))
        assertThrowsError(MeshCoreError.frameMismatch) { store.ingest(packet(update(sequence = 1), frame = "other")) }
        assertThrows { store.ingest(packet(update(sequence = 1), hops = 9)) }
        assertEquals(0L, store.latest["device"]?.sequence)
        assertEquals(0L, store.relayPackets["device"]?.update?.sequence)
    }

    @Test
    fun testOneHundredDevicesAndCapacityRejection() {
        val store = MeshStore(frameId = "frame", selfId = "self")
        for (index in 0 until 100) store.ingest(packet(update(id = "device-$index")))
        assertEquals(100, store.latest.size)
        assertEquals(100, store.relayPackets.size)
        assertThrowsError(MeshCoreError.deviceCapacityReached) { store.ingest(packet(update(id = "overflow"))) }
        assertNull(store.latest["overflow"])
        assertNull(store.relayPackets["overflow"])
        assertNotNull(store.ingest(packet(update(id = "device-0", sequence = 1))))
        assertEquals(100, store.latest.size)
    }

    @Test
    fun testEpochCapacityPreservesRetiredEpochsAndCurrentUpdates() {
        val store = MeshStore(frameId = "frame", selfId = "self")
        store.ingest(packet(update()))
        var currentEpoch = epoch
        for (i in 1 until 100) {
            currentEpoch = UUID.randomUUID().toString().uppercase()
            store.ingest(packet(update(epochId = currentEpoch)))
        }
        assertThrowsError(MeshCoreError.epochCapacityReached) { store.ingest(packet(update(epochId = nextEpoch))) }
        assertEquals(currentEpoch, store.latest["device"]?.epochId)
        assertNull(store.ingest(packet(update(sequence = 999))))
        assertNotNull(store.ingest(packet(update(epochId = currentEpoch, sequence = 1))))
        assertEquals(1L, store.relayPackets["device"]?.update?.sequence)
    }

    @Test
    fun testResetClearsLatestRelaysAndEpochHistory() {
        val store = MeshStore(frameId = "frame", selfId = "self")
        store.ingest(packet(update()))
        store.ingest(packet(update(epochId = nextEpoch)))
        store.reset(frameId = "new-frame")
        assertTrue(store.latest.isEmpty())
        assertTrue(store.relayPackets.isEmpty())
        assertThrows { store.ingest(packet(update())) }
        assertNotNull(store.ingest(packet(update(), frame = "new-frame")))
    }

    @Test
    fun testRSSIInitialStateAndInvalidValues() {
        val stats = RSSIStatistics()
        assertNull(stats.raw)
        assertNull(stats.smoothed)
        assertNull(stats.standardDeviation)
        assertEquals(0, stats.sampleCount)
        for (value in listOf(127, -128, 21, Int.MIN_VALUE, Int.MAX_VALUE)) assertFalse(stats.record(value))
        assertNull(stats.raw)
        assertNull(stats.smoothed)
        assertNull(stats.standardDeviation)
        assertEquals(0, stats.sampleCount)
        assertTrue(stats.record(-80))
        assertFalse(stats.record(127))
        assertEquals(-80, stats.raw)
        assertEquals(-80.0, stats.smoothed!!, 0.0)
        assertEquals(0.0, stats.standardDeviation!!, 0.0)
        assertEquals(1, stats.sampleCount)
    }

    @Test
    fun testRSSITimeBasedSmoothingAndPopulationDeviation() {
        val start = currentTime()
        val stats = RSSIStatistics()
        assertTrue(stats.record(-80, now = start))
        assertTrue(stats.record(-60, now = start + RSSIStatistics.timeConstant))
        assertEquals(-60, stats.raw)
        // One time constant closes 1 - 1/e of the gap.
        assertEquals(-60 - 20 * exp(-1.0), assertNotNullValue(stats.smoothed), 0.000001)
        assertEquals(10.0, assertNotNullValue(stats.standardDeviation), 0.000001)
        // A sample with no elapsed time does not move the average.
        val before = assertNotNullValue(stats.smoothed)
        assertTrue(stats.record(-60, now = start + RSSIStatistics.timeConstant))
        assertEquals(before, assertNotNullValue(stats.smoothed), 0.000001)
        assertEquals(3, stats.sampleCount)
    }

    @Test
    fun testRSSISmoothingDoesNotDependOnSampleRate() {
        val start = currentTime()
        val sparse = RSSIStatistics()
        val dense = RSSIStatistics()
        sparse.record(-80, now = start)
        dense.record(-80, now = start)
        sparse.record(-60, now = start + 3)
        for (second in 1..3) dense.record(-60, now = start + second.toDouble())
        assertEquals(assertNotNullValue(sparse.smoothed), assertNotNullValue(dense.smoothed), 0.000001)
    }

    @Test
    fun testRSSIBoundedWindowAndInclusiveRange() {
        val stats = RSSIStatistics()
        assertTrue(stats.record(-127))
        assertTrue(stats.record(20))
        repeat(20) { assertTrue(stats.record(-60)) }
        assertEquals(22, stats.sampleCount)
        assertEquals(0.0, assertNotNullValue(stats.standardDeviation), 0.000001)
        assertTrue(stats.record(-80))
        assertEquals(sqrt(19.0), assertNotNullValue(stats.standardDeviation), 0.000001)
    }

    @Test
    fun testRSSICopyIsIndependent() {
        // Kotlin-only: RSSIStatistics is a class here, so value copies are explicit.
        val stats = RSSIStatistics()
        stats.record(-80, now = 0.0)
        val snapshot = stats.copy()
        stats.record(-40, now = 10.0)
        assertEquals(-80, snapshot.raw)
        assertEquals(1, snapshot.sampleCount)
        assertEquals(2, stats.sampleCount)
    }

    // MARK: Relay path

    @Test
    fun testRelayPathGrowsPerHopAndOwnReportsLeaveEmpty() {
        val origin = MeshStore(frameId = "frame", selfId = "device")
        val b = MeshStore(frameId = "frame", selfId = "b")
        val c = MeshStore(frameId = "frame", selfId = "c")
        val own = assertNotNullValue(origin.ingest(packet(update(), hops = 5)))
        assertEquals(emptyList<String>(), own.path)
        assertEquals(4, own.hopsRemaining)
        val viaB = assertNotNullValue(b.ingest(MeshPacket.decode(own.encoded())))
        assertEquals(listOf("b"), viaB.path)
        val viaC = assertNotNullValue(c.ingest(MeshPacket.decode(viaB.encoded())))
        assertEquals(listOf("b", "c"), viaC.path)
        assertEquals(2, viaC.hopsRemaining)
        assertEquals(update(), viaC.update)
        // Resending the cached relay never changes its path.
        assertEquals(listOf("b", "c"), c.relayPackets["device"]?.path)
    }

    @Test
    fun testPacketThatAlreadyPassedThroughThisPhoneIsDropped() {
        val store = MeshStore(frameId = "frame", selfId = "b")
        val looped = MeshPacket(frameId = "frame", hopsRemaining = 4, update = update(), path = listOf("b", "c"))
        assertNull(store.ingest(looped))
        assertNull(store.latest["device"])
        assertNull(store.receivedAt["device"])
    }

    @Test
    fun testRelayStopsWhenPathIsFull() {
        val store = MeshStore(frameId = "frame", selfId = "self")
        val full = (1..MeshProtocol.maxPathLength).map { "relay-$it" }
        assertNull(store.ingest(MeshPacket(frameId = "frame", hopsRemaining = 8, update = update(), path = full)))
        assertEquals(update(), store.latest["device"])
        assertNull(store.relayPackets["device"])
    }

    @Test
    fun testInvalidPathsAreRejected() {
        val paths: List<List<String>> = listOf(
            (0..MeshProtocol.maxPathLength).map { "relay-$it" },
            listOf("b", "b"),
            listOf("device"),
            listOf(""),
            listOf("x".repeat(65)),
        )
        for (path in paths) {
            assertThrows { MeshPacket(frameId = "frame", hopsRemaining = 4, update = update(), path = path).validate() }
        }
    }

    @Test
    fun testFreshnessUsesLocalReceiveTime() {
        val store = MeshStore(frameId = "frame", selfId = "self")
        val start = currentTime()
        store.ingest(packet(update()), now = start)
        assertTrue(store.isFresh("device", 30.0, now = start + 30))
        assertFalse(store.isFresh("device", 30.0, now = start + 31))
        assertFalse(store.isFresh("unknown", 30.0, now = start))
        // A duplicate does not refresh the receive time.
        assertNull(store.ingest(packet(update()), now = start + 20))
        assertEquals(start, store.receivedAt["device"])
    }

    // MARK: Hello

    @Test
    fun testHelloRoundTripAndValidation() {
        val hello = Hello(frameId = "frame", deviceId = "device", label = "Phone 📡")
        assertEquals(MeshProtocol.version, hello.protocolVersion)
        assertEquals(hello, Hello.decode(hello.encoded()))
        for (invalid in listOf(
            Hello(frameId = "", deviceId = "device", label = null),
            Hello(frameId = "frame", deviceId = "", label = null),
            Hello(frameId = "frame", deviceId = "x".repeat(65), label = null),
            Hello(frameId = "frame", deviceId = "device", label = "x".repeat(41)),
        )) {
            assertThrows { invalid.encoded() }
        }
        assertThrows { Hello.decode(bytes("{}")) }
        assertThrows { Hello.decode(ByteArray(Hello.maxEncodedSize + 1) { 32 }) }
    }

    // MARK: Framing

    @Test
    fun testFramesSurviveArbitraryChunking() {
        val hello = Hello(frameId = "frame", deviceId = "device", label = null).encoded()
        val position = packet(update()).encoded()
        val stream = Framing.encode(hello, FrameType.hello)!! + Framing.encode(position, FrameType.position)!!
        for (size in listOf(1, 7, 20, 182, stream.size)) {
            val assembler = FrameAssembler()
            val frames = mutableListOf<Frame>()
            for (start in 0 until stream.size step size) {
                frames += assembler.append(stream.copyOfRange(start, minOf(start + size, stream.size)))
            }
            assertEquals(listOf(Frame(FrameType.hello, hello), Frame(FrameType.position, position)), frames)
            assertFalse(assembler.hasPartialFrame)
        }
    }

    @Test
    fun testMalformedFramesAreRejectedAndTheAssemblerRecovers() {
        val valid = Framing.encode(bytes("ok"), FrameType.position)!!
        val malformed: List<ByteArray> = listOf(
            byteArrayOf(0, 0, 0, 0, 2) + bytes("ok"),   // type 0: also how a version 1 length prefix starts
            byteArrayOf(2, 0, 0, 0, 0),                 // empty payload
            byteArrayOf(2, 0, 0, 0x10, 0x01),           // 4,097-byte payload
            byteArrayOf(2, 0, 0, 0x10, 0) + ByteArray(8_200),  // over the buffer limit
        )
        for (data in malformed) {
            val assembler = FrameAssembler()
            assertThrowsError(MeshCoreError.invalidFrame) { assembler.append(data) }
            assertFalse(assembler.hasPartialFrame)
            assertEquals(listOf(Frame(FrameType.position, bytes("ok"))), assembler.append(valid))
        }
        assertNull(Framing.encode(ByteArray(0), FrameType.position))
        assertNull(Framing.encode(ByteArray(Framing.maxPayload + 1), FrameType.position))
        assertNotNull(Framing.encode(ByteArray(Framing.maxPayload), FrameType.position))
    }

    @Test
    fun testPartialFrameExpires() {
        val start = currentTime()
        val framed = Framing.encode(bytes("payload"), FrameType.position)!!
        val assembler = FrameAssembler()
        assertEquals(emptyList<Frame>(), assembler.append(framed.copyOfRange(0, 3), now = start))
        assertFalse(assembler.expire(now = start + FrameAssembler.timeout))
        assertTrue(assembler.hasPartialFrame)
        assertTrue(assembler.expire(now = start + FrameAssembler.timeout + 0.1))
        assertFalse(assembler.hasPartialFrame)
        assertEquals(listOf(Frame(FrameType.position, bytes("payload"))), assembler.append(framed))
    }

    @Test
    fun testUnknownFrameTypesAreSkipped() {
        val known = Framing.encode(bytes("ok"), FrameType.position)!!
        val assembler = FrameAssembler()
        val frames = assembler.append(byteArrayOf(9, 0, 0, 0, 3) + bytes("new") + known)
        assertEquals(listOf(Frame(FrameType.position, bytes("ok"))), frames)
        assertFalse(assembler.hasPartialFrame)
    }

    // MARK: Ranging

    private fun assertClose(a: Position?, b: Position, accuracy: Double = 1e-9) {
        if (a == null) fail("nil position")
        a!!
        assertEquals(b.x, a.x, accuracy)
        assertEquals(b.y, a.y, accuracy)
        assertEquals(b.z, a.z, accuracy)
    }

    private fun rangingFix(
        heading: Double,
        gravity: Vector3 = AnchorGeometry.upright,
        direction: Vector3,
        distance: Double = 2.0,
        floor: Boolean = false,
    ): RangingFix? = AnchorGeometry.fix(
        anchorId = "anchor", targetId = "target", anchor = Position(x = 10.0, y = 1.0, z = 20.0),
        headingDegrees = heading, gravity = gravity, distance = distance, direction = direction, floor = floor,
    )

    @Test
    fun testUprightAnchorMapsDeviceAxesByHeading() {
        val behind = Vector3(0.0, 0.0, -1.0)
        val right = Vector3(1.0, 0.0, 0.0)
        val up = Vector3(0.0, 1.0, 0.0)
        // Heading 0: the back faces map +z and the screen's right is map +x.
        assertClose(rangingFix(heading = 0.0, direction = behind)?.position, Position(x = 10.0, y = 1.0, z = 22.0))
        assertClose(rangingFix(heading = 0.0, direction = right)?.position, Position(x = 12.0, y = 1.0, z = 20.0))
        assertClose(rangingFix(heading = 0.0, direction = up)?.position, Position(x = 10.0, y = 3.0, z = 20.0))
        // Heading 90: the back faces map +x, so the screen's right is map -z.
        assertClose(rangingFix(heading = 90.0, direction = behind)?.position, Position(x = 12.0, y = 1.0, z = 20.0))
        assertClose(rangingFix(heading = 90.0, direction = right)?.position, Position(x = 10.0, y = 1.0, z = 18.0))
        assertClose(rangingFix(heading = 180.0, direction = behind)?.position, Position(x = 10.0, y = 1.0, z = 18.0))
        assertClose(rangingFix(heading = -90.0, direction = behind)?.position, Position(x = 8.0, y = 1.0, z = 20.0))
    }

    @Test
    fun testGravityCorrectsPitch() {
        // Tilted so the screen faces 30° downwards: gravity gains a +z (out of the screen) part and the back points 30° up.
        val pitch = 30.0 * PI / 180
        val gravity = Vector3(0.0, -cos(pitch), sin(pitch))
        val behind = Vector3(0.0, 0.0, -1.0)
        val level = Vector3(0.0, -sin(pitch), -cos(pitch))   // a horizontal ray straight ahead, in device axes
        assertClose(rangingFix(heading = 0.0, gravity = gravity, direction = level)?.position, Position(x = 10.0, y = 1.0, z = 22.0))
        assertClose(
            rangingFix(heading = 0.0, gravity = gravity, direction = behind)?.position,
            Position(x = 10.0, y = 1 + 2 * sin(pitch), z = 20 + 2 * cos(pitch)),
        )
    }

    @Test
    fun testFlatPhoneFloorModeAndInvalidMeasurements() {
        val behind = Vector3(0.0, 0.0, -1.0)
        assertNull("lying flat: heading undefined", rangingFix(heading = 0.0, gravity = Vector3(0.0, 0.0, 1.0), direction = behind))
        assertNull(rangingFix(heading = 0.0, direction = Vector3(0.0, 0.0, 0.0)))
        assertNull(rangingFix(heading = Double.NaN, direction = behind))
        assertNull(rangingFix(heading = 0.0, direction = behind, distance = -1.0))
        assertNull(rangingFix(heading = 0.0, direction = behind, distance = Double.POSITIVE_INFINITY))
        assertClose(
            rangingFix(heading = 0.0, direction = Vector3(0.0, 1.0, -1.0), distance = 2.0, floor = true)?.position,
            Position(x = 10.0, y = 0.0, z = 20 + sqrt(2.0)),
        )
        // Non-unit directions are normalized.
        assertClose(rangingFix(heading = 0.0, direction = Vector3(0.0, 0.0, -5.0))?.position, Position(x = 10.0, y = 1.0, z = 22.0))
    }

    @Test
    fun testAccuracyGrowsWithDistance() {
        assertEquals(AnchorGeometry.baseErrorMeters, AnchorGeometry.accuracy(distance = 0.0), 0.0)
        val near = AnchorGeometry.accuracy(distance = 2.0)
        val far = AnchorGeometry.accuracy(distance = 8.0)
        assertTrue(near < far)
        assertEquals(8 * sin(15 * PI / 180) + 0.3, far, 0.01)
        assertEquals(far, assertNotNullValue(rangingFix(heading = 0.0, direction = Vector3(0.0, 0.0, -1.0), distance = 8.0)).accuracyMeters, 0.0)
    }

    @Test
    fun testRangingMessagesRoundTripAndValidate() {
        val fix = assertNotNullValue(rangingFix(heading = 0.0, direction = Vector3(0.0, 0.0, -1.0)))
        assertEquals(fix, RangingFix.decode(fix.encoded()))
        for (invalid in listOf(
            RangingFix(anchorId = "a", targetId = "a", position = Position(x = 0.0, y = 0.0, z = 0.0), accuracyMeters = 1.0, distanceMeters = 1.0),
            RangingFix(anchorId = "a", targetId = "b", position = Position(x = 10_001.0, y = 0.0, z = 0.0), accuracyMeters = 1.0, distanceMeters = 1.0),
            RangingFix(anchorId = "a", targetId = "b", position = Position(x = 0.0, y = 0.0, z = 0.0), accuracyMeters = 1_001.0, distanceMeters = 1.0),
            RangingFix(anchorId = "a", targetId = "b", position = Position(x = 0.0, y = 0.0, z = 0.0), accuracyMeters = 1.0, distanceMeters = -1.0),
        )) {
            assertThrows { invalid.encoded() }
        }
        val token = RangingToken(token = byteArrayOf(1, 2, 3), isAnchor = true)
        assertEquals(token, RangingToken.decode(token.encoded()))
        assertThrows { RangingToken(token = ByteArray(0), isAnchor = false).encoded() }
        assertThrows { RangingToken(token = ByteArray(RangingToken.maxTokenSize + 1), isAnchor = false).encoded() }
    }

    // MARK: Link outbox

    private fun drain(outbox: LinkOutbox, maxLength: Int): List<ByteArray> {
        val sent = mutableListOf<ByteArray>()
        while (true) {
            val chunk = outbox.nextChunk(maxLength) ?: break
            sent.add(chunk)
            outbox.chunkSent()
        }
        return sent
    }

    private fun assertChunks(expected: List<String>, actual: List<ByteArray>) {
        assertEquals(expected, actual.map { it.decodeToString() })
    }

    @Test
    fun testOutboxReplacesQueuedMessageWithSameKey() {
        val outbox = LinkOutbox()
        outbox.enqueue(bytes("old-a"), key = "a")
        outbox.enqueue(bytes("b"), key = "b")
        outbox.enqueue(bytes("new-a"), key = "a")
        assertEquals(2, outbox.pendingCount)
        // The replacement keeps the original place in line.
        assertChunks(listOf("new-a", "b"), drain(outbox, maxLength = 100))
        assertTrue(outbox.isEmpty)
    }

    @Test
    fun testOutboxFinishesTransferInProgressBeforeReplacement() {
        val outbox = LinkOutbox()
        outbox.enqueue(bytes("abcdef"), key = "a")
        assertArrayEquals(bytes("abcd"), outbox.nextChunk(maxLength = 4))
        outbox.chunkSent()
        outbox.enqueue(bytes("XYZ"), key = "a")
        assertChunks(listOf("ef", "XYZ"), drain(outbox, maxLength = 4))
    }

    @Test
    fun testOutboxChunksRespectMaxLength() {
        val outbox = LinkOutbox()
        val message = ByteArray(50) { it.toByte() }
        outbox.enqueue(message, key = "a")
        val chunks = drain(outbox, maxLength = 20)
        assertEquals(listOf(20, 20, 10), chunks.map { it.size })
        assertArrayEquals(message, chunks.fold(ByteArray(0)) { acc, chunk -> acc + chunk })
        // A chunk is removed only once sent, so an unsent chunk is offered again unchanged.
        outbox.enqueue(message, key = "a")
        val first = outbox.nextChunk(maxLength = 20)
        val again = outbox.nextChunk(maxLength = 20)
        assertArrayEquals(first, again)
    }

    @Test
    fun testGeoFrameConvertsGPSToEastNorthMeters() {
        val origin = assertNotNullValue(GeoFrame.origins[GeoFrame.defaultFrameId])
        val atOrigin = assertNotNullValue(
            GeoFrame.position(frameId = GeoFrame.defaultFrameId, latitude = origin.latitude, longitude = origin.longitude),
        )
        assertEquals(Position(x = 0.0, y = 0.0, z = 0.0), atOrigin)
        // 0.001° north is about 111 m; 0.002° east at 61.45° N is about 106 m.
        val moved = assertNotNullValue(
            GeoFrame.position(frameId = GeoFrame.defaultFrameId, latitude = origin.latitude + 0.001, longitude = origin.longitude + 0.002),
        )
        assertEquals(111.2, moved.z, 0.5)
        assertEquals(106.3, moved.x, 0.5)
        assertEquals(0.0, moved.y, 0.0)
        update(position = moved, positionMode = "floor").validate()
    }

    @Test
    fun testGeoFrameCoordinateIsTheInverse() {
        val p = assertNotNullValue(GeoFrame.position(frameId = GeoFrame.defaultFrameId, latitude = 61.4512, longitude = 23.8601))
        val back = assertNotNullValue(GeoFrame.coordinate(frameId = GeoFrame.defaultFrameId, x = p.x, z = p.z))
        assertEquals(61.4512, back.latitude, 1e-9)
        assertEquals(23.8601, back.longitude, 1e-9)
        assertNull(GeoFrame.coordinate(frameId = "demo-room-v1", x = 0.0, z = 0.0))
    }

    @Test
    fun testGeoFrameRejectsUnknownFramesAndFarFixes() {
        assertNull(GeoFrame.position(frameId = "demo-room-v1", latitude = 61.4499, longitude = 23.856))
        // Helsinki is ~150 km away, outside the dashboard's ±10 km limit.
        assertNull(GeoFrame.position(frameId = GeoFrame.defaultFrameId, latitude = 60.17, longitude = 24.94))
    }

    @Test
    fun testPositionSourceRoundTripsAndIsOptionalOnTheWire() {
        for (source in PositionSource.entries) {
            val value = DeviceUpdate(
                id = "device", epochId = epoch, sequence = 1, role = "mobile",
                position = Position(x = 0.0, y = 0.0, z = 0.0), positionMode = "floor",
                positionSource = source,
            )
            val decoded = MeshPacket.decode(packet(value).encoded())
            assertEquals(source, decoded.update.positionSource)
        }
        // Reports from builds without the field still decode, as manual positions.
        val legacy = MeshPacket.decode(packet(update()).encoded())
        assertNull(legacy.update.positionSource)
        val unknown = """{"schemaVersion":${MeshProtocol.version},"frameId":"frame","hopsRemaining":3,"path":[],""" +
            """"update":{"id":"d","epochId":"$epoch","sequence":1,"role":"mobile",""" +
            """"position":{"x":0,"y":0,"z":0},"positionMode":"floor","positionSource":"guess"}}"""
        assertThrows { MeshPacket.decode(bytes(unknown)) }
    }
}

/** XCTAssertThrowsError. */
private fun assertThrows(body: () -> Unit) {
    try {
        body()
    } catch (e: Exception) {
        return
    }
    fail("expected an error")
}

/** XCTAssertThrowsError with `XCTAssertEqual(error as? MeshCoreError, expected)`. */
private fun assertThrowsError(expected: MeshCoreError, body: () -> Unit) {
    try {
        body()
    } catch (e: Exception) {
        assertEquals(expected, e)
        return
    }
    fail("expected $expected")
}

/** XCTUnwrap. */
private fun <T : Any> assertNotNullValue(value: T?): T {
    assertNotNull(value)
    return value!!
}
