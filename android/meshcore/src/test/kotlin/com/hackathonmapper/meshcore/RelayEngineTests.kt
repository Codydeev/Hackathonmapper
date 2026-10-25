package com.hackathonmapper.meshcore

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Swift `UUID().uuidString`. */
private fun newUUID(): String = UUID.randomUUID().toString().uppercase()

/**
 * In-memory phones joined by links that come and go. Every frame goes through the real wire path:
 * JSON encoding, `Framing`, chunking at a BLE-sized payload and `FrameAssembler`.
 */
private class SimulatedMesh(ids: List<String>, configuration: RelayEngine.Configuration = RelayEngine.Configuration()) {
    companion object {
        const val chunkSize = 182

        private fun key(a: String, b: String): String = if (a < b) "$a|$b" else "$b|$a"
    }

    private class Chunk(val from: String, val to: String, val chunk: ByteArray)

    var now: TimeInterval = 1_000.0
    val engines = HashMap<String, RelayEngine>()
    private val deliveries = HashMap<String, MutableList<RelayDelivery>>()
    var framesSent = 0
        private set
    private val links = HashSet<String>()
    private val queue = ArrayDeque<Chunk>()
    private val assemblers = HashMap<String, FrameAssembler>()

    init {
        for (id in ids) engines[id] = RelayEngine(selfId = id, configuration = configuration)
    }

    operator fun get(id: String): RelayEngine = engines[id]!!

    fun delivered(id: String): List<RelayDelivery> = deliveries[id] ?: emptyList()

    fun link(a: String, b: String, run: Boolean = true) {
        links.add(key(a, b))
        handle(a, this[a].neighborReady(b, now = now))
        handle(b, this[b].neighborReady(a, now = now))
        if (run) run()
    }

    /** Ends the link. Anything still in flight on it is lost. */
    fun unlink(a: String, b: String) {
        links.remove(key(a, b))
        this[a].neighborLost(b)
        this[b].neighborLost(a)
        queue.removeAll { key(it.from, it.to) == key(a, b) }
        assemblers.remove("$a>$b")
        assemblers.remove("$b>$a")
    }

    /** Loses everything in flight while the links stay up, like a failed write or notification. */
    fun dropInFlight() {
        queue.clear()
        assemblers.clear()
    }

    fun send(
        from: String,
        to: String? = null,
        kind: String = "text",
        body: String = "hello",
        ttlMs: Int? = null,
        hops: Int? = null,
        run: Boolean = true,
    ): RelayEnvelope {
        val (envelope, actions) = this[from].originate(
            kind = kind, body = body, to = to, ttlMs = ttlMs, hops = hops,
            now = now, wallClock = 1_800_000_000 + now,
        )
        handle(from, actions)
        if (run) run()
        return envelope
    }

    /** Moves time forward one second at a time, ticking every phone and delivering what it sends. */
    fun advance(seconds: Int) {
        repeat(seconds) {
            now += 1
            for (id in engines.keys.sorted()) handle(id, this[id].tick(now = now))
            run()
        }
    }

    fun run() {
        var steps = 0
        while (queue.isNotEmpty()) {
            steps += 1
            check(steps < 100_000) { "relay traffic did not settle" }
            val item = queue.removeFirst()
            if (!links.contains(key(item.from, item.to))) continue
            val direction = "${item.from}>${item.to}"
            val assembler = assemblers.getOrPut(direction) { FrameAssembler() }
            val frames = assembler.append(item.chunk, now = now)
            for (frame in frames) {
                handle(item.to, this[item.to].receive(frame, from = item.from, now = now))
            }
        }
    }

    private fun handle(id: String, actions: List<RelayAction>) {
        for (action in actions) {
            when (action) {
                is RelayAction.send -> enqueue(Framing.encode(action.envelope.encoded(), FrameType.relayMessage)!!, from = id, to = action.to)
                is RelayAction.sendSummary -> enqueue(Framing.encode(action.summary.encoded(), FrameType.relaySummary)!!, from = id, to = action.to)
                is RelayAction.deliver -> deliveries.getOrPut(id) { mutableListOf() }.add(action.delivery)
            }
        }
    }

    private fun enqueue(framed: ByteArray, from: String, to: String) {
        if (!links.contains(key(from, to))) return
        framesSent += 1
        for (start in 0 until framed.size step chunkSize) {
            queue.addLast(Chunk(from, to, framed.copyOfRange(start, minOf(start + chunkSize, framed.size))))
        }
    }
}

