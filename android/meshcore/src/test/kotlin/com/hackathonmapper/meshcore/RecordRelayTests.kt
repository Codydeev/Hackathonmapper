package com.hackathonmapper.meshcore

import java.io.File
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Phones running `RecordRelay`, joined by links that come and go. Frames take the real wire path:
 * JSON, `Framing` and `FrameAssembler`.
 */
private class RecordMesh(ids: List<String>) {
    private class Queued(val from: String, val to: String, val framed: ByteArray)

    var now: TimeInterval = 5_000.0
    val relays = HashMap<String, RecordRelay>()
    private val received = HashMap<String, MutableList<ReceivedRecord>>()
    var droppableSends = 0
        private set
    private val links = HashSet<String>()
    private val queue = ArrayDeque<Queued>()

    init {
        for (id in ids) relays[id] = RecordRelay(selfId = id)
    }

    operator fun get(id: String): RecordRelay = relays[id]!!

    fun records(id: String): List<RelayMessage> = (received[id] ?: emptyList()).map { it.message }

    fun link(a: String, b: String) {
        links.add(key(a, b))
        handle(a, this[a].neighborReady(b, now = now))
        handle(b, this[b].neighborReady(a, now = now))
        run()
    }

    fun unlink(a: String, b: String) {
        links.remove(key(a, b))
        this[a].neighborLost(b)
        this[b].neighborLost(a)
        queue.removeAll { key(it.from, it.to) == key(a, b) }
    }

    fun publish(message: RelayMessage) {
        handle(message.originId, this[message.originId].publish(message, now = now))
        run()
    }

    fun advance(seconds: Int) {
        repeat(seconds) {
            now += 1
            for (relay in relays.values) relay.tick(now = now)
        }
    }

    private fun run() {
        while (queue.isNotEmpty()) {
            val item = queue.removeFirst()
            if (!links.contains(key(item.from, item.to))) continue
            val assembler = FrameAssembler()
            for (start in 0 until item.framed.size step 182) {
                val chunk = item.framed.copyOfRange(start, minOf(start + 182, item.framed.size))
                for (frame in assembler.append(chunk, now = now)) {
                    handle(item.to, this[item.to].receive(frame, from = item.from, now = now, wallClock = 1_793_000_000 + now))
                }
            }
        }
    }

    private fun handle(id: String, actions: List<RecordAction>) {
        for (action in actions) {
            when (action) {
                is RecordAction.send -> {
                    if (action.droppable) droppableSends += 1
                    if (!links.contains(key(id, action.to))) continue
                    queue.addLast(Queued(id, action.to, Framing.encode(action.message.encoded(), FrameType.record)!!))
                }
                is RecordAction.deliver -> received.getOrPut(id) { mutableListOf() }.add(action.record)
            }
        }
    }

    private fun key(a: String, b: String): String = if (a < b) "$a|$b" else "$b|$a"
}

/** Port of ios/MeshCore/Tests/MeshCoreTests/RecordRelayTests.swift. */
class RecordRelayTests {
    private val frame = "hervanta-v1"
    private val epoch = "2B7F0E64-5C1D-4E8B-A6F2-7D3C9B1E0A55"
    private val nextEpoch = "9A1C3E5F-7B2D-4F60-8E14-A3C5E7092B4D"

    private fun position(origin: String, x: Double, age: Double = 0.0, maxAge: Double = 30.0): RelayMessage.Payload =
        RelayMessage.Payload.position(
            PositionEstimate(
                subjectId = origin, timestamp = 1_793_000_000.0, frameId = frame, kind = PositionEstimate.Kind.declared,
                method = PositionEstimate.Method.manual, position = Position(x = x, y = 0.0, z = 0.0),
                uncertainty = PositionUncertainty(r95 = 2.0), source = EvidenceSource.manual,
                freshness = Freshness(ageAtHandoff = age, maxAge = maxAge),
                provenance = Provenance(producerId = origin, algorithm = "manual@1", gnssDependent = false),
            ),
        )

    private fun observations(origin: String, peer: String): RelayMessage.Payload =
        RelayMessage.Payload.observations(
            listOf(
                PeerObservation(
                    observerId = origin, peerId = peer, timestamp = 1_793_000_000.0, frameId = frame,
                    channel = PeerObservation.Channel.connection, linkState = PeerObservation.LinkState.ready,
                    rawRSSI = listOf(-70.0, -72.0), window = 1.0, smoothedRSSI = -71.0,
                    uncertainty = PeerObservation.Uncertainty(stdDevDb = 1.0, sampleCount = 2),
                    freshness = Freshness(maxAge = 6.0),
                    provenance = Provenance(producerId = origin, algorithm = PeerSighting.algorithm, gnssDependent = false),
                ),
            ),
        )

