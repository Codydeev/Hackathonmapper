package com.hackathonmapper.meshcore

import kotlin.math.max

/** A contract `RelayMessage` this phone accepted, as handed to the pipeline. */
data class ReceivedRecord(
    /** The copy as it arrived; its `freshness.ageAtHandoff` includes every earlier hold. */
    val message: RelayMessage,
    val fromNeighbor: String,
    /** Unix seconds on this phone's clock. */
    val receivedAt: Double,
    /**
     * Local monotonic seconds. The record's age now is
     * `message.freshness.age(receivedAt = receivedAtMonotonic, now = <monotonic now>)`.
     */
    val receivedAtMonotonic: TimeInterval,
) {
    /** Links traversed: one more than the number of relays. */
    val hops: Int get() = message.path.size + 1
}

sealed class RecordAction {
    /**
     * Queue `message` for `to` under the outbox `key`; a newer message with the same key
     * replaces a queued one. `droppable` messages may be skipped when the link is backed up.
     */
    data class send(val message: RelayMessage, val to: String, val key: String, val droppable: Boolean) : RecordAction()
    data class deliver(val record: ReceivedRecord) : RecordAction()
}

data class RecordRelayStatistics(
    var published: Int = 0,
    var accepted: Int = 0,
    /** Copies handed to the transport. */
    var sent: Int = 0,
    var duplicates: Int = 0,
    /** Copies that already passed through this phone, including its own records coming back. */
    var loops: Int = 0,
    /** Older sequence than the latest accepted, or from a retired epoch. */
    var outOfOrder: Int = 0,
    /** Already older than `maxAge` on arrival. */
    var stale: Int = 0,
    /** Stored records dropped because they aged past `maxAge`. */
    var expired: Int = 0,
    var invalid: Int = 0,
)

/**
 * Carries GhostCore contract `RelayMessage`s (frame type 7) across the mesh.
 *
 * - Positions, assessments and predictions are state: only the latest per origin and payload type
 *   matters. They are ordered by epoch and sequence (a restart's new epoch retires the old one),
 *   stored, and handed to neighbors that link later, with the time held added to `freshness`.
 * - Observation batches are events: deduplicated by `messageId` and forwarded, never stored.
 * - Every accepted record is delivered to this phone's pipeline and forwarded with
 *   `RelayMessage.relayed(by:heldFor:)`, which refuses loops and spent hop budgets.
 *
 * `now` is local monotonic seconds. Not thread safe: use one instance from one thread.
 * `statistics` and `neighbors` return copies, like Swift value types.
 */