/** Port of ios/MeshCore/Tests/MeshCoreTests/RelayEngineTests.swift. */
class RelayEngineTests {
    private fun envelope(
        originId: String = "phone-a",
        destinationId: String? = null,
        kind: String = "text",
        body: String = "hello",
        ageMs: Int = 0,
        ttlMs: Int = 60_000,
        hopsRemaining: Int = 4,
        path: List<String> = emptyList(),
        acknowledges: String? = null,
    ): RelayEnvelope = RelayEnvelope(
        originId = originId, destinationId = destinationId, kind = kind, body = body,
        createdAt = 1_800_000_000_000.0, ageMs = ageMs, ttlMs = ttlMs,
        hopsRemaining = hopsRemaining, path = path, acknowledges = acknowledges,
    )

    private fun frame(envelope: RelayEnvelope): Frame = Frame(FrameType.relayMessage, envelope.encoded())

    private fun assertThrows(message: String = "expected an error", body: () -> Unit) {
        try {
            body()
        } catch (e: Exception) {
            return
        }
        fail(message)
    }

    // MARK: Envelope

    @Test
    fun testEnvelopeRoundTripsThroughJSON() {
        val original = envelope(destinationId = "phone-c", path = listOf("phone-b"))
        val decoded = RelayEnvelope.decode(original.encoded())
        assertEquals(original, decoded)
        assertEquals(original.messageId, decoded.messageId)
    }

    @Test
    fun testEnvelopeValidation() {
        envelope().validate()
        envelope(hopsRemaining = 7, path = listOf("b")).validate()
        envelope(kind = "ghostcore.sos").validate()
        envelope(body = "x".repeat(RelayEnvelope.maxBodyBytes)).validate()
        // Expired copies are well formed; the engine counts them.
        envelope(ageMs = 60_000).validate()
        val receipt = envelope(destinationId = "phone-c", kind = RelayEnvelope.receiptKind, acknowledges = newUUID())
        receipt.validate()

        val invalid = listOf(
            envelope(originId = ""),
            envelope(originId = "a".repeat(65)),
            envelope(destinationId = "phone-a"),
            envelope(kind = "Text"),
            envelope(kind = ""),
            envelope(kind = "k".repeat(33)),
            envelope(body = "x".repeat(RelayEnvelope.maxBodyBytes + 1)),
            envelope(ageMs = -1),
            envelope(ttlMs = 0),
            envelope(ttlMs = RelayEnvelope.maxTTLMs + 1),
            envelope(hopsRemaining = -1),
            envelope(hopsRemaining = 8, path = listOf("b")),
            envelope(path = listOf("phone-a")),
            envelope(path = listOf("b", "b")),
            envelope(path = listOf("")),
            envelope(kind = RelayEnvelope.receiptKind),
            envelope(acknowledges = newUUID()),
        )
        for (value in invalid) {
            assertThrows("$value") { value.validate() }
            assertThrows("$value") { value.encoded() }
        }
    }

    @Test
    fun testDecodeRejectsMalformedAndOversizedPayloads() {
        assertThrows { RelayEnvelope.decode("{}".encodeToByteArray()) }
        assertThrows { RelayEnvelope.decode(ByteArray(RelayEnvelope.maxEncodedSize + 1) { 0x20 }) }
        assertThrows { RelaySummary.decode("[1]".encodeToByteArray()) }
    }

    @Test
    fun testSummaryIsBounded() {
        RelaySummary(have = (0 until RelaySummary.maxIds).map { newUUID() }).encoded()
        val full = RelaySummary(have = (0 until RelaySummary.maxIds).map { newUUID() }).encoded()
        assertTrue(full.size <= Framing.maxPayload)
        assertThrows { RelaySummary(have = (0..RelaySummary.maxIds).map { newUUID() }).encoded() }
    }

    @Test
    fun testOriginateRejectsInvalidMessages() {
        val engine = RelayEngine(selfId = "phone-a")
        assertThrows { engine.originate(kind = "text", body = "x", to = "phone-a", now = 0.0) }
        assertThrows { engine.originate(kind = "BAD", body = "x", now = 0.0) }
        assertThrows { engine.originate(kind = "text", body = "x", hops = 9, now = 0.0) }
        assertEquals(0, engine.statistics.originated)
    }