    private fun message(
        origin: String,
        sequence: Long,
        epoch: String? = null,
        x: Double = 1.0,
        hops: Int = 4,
        age: Double = 0.0,
        maxAge: Double = 30.0,
        payload: RelayMessage.Payload? = null,
    ): RelayMessage = RelayMessage(
        originId = origin, epochId = epoch ?: this.epoch, sequence = sequence, timestamp = 1_793_000_000.0,
        frameId = frame, hopsRemaining = hops, freshness = Freshness(ageAtHandoff = age, maxAge = maxAge),
        payload = payload ?: position(origin, x = x, age = age, maxAge = maxAge),
    )

    private val fixtures = File(System.getProperty("repo.root"), "contract/fixtures")

    private fun assertThrows(body: () -> Unit) {
        try {
            body()
        } catch (e: Exception) {
            return
        }
        fail("expected an error")
    }

    // MARK: Relaying

    @Test
    fun testStateRecordCrossesTheChainWithItsIdentity() {
        val mesh = RecordMesh(listOf("a", "b", "c"))
        mesh.link("a", "b")
        mesh.link("b", "c")
        val sent = message("a", sequence = 1)
        mesh.publish(sent)

        val atC = mesh.records("c").first()
        assertEquals(1, mesh.records("c").size)
        assertEquals(sent.messageId, atC.messageId)
        assertEquals("a", atC.originId)
        assertEquals(sent.epochId, atC.epochId)
        assertEquals(1L, atC.sequence)
        assertEquals(sent.payload, atC.payload)
        assertEquals(listOf("b"), atC.path)
        assertEquals(3, atC.hopsRemaining)
        assertEquals(0.0, atC.freshness.ageAtHandoff, 0.0)
        assertEquals("relays deliver to their own pipeline too", listOf(sent.messageId), mesh.records("b").map { it.messageId })
        assertTrue(mesh.records("a").isEmpty())
        assertEquals(sent.messageId, mesh["c"].latest(from = "a", type = "position")?.messageId)
    }

    @Test
    fun testOlderSequencesAndRetiredEpochsAreIgnored() {
        val relay = RecordRelay(selfId = "b")
        fun accept(message: RelayMessage): Boolean =
            relay.receive(message, from = "a", now = 1.0, wallClock = 1.0).any { it is RecordAction.deliver }
        assertTrue(accept(message("a", sequence = 5)))
        assertFalse(accept(message("a", sequence = 4)))
        assertFalse("same sequence, new message ID", accept(message("a", sequence = 5)))
        assertTrue("a restart starts a new epoch", accept(message("a", sequence = 1, epoch = nextEpoch)))
        assertFalse("the old epoch is retired", accept(message("a", sequence = 9, epoch = epoch)))
        assertTrue(accept(message("a", sequence = 2, epoch = nextEpoch)))
        assertEquals(3, relay.statistics.outOfOrder)
        assertEquals(2L, relay.latest(from = "a", type = "position")?.sequence)
    }

    @Test
    fun testEachPayloadTypeHasItsOwnOrder() {
        val relay = RecordRelay(selfId = "b")
        relay.receive(message("a", sequence = 7), from = "a", now = 1.0, wallClock = 1.0)
        val batch = message("a", sequence = 3, payload = observations("a", peer = "c"))
        assertEquals(
            "observations are not ordered against positions",
            1, relay.receive(batch, from = "a", now = 1.0, wallClock = 1.0).size,
        )
        assertEquals("observation batches are never stored", 1, relay.storedCount)
    }

    @Test
    fun testPhoneThatLinksLaterGetsTheLatestRecordWithItsHoldTime() {
        val mesh = RecordMesh(listOf("a", "b", "c"))
        mesh.link("a", "b")
        mesh.publish(message("a", sequence = 1, x = 1.0))
        val newest = message("a", sequence = 2, x = 2.0)
        mesh.publish(newest)
        mesh.unlink("a", "b")
        mesh.advance(10)
        mesh.link("b", "c")

        assertEquals("only the latest state is handed on", listOf(2L), mesh.records("c").map { it.sequence })
        val atC = mesh.records("c").first()
        assertEquals(newest.messageId, atC.messageId)
        assertEquals(listOf("b"), atC.path)
        assertEquals("B's hold time is added", 10.0, atC.freshness.ageAtHandoff, 1e-9)
        assertEquals(30.0, atC.freshness.maxAge, 0.0)
    }