class RecordRelay(
    val selfId: String,
    configuration: Configuration = Configuration(),
) {
    /** A Swift struct: the relay keeps its own copy. */
    data class Configuration(
        var maxStreams: Int = 512,
        var maxSeen: Int = 4_096,
        var seenLifetime: TimeInterval = 10.0 * 60,
        /** Retired epochs remembered per origin. */
        var maxRetiredEpochs: Int = 100,
    )

    private data class Stream(val originId: String, val type: String)

    private class Latest(
        val message: RelayMessage,
        val receivedAt: TimeInterval,
        /** Neighbor it came from; this phone's ID for its own records. */
        val source: String,
    )

    val configuration: Configuration = configuration.copy()

    private var stats = RecordRelayStatistics()
    val statistics: RecordRelayStatistics get() = stats.copy()

    private val readyNeighbors = HashSet<String>()
    val neighbors: Set<String> get() = readyNeighbors.toSet()

    // Insertion ordered, so ties in `receivedAt` resolve the same way on every run.
    private val latest = LinkedHashMap<Stream, Latest>()
    private val currentEpoch = HashMap<String, String>()
    private val retiredEpochs = HashMap<String, MutableList<String>>()
    private val seen = HashMap<String, TimeInterval>()
    private val seenOrder = ArrayDeque<String>()

    val storedCount: Int get() = latest.size

    /** The stored latest record of `type` ("position", "integrity", "prediction") from `originId`. */
    fun latest(from: String, type: String): RelayMessage? = latest[Stream(from, type)]?.message

    companion object {
        fun payloadType(payload: RelayMessage.Payload): String = when (payload) {
            is RelayMessage.Payload.position -> "position"
            is RelayMessage.Payload.integrity -> "integrity"
            is RelayMessage.Payload.prediction -> "prediction"
            is RelayMessage.Payload.observations -> "observations"
        }

        /** Outbox key: one queued message per origin and type, so a slow link sends only the newest. */
        fun outboxKey(message: RelayMessage): String {
            val type = payloadType(message.payload)
            if (type != "observations") return "record:${message.originId}:$type"
            return "record:${message.originId}:observations:${message.messageId}"
        }
    }

    // MARK: Events

    /** Sends one of this phone's records, built by the pipeline, to every ready neighbor. */
    fun publish(message: RelayMessage, now: TimeInterval): List<RecordAction> {
        if (!(message.originId == selfId && message.path.isEmpty())) throw GhostCoreContractError.invalid("originId")
        message.encoded()
        if (seen[message.messageId] != null) return emptyList()
        remember(message.messageId, now)
        stats.published += 1
        if (isState(message)) {
            val stream = Stream(selfId, payloadType(message.payload))
            val previous = latest[stream]
            if (previous != null && previous.message.epochId == message.epochId &&
                previous.message.sequence >= message.sequence
            ) {
                throw GhostCoreContractError.invalid("sequence")
            }
            store(message, stream, now, selfId)
        }
        return readyNeighbors.sorted().map { send(message, it) }
    }

    fun receive(frame: Frame, from: String, now: TimeInterval, wallClock: Double): List<RecordAction> {
        if (frame.type != FrameType.record) return emptyList()
        val message = try {
            RelayMessage.decode(frame.payload)
        } catch (e: Exception) {
            null
        }
        if (message == null) {
            stats.invalid += 1
            return emptyList()
        }
        return receive(message, from, now, wallClock)
    }

    fun receive(message: RelayMessage, from: String, now: TimeInterval, wallClock: Double): List<RecordAction> {
        val neighbor = from
        try {
            message.validate()
        } catch (e: Exception) {
            stats.invalid += 1
            return emptyList()
        }
        if (message.originId == selfId || message.path.contains(selfId)) {
            stats.loops += 1
            return emptyList()
        }
        if (seen[message.messageId] != null) {
            stats.duplicates += 1
            return emptyList()
        }
        remember(message.messageId, now)
        if (!(message.freshness.ageAtHandoff <= message.freshness.maxAge)) {
            stats.stale += 1
            return emptyList()
        }
        if (isState(message)) {
            if (!acceptsOrder(message)) {
                stats.outOfOrder += 1
                return emptyList()
            }
            store(message, Stream(message.originId, payloadType(message.payload)), now, neighbor)
        }
        stats.accepted += 1
        val actions = mutableListOf<RecordAction>(
            RecordAction.deliver(
                ReceivedRecord(message = message, fromNeighbor = neighbor, receivedAt = wallClock, receivedAtMonotonic = now),
            ),
        )
        val copy = message.relayed(selfId, 0.0)
        if (copy != null) {
            for (target in readyNeighbors.sorted()) {
                if (target == neighbor || target == message.originId || message.path.contains(target)) continue
                stats.sent += 1
                actions.add(RecordAction.send(copy, to = target, key = outboxKey(copy), droppable = !isState(copy)))
            }
        }
        return actions
    }

    /** A neighbor gained a ready link: hand it every stored record it may not have. */
    fun neighborReady(neighbor: String, now: TimeInterval): List<RecordAction> {
        readyNeighbors.add(neighbor)
        val actions = mutableListOf<RecordAction>()
        for (entry in latest.values.sortedBy { it.receivedAt }) {
            val message = entry.message
            if (entry.source == neighbor || message.originId == neighbor || message.path.contains(neighbor) ||
                message.freshness.isStale(receivedAt = entry.receivedAt, now = now)
            ) {
                continue
            }
            val held = max(0.0, now - entry.receivedAt)
            val copy: RelayMessage? = if (message.originId == selfId) {
                RelayMessage(
                    messageId = message.messageId, originId = message.originId, epochId = message.epochId,
                    sequence = message.sequence, timestamp = message.timestamp, frameId = message.frameId,
                    hopsRemaining = message.hopsRemaining, path = message.path,
                    freshness = message.freshness.handedOn(heldFor = held), payload = message.payload,
                )
            } else {
                message.relayed(selfId, held)
            }
            if (copy == null) continue
            stats.sent += 1
            actions.add(RecordAction.send(copy, to = neighbor, key = outboxKey(copy), droppable = false))
        }
        return actions
    }

    fun neighborLost(neighbor: String) {
        readyNeighbors.remove(neighbor)
    }

    /** Drops stored records past their `maxAge` and old message IDs. Call about once per second. */
    fun tick(now: TimeInterval) {
        val iterator = latest.values.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            if (entry.message.freshness.isStale(receivedAt = entry.receivedAt, now = now)) {
                iterator.remove()
                stats.expired += 1
            }
        }
        val cutoff = now - configuration.seenLifetime
        while (seenOrder.isNotEmpty()) {
            val firstSeen = seen[seenOrder.first()] ?: break
            if (!(firstSeen < cutoff)) break
            seen.remove(seenOrder.removeFirst())
        }
    }

    fun reset() {
        stats = RecordRelayStatistics()
        readyNeighbors.clear()
        latest.clear()
        currentEpoch.clear()
        retiredEpochs.clear()
        seen.clear()
        seenOrder.clear()
    }

    // MARK: Internals

    private fun isState(message: RelayMessage): Boolean = message.payload !is RelayMessage.Payload.observations

    private fun send(message: RelayMessage, neighbor: String): RecordAction {
        stats.sent += 1
        return RecordAction.send(message, to = neighbor, key = outboxKey(message), droppable = !isState(message))
    }

    /**
     * Same epoch: only a higher sequence. A new epoch retires the origin's previous one, whose
     * records are dropped; a retired epoch is never accepted again.
     */
    private fun acceptsOrder(message: RelayMessage): Boolean {
        val origin = message.originId
        if (retiredEpochs[origin]?.contains(message.epochId) == true) return false
        val current = currentEpoch[origin] ?: return true
        if (current == message.epochId) {
            val stream = Stream(origin, payloadType(message.payload))
            return latest[stream]?.let { message.sequence > it.message.sequence } ?: true
        }
        return true
    }

    private fun store(message: RelayMessage, stream: Stream, receivedAt: TimeInterval, source: String) {
        val origin = message.originId
        val current = currentEpoch[origin]
        if (current != null && current != message.epochId) {
            val retired = retiredEpochs.getOrPut(origin) { mutableListOf() }
            retired.add(current)
            if (retired.size > configuration.maxRetiredEpochs) retired.removeAt(0)
            latest.keys.removeAll { it.originId == origin }
        }
        currentEpoch[origin] = message.epochId
        if (latest[stream] == null && latest.size >= configuration.maxStreams) {
            val oldest = latest.entries.minByOrNull { it.value.receivedAt }
            if (oldest != null) latest.remove(oldest.key)
        }
        latest[stream] = Latest(message, receivedAt, source)
    }

    private fun remember(id: String, now: TimeInterval) {
        if (seen[id] != null) return
        if (seenOrder.size >= configuration.maxSeen) {
            seen.remove(seenOrder.removeFirst())
        }
        seen[id] = now
        seenOrder.addLast(id)
    }
}