    // MARK: Direct and multi-hop delivery

    @Test
    fun testDirectMessageIsDeliveredOnceAndAcknowledged() {
        val mesh = SimulatedMesh(listOf("a", "b"))
        mesh.link("a", "b")
        val sent = mesh.send(from = "a", to = "b", body = "ping")

        assertEquals(1, mesh.delivered("b").size)
        val delivery = mesh.delivered("b").first()
        assertEquals(sent.messageId, delivery.envelope.messageId)
        assertEquals("a", delivery.envelope.originId)
        assertEquals("ping", delivery.envelope.body)
        assertEquals(emptyList<String>(), delivery.envelope.path)
        assertEquals(1, delivery.hops)
        assertEquals("a", delivery.fromNeighbor)

        val receipt = mesh.delivered("a").first()
        assertTrue(receipt.envelope.isReceipt)
        assertEquals(sent.messageId, receipt.envelope.acknowledges)
        assertEquals("a", receipt.envelope.destinationId)
        assertEquals(RelayReceiptInfo(path = emptyList(), ageMs = 0), RelayReceiptInfo.decode(receipt.envelope.body))
        assertFalse("a receipt ends store-and-forward of the message", mesh["a"].isStored(sent.messageId))
        assertFalse("the destination does not forward a message for itself", mesh["b"].isStored(sent.messageId))
    }

    @Test
    fun testThreePhoneChainRelaysThroughTheMiddlePhone() {
        // A and C have no link; only B can carry A's message.
        val mesh = SimulatedMesh(listOf("a", "b", "c"))
        mesh.link("a", "b")
        mesh.link("b", "c")
        val sent = mesh.send(from = "a", to = "c", hops = 4)

        val delivery = mesh.delivered("c").first()
        assertEquals(1, mesh.delivered("c").size)
        assertEquals("message IDs survive relaying", sent.messageId, delivery.envelope.messageId)
        assertEquals("a", delivery.envelope.originId)
        assertEquals(sent.createdAt, delivery.envelope.createdAt)
        assertEquals(listOf("b"), delivery.envelope.path)
        assertEquals(3, delivery.envelope.hopsRemaining)
        assertEquals(2, delivery.hops)
        assertEquals("b", delivery.fromNeighbor)
        assertTrue("B relays a message addressed to C without delivering it", mesh.delivered("b").isEmpty())

        val receipt = mesh.delivered("a").first()
        assertEquals(sent.messageId, receipt.envelope.acknowledges)
        assertEquals(listOf("b"), receipt.envelope.path)
        assertEquals(listOf("b"), RelayReceiptInfo.decode(receipt.envelope.body)?.path)
        assertFalse("the receipt passing through B clears B's copy", mesh["b"].isStored(sent.messageId))
        assertEquals(1, mesh["b"].statistics.cleared)
    }

    @Test
    fun testBroadcastIsDeliveredByEveryPhoneExactlyOnce() {
        // Diamond: D hears A's broadcast through both B and C.
        val mesh = SimulatedMesh(listOf("a", "b", "c", "d"))
        mesh.link("a", "b")
        mesh.link("a", "c")
        mesh.link("b", "d")
        mesh.link("c", "d")
        val sent = mesh.send(from = "a", body = "all")

        for (id in listOf("b", "c", "d")) {
            assertEquals(id, listOf(sent.messageId), mesh.delivered(id).map { it.envelope.messageId })
        }
        assertTrue("no receipts for broadcasts, no self-delivery", mesh.delivered("a").isEmpty())
        val suppressed = listOf("b", "c", "d").sumOf { mesh[it].statistics.duplicates + mesh[it].statistics.loops }
        assertTrue("the second copy reaching D is suppressed", suppressed >= 1)
    }

    @Test
    fun testHopLimitStopsForwarding() {
        val mesh = SimulatedMesh(listOf("a", "b", "c", "d"))
        mesh.link("a", "b")
        mesh.link("b", "c")
        mesh.link("c", "d")
        mesh.send(from = "a", hops = 1)

        assertEquals(1, mesh.delivered("b").size)
        assertEquals(0, mesh.delivered("c").firstOrNull()?.envelope?.hopsRemaining)
        assertEquals(listOf("b"), mesh.delivered("c").firstOrNull()?.envelope?.path)
        assertTrue(mesh.delivered("d").isEmpty())
        assertEquals(1, mesh["c"].statistics.hopLimited)
    }