    @Test
    fun testOriginHandsItsOwnStoredRecordToALateNeighbor() {
        val mesh = RecordMesh(listOf("a", "b"))
        val sent = message("a", sequence = 1)
        mesh.publish(sent)
        mesh.advance(4)
        mesh.link("a", "b")
        val atB = mesh.records("b").first()
        assertEquals(sent.messageId, atB.messageId)
        assertEquals(emptyList<String>(), atB.path)
        assertEquals(sent.hopsRemaining, atB.hopsRemaining)
        assertEquals(4.0, atB.freshness.ageAtHandoff, 1e-9)
    }

    @Test
    fun testStaleRecordsAreNeitherAcceptedNorHandedOn() {
        val mesh = RecordMesh(listOf("a", "b", "c"))
        mesh.link("a", "b")
        mesh.publish(message("a", sequence = 1, maxAge = 5.0))
        mesh.unlink("a", "b")
        mesh.advance(6)
        assertEquals(0, mesh["b"].storedCount)
        assertEquals(1, mesh["b"].statistics.expired)
        mesh.link("b", "c")
        assertTrue(mesh.records("c").isEmpty())

        val relay = RecordRelay(selfId = "b")
        assertTrue(relay.receive(message("a", sequence = 1, age = 31.0, maxAge = 30.0), from = "a", now = 0.0, wallClock = 0.0).isEmpty())
        assertEquals(1, relay.statistics.stale)
    }

    @Test
    fun testObservationBatchesAreForwardedOnceAndMayBeDropped() {
        // Diamond: D hears A's batch through B and C but delivers it once.
        val mesh = RecordMesh(listOf("a", "b", "c", "d"))
        mesh.link("a", "b")
        mesh.link("a", "c")
        mesh.link("b", "d")
        mesh.link("c", "d")
        val batch = message("a", sequence = 1, payload = observations("a", peer = "b"))
        mesh.publish(batch)
        assertEquals(listOf(batch.messageId), mesh.records("d").map { it.messageId })
        assertTrue(mesh["d"].statistics.duplicates >= 1)
        assertEquals(0, mesh["d"].storedCount)
        assertTrue(mesh.droppableSends > 0)
    }

    @Test
    fun testLoopsAndOwnRecordsAreDropped() {
        val relay = RecordRelay(selfId = "b")
        val own = message("b", sequence = 1)
        assertTrue(relay.receive(own, from = "a", now = 0.0, wallClock = 0.0).isEmpty())
        val looped = RelayMessage(
            originId = "a", epochId = epoch, sequence = 1, timestamp = 1_793_000_000.0, frameId = frame,
            hopsRemaining = 3, path = listOf("b"), freshness = Freshness(maxAge = 30.0), payload = position("a", x = 1.0),
        )
        assertTrue(relay.receive(looped, from = "c", now = 0.0, wallClock = 0.0).isEmpty())
        assertEquals(2, relay.statistics.loops)
    }

    @Test
    fun testHopBudgetEndsForwarding() {
        val mesh = RecordMesh(listOf("a", "b", "c"))
        mesh.link("a", "b")
        mesh.link("b", "c")
        mesh.publish(message("a", sequence = 1, hops = 0))
        assertEquals(1, mesh.records("b").size)
        assertTrue(mesh.records("c").isEmpty())
    }

    @Test
    fun testPublishRefusesForeignOrReplayedRecords() {
        val relay = RecordRelay(selfId = "a")
        assertThrows { relay.publish(message("z", sequence = 1), now = 0.0) }
        relay.publish(message("a", sequence = 3), now = 0.0)
        assertThrows { relay.publish(message("a", sequence = 3), now = 0.0) }
        assertThrows { relay.publish(message("a", sequence = 2), now = 0.0) }
        relay.publish(message("a", sequence = 4), now = 0.0)
    }

    @Test
    fun testOutboxKeysCoalesceStateButNotEvents() {
        assertEquals(RecordRelay.outboxKey(message("a", sequence = 1)), RecordRelay.outboxKey(message("a", sequence = 2)))
        assertNotEquals(RecordRelay.outboxKey(message("a", sequence = 1)), RecordRelay.outboxKey(message("b", sequence = 1)))
        val first = message("a", sequence = 1, payload = observations("a", peer = "b"))
        val second = message("a", sequence = 2, payload = observations("a", peer = "b"))
        assertNotEquals(RecordRelay.outboxKey(first), RecordRelay.outboxKey(second))
    }