    @Test
    fun testRelayIgnoresLoopsAndItsOwnMessages() {
        val engine = RelayEngine(selfId = "phone-b")
        engine.neighborReady("phone-a", now = 0.0)
        val looped = envelope(originId = "phone-a", path = listOf("phone-b"))
        assertTrue(engine.receive(frame(looped), from = "phone-a", now = 1.0).isEmpty())
        val own = envelope(originId = "phone-b", path = listOf("phone-a"))
        assertTrue(engine.receive(frame(own), from = "phone-a", now = 1.0).isEmpty())
        assertEquals(2, engine.statistics.loops)
        assertEquals(0, engine.statistics.accepted)
    }

    @Test
    fun testInvalidFramesAreCountedNotDelivered() {
        val engine = RelayEngine(selfId = "phone-b")
        assertTrue(engine.receive(Frame(FrameType.relayMessage, "not json".encodeToByteArray()), from = "phone-a", now = 0.0).isEmpty())
        assertTrue(engine.receive(Frame(FrameType.relaySummary, "{}".encodeToByteArray()), from = "phone-a", now = 0.0).isEmpty())
        assertTrue(engine.receive(Frame(FrameType.position, "{}".encodeToByteArray()), from = "phone-a", now = 0.0).isEmpty())
        assertEquals(2, engine.statistics.invalid)
        assertTrue(engine.relayCapable.isEmpty())
    }

    // MARK: Store and forward

    @Test
    fun testMiddlePhoneCarriesMessageToPhoneThatArrivesLater() {
        // A and B are together; C is out of range. B walks away from A, holds the message for 45 s,
        // then meets C.
        val mesh = SimulatedMesh(listOf("a", "b", "c"))
        mesh.link("a", "b")
        val sent = mesh.send(from = "a", to = "c", body = "need water", ttlMs = 10 * 60_000)
        assertTrue(mesh["b"].isStored(sent.messageId))
        assertTrue(mesh.delivered("c").isEmpty())

        mesh.unlink("a", "b")
        mesh.advance(45)
        mesh.link("b", "c")

        val delivery = mesh.delivered("c").first()
        assertEquals(1, mesh.delivered("c").size)
        assertEquals(sent.messageId, delivery.envelope.messageId)
        assertEquals(listOf("b"), delivery.envelope.path)
        assertTrue("B's hold time is part of the age", delivery.envelope.ageMs >= 45_000)
        assertTrue(delivery.envelope.ageMs < 46_000)
        assertFalse("C's receipt clears B's copy", mesh["b"].isStored(sent.messageId))

        // A is still waiting: the receipt rides back with B.
        assertTrue(mesh.delivered("a").isEmpty())
        assertTrue(mesh["a"].isStored(sent.messageId))
        mesh.unlink("b", "c")
        mesh.advance(10)
        mesh.link("a", "b")
        val receipt = mesh.delivered("a").first()
        assertEquals(sent.messageId, receipt.envelope.acknowledges)
        assertEquals(listOf("b"), RelayReceiptInfo.decode(receipt.envelope.body)?.path)
        assertFalse(mesh["a"].isStored(sent.messageId))
        assertEquals("nothing is delivered twice", 1, mesh.delivered("c").size)
    }

    @Test
    fun testAgeAccumulatesAcrossHoldsWithoutWallClocks() {
        val mesh = SimulatedMesh(listOf("a", "b", "c"))
        val sent = mesh.send(from = "a", body = "beacon")
        mesh.advance(2)
        mesh.link("a", "b")
        assertEquals(2_000, mesh.delivered("b").firstOrNull()?.envelope?.ageMs)
        mesh.advance(3)
        mesh.link("b", "c")
        val atC = mesh.delivered("c").first()
        assertEquals(5_000, atC.envelope.ageMs)
        assertEquals("the origin wall clock rides along unchanged", sent.createdAt, atC.envelope.createdAt)
    }

    @Test
    fun testExpiredMessagesAreNotCarriedFurther() {
        val mesh = SimulatedMesh(listOf("a", "b", "c"))
        mesh.link("a", "b")
        val sent = mesh.send(from = "a", to = "c", ttlMs = 30_000)
        mesh.unlink("a", "b")
        mesh.advance(31)
        assertFalse(mesh["b"].isStored(sent.messageId))
        assertTrue(mesh["b"].statistics.expired >= 1)
        mesh.link("b", "c")
        assertTrue(mesh.delivered("c").isEmpty())
    }

    @Test
    fun testCopyArrivingAfterItsTTLIsDropped() {
        val engine = RelayEngine(selfId = "phone-b")
        engine.neighborReady("phone-a", now = 0.0)
        val late = envelope(destinationId = "phone-b", ageMs = 60_000, ttlMs = 60_000)
        assertTrue(engine.receive(frame(late), from = "phone-a", now = 1.0).isEmpty())
        assertEquals(1, engine.statistics.expired)
        assertEquals(0, engine.statistics.delivered)
    }

    @Test
    fun testReconnectResendsOnlyWhatWasLost() {
        val mesh = SimulatedMesh(listOf("a", "b"))
        mesh.link("a", "b")
        val first = mesh.send(from = "a", body = "one")
        assertEquals(1, mesh.delivered("b").size)

        // The second message is queued, then the link drops before it is sent.
        val second = mesh.send(from = "a", body = "two", run = false)
        mesh.unlink("a", "b")
        assertEquals(1, mesh.delivered("b").size)

        mesh.advance(6)
        val framesBefore = mesh.framesSent
        mesh.link("a", "b")
        assertEquals(listOf(first.messageId, second.messageId), mesh.delivered("b").map { it.envelope.messageId })
        // Two summaries plus the one missing message: the delivered one is not resent.
        assertEquals(3, mesh.framesSent - framesBefore)
    }

    @Test
    fun testPeriodicSummaryRepairsLossOnAStableLink() {
        val configuration = RelayEngine.Configuration()
        configuration.summaryInterval = 10.0
        val mesh = SimulatedMesh(listOf("a", "b"), configuration = configuration)
        mesh.link("a", "b")
        val lost = mesh.send(from = "a", body = "lost", run = false)
        mesh.dropInFlight()
        mesh.advance(9)
        assertTrue("no summary is due yet", mesh.delivered("b").isEmpty())
        mesh.advance(1)
        assertEquals(listOf(lost.messageId), mesh.delivered("b").map { it.envelope.messageId })
    }

    @Test
    fun testNeighborsWithoutTheRelayGetNoEnvelopes() {
        val engine = RelayEngine(selfId = "phone-a")
        val ready = engine.neighborReady("old-build", now = 0.0)
        assertEquals(1, ready.size)
        if (ready[0] !is RelayAction.sendSummary) fail("expected a summary")
        val (_, actions) = engine.originate(kind = "text", body = "x", now = 1.0)
        assertTrue("a phone that never sent a relay frame skips them anyway", actions.isEmpty())
        assertEquals(1, engine.storedCount)
    }

    @Test
    fun testLostNeighborStopsReceivingCopies() {
        val mesh = SimulatedMesh(listOf("a", "b"))
        mesh.link("a", "b")
        mesh.unlink("a", "b")
        mesh.send(from = "a")
        assertTrue(mesh.delivered("b").isEmpty())
        assertFalse(mesh["a"].neighbors.contains("b"))
    }

    // MARK: Bounds

    @Test
    fun testStorageIsBoundedAndEvictsClosestToExpiry() {
        val configuration = RelayEngine.Configuration()
        configuration.maxStored = 4
        val engine = RelayEngine(selfId = "phone-a", configuration = configuration)
        val (shortLived, _) = engine.originate(kind = "text", body = "short", ttlMs = 10_000, now = 0.0)
        for (index in 0 until 9) {
            engine.originate(kind = "text", body = "$index", ttlMs = 600_000, now = 1.0)
        }
        assertEquals(4, engine.storedCount)
        assertEquals(6, engine.statistics.evicted)
        assertFalse(engine.isStored(shortLived.messageId))
    }