    @Test
    fun testGoldenRelayFixtureIsAcceptedAndRelayed() {
        val data = File(fixtures, "relay-integrity.json").readBytes()
        val golden = RelayMessage.decode(data)
        val relay = RecordRelay(selfId = "phone-d")
        relay.neighborReady("phone-b", now = 0.0)
        relay.neighborReady("phone-e", now = 0.0)
        val actions = relay.receive(Frame(FrameType.record, data), from = "phone-b", now = 0.0, wallClock = 1_793_001_643.0)

        val record = (actions.firstOrNull() as? RecordAction.deliver)?.record ?: return fail("not delivered")
        assertEquals(golden, record.message)
        assertEquals(2, record.hops)
        val sends = actions.filterIsInstance<RecordAction.send>()
        assertEquals("never back to where it came from", listOf("phone-e"), sends.map { it.to })
        val copy = sends.first().message
        assertEquals(golden.path + "phone-d", copy.path)
        assertEquals(golden.hopsRemaining - 1, copy.hopsRemaining)
        assertEquals(golden.freshness.ageAtHandoff, copy.freshness.ageAtHandoff, 0.0)
        assertEquals(golden.messageId, copy.messageId)
        copy.encoded()
    }

    // MARK: Peer observations

    @Test
    fun testSightingMapsOntoTheContract() {
        val statistics = RSSIStatistics()
        val start = 1_793_001_640.0
        statistics.record(-71, now = start)
        statistics.record(-74, now = start + 0.5)
        statistics.record(-69, now = start + 1)
        val sighting = PeerSighting.take(
            from = statistics, observerId = "phone-b", peerId = "phone-a", transportHandle = UUID.randomUUID().toString().uppercase(),
            channel = PeerSighting.Channel.connection, linkState = PeerSighting.LinkState.ready, txPower = -8, now = start + 1.25,
        )!!
        val observation = sighting.observation(frameId = frame, peerModel = "iPhone16,1")!!

        observation.validate()
        assertEquals("phone-b", observation.observerId)
        assertEquals("phone-a", observation.peerId)
        assertEquals("time of the newest sample", 1_793_001_641.0, observation.timestamp, 1e-6)
        assertEquals(PeerObservation.Channel.connection, observation.channel)
        assertEquals(PeerObservation.LinkState.ready, observation.linkState)
        assertEquals(listOf(-71.0, -74.0, -69.0), observation.rawRSSI)
        assertEquals(1.0, observation.window, 1e-9)
        assertEquals(3, observation.uncertainty.sampleCount)
        assertNotNull(observation.uncertainty.stdDevDb)
        assertEquals(-8, observation.txPower)
        assertEquals(EvidenceSource.bluetooth, observation.source)
        assertEquals(0.25, observation.freshness.ageAtHandoff, 1e-6)
        assertEquals(PeerSighting.observationMaxAge, observation.freshness.maxAge, 0.0)
        assertEquals("phone-b", observation.provenance.producerId)
        assertEquals("ble-sighting@1", observation.provenance.algorithm)
        assertFalse(observation.provenance.gnssDependent)
        assertFalse(observation.provenance.simulated)
    }

    @Test
    fun testSightingStatesAndEdgeCasesMapOntoTheContract() {
        val at = 1_793_001_640.0
        fun observation(state: PeerSighting.LinkState, peerId: String?, samples: Int): PeerObservation? {
            val statistics = RSSIStatistics()
            for (index in 0 until samples) statistics.record(-60 - index, now = at + index)
            statistics.takeRecentSamples()
            return PeerSighting.take(
                from = statistics, observerId = "phone-b", peerId = peerId, transportHandle = null,
                channel = PeerSighting.Channel.advertisement, linkState = state, now = at,
            )?.observation(frameId = frame)
        }
        assertEquals(PeerObservation.LinkState.advertisementOnly, observation(PeerSighting.LinkState.advertised, peerId = null, samples = 1)?.linkState)
        assertNull(observation(PeerSighting.LinkState.advertised, peerId = null, samples = 1)?.peerId)
        assertNull("no spread from one sample", observation(PeerSighting.LinkState.advertised, peerId = null, samples = 1)?.uncertainty?.stdDevDb)
        assertEquals(PeerObservation.LinkState.connecting, observation(PeerSighting.LinkState.linking, peerId = "phone-a", samples = 2)?.linkState)
        assertEquals(PeerObservation.LinkState.lost, observation(PeerSighting.LinkState.lost, peerId = "phone-a", samples = 2)?.linkState)
        val quiet = observation(PeerSighting.LinkState.ready, peerId = "phone-a", samples = 25)!!
        assertTrue("a snapshot with no new samples still reports the smoothed value", quiet.rawRSSI.isEmpty())
        assertEquals(RSSIStatistics.deviationWindow, quiet.uncertainty.sampleCount)
        assertNull("a peer can't be the observer", observation(PeerSighting.LinkState.ready, peerId = "phone-b", samples = 2))
        assertNull(observation(PeerSighting.LinkState.ready, peerId = "phone-a", samples = 0))
    }
}