    @Test
    fun testSeenIdsAreBoundedAndForgottenAfterTheirLifetime() {
        val configuration = RelayEngine.Configuration()
        configuration.maxSeen = 3
        configuration.seenLifetime = 60.0
        val engine = RelayEngine(selfId = "phone-a", configuration = configuration)
        val ids = (0 until 4).map { engine.originate(kind = "text", body = "x", now = 0.0).first.messageId }
        assertFalse(engine.hasSeen(ids[0]))
        assertTrue(engine.hasSeen(ids[3]))
        assertEquals(ids.drop(1).reversed(), engine.summary().have)
        engine.tick(now = 61.0)
        assertFalse(engine.hasSeen(ids[3]))
        assertTrue(engine.summary().have.isEmpty())
    }

    @Test
    fun testDefaultLimitsFitTheFraming() {
        val path = (1..7).map { "relay-$it-" + "x".repeat(50) }
        val largest = RelayEnvelope(
            originId = "o".repeat(64), destinationId = "d".repeat(64),
            kind = "k".repeat(32), body = "é".repeat(RelayEnvelope.maxBodyBytes / 2),
            createdAt = 1_800_000_000_000.0, ageMs = 899_999, ttlMs = RelayEnvelope.maxTTLMs,
            hopsRemaining = 1, path = path,
        )
        val encoded = largest.encoded()
        assertTrue(encoded.size <= RelayEnvelope.maxEncodedSize)
        assertNotNull(Framing.encode(encoded, FrameType.relayMessage))
        assertTrue(RelayEngine.Configuration().seenLifetime * 1000 > RelayEnvelope.maxTTLMs.toDouble())
    }

    @Test
    fun testResetForgetsEverything() {
        val engine = RelayEngine(selfId = "phone-a")
        engine.neighborReady("phone-b", now = 0.0)
        val (sent, _) = engine.originate(kind = "text", body = "x", now = 0.0)
        engine.reset()
        assertFalse(engine.hasSeen(sent.messageId))
        assertEquals(0, engine.storedCount)
        assertTrue(engine.neighbors.isEmpty())
        assertEquals(RelayStatistics(), engine.statistics)
    }

    // MARK: T3 beacon

    @Test
    fun testSimulatedT3RunThroughTheMiddlePhone() {
        // Two minutes of 1 Hz beacons from A, with no A–C link; the B–C link drops for 10 s midway.
        val mesh = SimulatedMesh(listOf("a", "b", "c"))
        mesh.link("a", "b")
        mesh.link("b", "c")
        for (seq in 0 until 120) {
            if (seq == 60) mesh.unlink("b", "c")
            if (seq == 70) mesh.link("b", "c")
            mesh.send(
                from = "a", kind = BeaconPayload.kind, body = BeaconPayload(run = "run1", seq = seq).body,
                ttlMs = 30_000, hops = 2,
            )
            mesh.advance(1)
        }
        val stats = BeaconStats(originId = "a", run = "run1")
        for (delivery in mesh.delivered("c")) stats.record(delivery.envelope)

        assertEquals(120, stats.received)
        assertEquals(120, stats.expected)
        assertEquals("B stored the beacons sent during the outage", 1.0, stats.deliveryRatio!!, 0.0)
        assertEquals(1.0, stats.share(listOf("b"))!!, 0.0)
        assertEquals(0, stats.duplicates)
        assertEquals(0, stats.medianAgeMs)
        assertEquals("the first beacon of the outage waited 10 s at B", 10_000, stats.agesMs.maxOrNull())
    }

    @Test
    fun testBeaconStatsCountsGapsRoutesAndAges() {
        fun beacon(seq: Int, path: List<String>, ageMs: Int, run: String = "r", origin: String = "a"): RelayEnvelope =
            RelayEnvelope(
                originId = origin, kind = BeaconPayload.kind, body = BeaconPayload(run = run, seq = seq).body,
                ageMs = ageMs, ttlMs = 30_000, hopsRemaining = 1, path = path,
            )
        val stats = BeaconStats(originId = "a", run = "r")
        assertNull(stats.deliveryRatio)
        assertNull(stats.medianAgeMs)
        for (seq in listOf(3, 4, 6, 7)) assertTrue(stats.record(beacon(seq, path = listOf("b"), ageMs = seq * 100)))
        assertTrue(stats.record(beacon(8, path = emptyList(), ageMs = 2_000)))
        assertTrue(stats.record(beacon(4, path = listOf("b"), ageMs = 9)))
        assertFalse(stats.record(beacon(9, path = emptyList(), ageMs = 0, run = "other")))
        assertFalse(stats.record(beacon(9, path = emptyList(), ageMs = 0, origin = "z")))

        assertEquals(5, stats.received)
        assertEquals(6, stats.expected)
        assertEquals(5.0 / 6.0, stats.deliveryRatio!!, 1e-9)
        assertEquals(1, stats.duplicates)
        assertEquals(0.8, stats.share(listOf("b"))!!, 1e-9)
        assertEquals(mapOf("b" to 4, "" to 1), stats.routes)
        assertEquals(600, stats.medianAgeMs)
        assertEquals(2_000, stats.ageMs(percentile = 100.0))
        assertEquals(300, stats.ageMs(percentile = 0.0))
    }

    // MARK: Reconnect backoff

    @Test
    fun testReconnectBackoffSchedule() {
        val delays = (1..7).map { ReconnectBackoff.delay(afterFailures = it, jitter = 0.0) }
        assertEquals(listOf(5.0, 10.0, 20.0, 40.0, 60.0, 60.0, 60.0), delays)
        assertEquals(5.0, ReconnectBackoff.delay(afterFailures = 0, jitter = 0.0), 0.0)
        assertEquals(60.0, ReconnectBackoff.delay(afterFailures = 10_000, jitter = 0.0), 0.0)
        assertEquals(6.5, ReconnectBackoff.delay(afterFailures = 1, jitter = 1.5), 0.0)
        assertEquals("jitter is capped", 7.0, ReconnectBackoff.delay(afterFailures = 1, jitter = 99.0), 0.0)
        repeat(100) {
            assertTrue(ReconnectBackoff.delay(afterFailures = 1) in 5.0..7.0)
        }
    }

    // MARK: Peer sightings

    @Test
    fun testSightingCarriesRawSamplesSinceThePreviousSnapshot() {
        val statistics = RSSIStatistics()
        val start = 1_800_000_000.0
        assertNull(
            PeerSighting.take(
                from = statistics, observerId = "a", peerId = "b", transportHandle = null,
                channel = PeerSighting.Channel.connection, linkState = PeerSighting.LinkState.ready, now = start,
            ),
        )
        statistics.record(-60, now = start)
        statistics.record(127, now = start + 0.5)
        statistics.record(-64, now = start + 1)

        val first = PeerSighting.take(
            from = statistics, observerId = "a", peerId = "b", transportHandle = null,
            channel = PeerSighting.Channel.connection, linkState = PeerSighting.LinkState.ready, now = start + 1,
        )!!
        assertEquals(listOf(RSSISample(rssi = -60, at = start), RSSISample(rssi = -64, at = start + 1)), first.samples)
        assertEquals(0, first.droppedSamples)
        assertEquals("127 means unavailable and is not a sample", 2, first.sampleCount)
        assertEquals("b", first.peerId)
        assertEquals(start + 1, first.lastSampleAt!!, 0.0)
        assertEquals(2.0, first.sampleAge(now = start + 3)!!, 1e-9)
        assertNotNull(first.smoothedRSSI)
        assertNotNull(first.rssiStandardDeviation)

        val second = PeerSighting.take(
            from = statistics, observerId = "a", peerId = "b", transportHandle = null,
            channel = PeerSighting.Channel.connection, linkState = PeerSighting.LinkState.ready, now = start + 2,
        )!!
        assertTrue("each raw sample is reported once", second.samples.isEmpty())
        assertEquals(first.smoothedRSSI, second.smoothedRSSI)
        assertEquals(2, second.sampleCount)
    }

    @Test
    fun testSightingKeepsTheNewestSixteenSamples() {
        val statistics = RSSIStatistics()
        val start = 1_800_000_000.0
        for (index in 0 until 20) statistics.record(-50 - index, now = start + index)
        val sighting = PeerSighting.take(
            from = statistics, observerId = "a", peerId = null, transportHandle = newUUID(),
            channel = PeerSighting.Channel.advertisement, linkState = PeerSighting.LinkState.advertised, now = start,
        )!!
        assertEquals(RSSIStatistics.maxRecentSamples, sighting.samples.size)
        assertEquals(4, sighting.droppedSamples)
        assertEquals(-54, sighting.samples.first().rssi)
        assertEquals(-69, sighting.samples.last().rssi)
        assertNull(sighting.peerId)
        assertEquals(0, statistics.droppedRecentSamples)
    }
}
