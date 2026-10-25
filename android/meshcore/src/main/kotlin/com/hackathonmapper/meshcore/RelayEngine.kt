package com.hackathonmapper.meshcore

import kotlin.math.max

/** What the transport must do after the engine handled an event. */
sealed class RelayAction {
    data class send(val envelope: RelayEnvelope, val to: String) : RelayAction()
    data class sendSummary(val summary: RelaySummary, val to: String) : RelayAction()
    /** A message for this phone: addressed to it, or a broadcast. */
    data class deliver(val delivery: RelayDelivery) : RelayAction()
}

data class RelayDelivery(
    val envelope: RelayEnvelope,
    /** Neighbor the accepted copy arrived from. */
    val fromNeighbor: String,
    /** Local monotonic time of arrival, in seconds. */
    val receivedAt: TimeInterval,
) {
    /** Links traversed: one more than the number of relays. */
    val hops: Int get() = envelope.path.size + 1
}

data class RelayStatistics(
    var originated: Int = 0,
    /** New messages accepted from neighbors. */
    var accepted: Int = 0,
    var delivered: Int = 0,
    /** Copies handed to the transport. */
    var sent: Int = 0,
    var duplicates: Int = 0,
    /** Copies that already passed through this phone, including its own messages coming back. */
    var loops: Int = 0,
    var expired: Int = 0,
    /** Accepted but not stored for forwarding because no hops remained. */
    var hopLimited: Int = 0,
    var invalid: Int = 0,
    /** Stored messages dropped to make room. */
    var evicted: Int = 0,
    /** Stored messages dropped because a receipt confirmed their delivery. */
    var cleared: Int = 0,
)

/**
 * Store-and-forward relay for `RelayEnvelope`s: epidemic routing with summary vectors, bounded
 * by hop count, TTL and storage.
 *
 * - A new message goes to every relay-capable neighbor except those it came through.
 * - Messages with hops and TTL left stay stored. When a link becomes ready both sides send a
 *   `RelaySummary`, and each answers with the stored messages the other lacks. Summaries repeat
 *   every `summaryInterval`, which repairs copies lost on a link that dropped mid-transfer.
 * - Message IDs are remembered for longer than any TTL, so every phone delivers a message once.
 * - The destination of a unicast message answers with a receipt; phones that relay or receive
 *   the receipt drop their stored copy.
 *
 * `now` is local monotonic time in seconds; it must not jump with the wall clock. Not thread
 * safe: use one instance from one thread.
 *
 * Message IDs are UUID strings, compared case-insensitively (keys are uppercased) like Swift's `UUID`.
 * `statistics`, `neighbors` and `relayCapable` return copies, like Swift value types.
 */
class RelayEngine(
    val selfId: String,
    configuration: Configuration = Configuration(),
) {
    /** A Swift struct: the engine keeps its own copy. */
    data class Configuration(
        var maxStored: Int = 256,
        var maxSeen: Int = 4_096,
        /** Longer than the largest TTL, so a late copy of a live message is still recognized. */
        var seenLifetime: TimeInterval = 20.0 * 60,
        var summaryInterval: TimeInterval = 10.0,
        /**
         * A copy sent to a neighbor this recently may still be in flight, so a summary that lacks
         * it does not trigger a resend.
         */
        var resendGuard: TimeInterval = 5.0,
        var defaultTTLMs: Int = 10 * 60_000,
        var defaultHops: Int = 6,
        var sendsReceipts: Boolean = true,
    )

    private class Stored(
        /** The copy as accepted (or created), before this phone's forwarding changes. */
        val envelope: RelayEnvelope,
        val receivedAt: TimeInterval,
        /**
         * Phones known to have the message: where it came from, its origin and relays, and
         * neighbors whose summary listed it.
         */
        val knownBy: MutableSet<String>,
        val sentTo: MutableMap<String, TimeInterval> = HashMap(),
    )

    val configuration: Configuration = configuration.copy()

    private var stats = RelayStatistics()
    val statistics: RelayStatistics get() = stats.copy()

    private val readyNeighbors = HashSet<String>()
    /** Ready neighbors, as reported by the transport. */
    val neighbors: Set<String> get() = readyNeighbors.toSet()

    private val capable = HashSet<String>()
    /** Neighbors that sent a relay frame, so they run the relay. Others never get envelopes. */
    val relayCapable: Set<String> get() = capable.toSet()

    // Insertion ordered, so ties in `receivedAt` resolve the same way on every run.
    private val stored = LinkedHashMap<String, Stored>()
    private val seen = HashMap<String, TimeInterval>()
    private val seenOrder = ArrayDeque<String>()
    private val lastSummary = HashMap<String, TimeInterval>()

    val storedCount: Int get() = stored.size
    fun isStored(messageId: String): Boolean = stored[key(messageId)] != null
    fun hasSeen(messageId: String): Boolean = seen[key(messageId)] != null

    // MARK: Origination

    /**
     * Creates a message from this phone and sends it to every relay-capable neighbor. Kept for
     * neighbors that appear later, until its TTL runs out or a receipt confirms delivery.
     * Swift returns the tuple `(RelayEnvelope, [RelayAction])`.
     */
    fun originate(
        kind: String,
        body: String,
        to: String? = null,
        ttlMs: Int? = null,
        hops: Int? = null,
        acknowledges: String? = null,
        now: TimeInterval,
        wallClock: Double = currentTime(),
    ): Pair<RelayEnvelope, List<RelayAction>> {
        val envelope = RelayEnvelope(
            originId = selfId,
            destinationId = to,
            kind = kind,
            body = body,
            createdAt = swiftRounded(wallClock * 1000),
            ttlMs = ttlMs ?: configuration.defaultTTLMs,
            hopsRemaining = hops ?: configuration.defaultHops,
            acknowledges = acknowledges,
        )
        envelope.encoded()
        remember(envelope.messageId, now)
        stats.originated += 1
        val actions = mutableListOf<RelayAction>()
        store(Stored(envelope, now, hashSetOf(selfId)), actions, now)
        return Pair(envelope, actions)
    }

    // MARK: Receiving

    /** Handles a relay frame from a ready neighbor. Other frame types are ignored. */
    fun receive(frame: Frame, from: String, now: TimeInterval): List<RelayAction> = when (frame.type) {
        FrameType.relayMessage -> {
            val envelope = try {
                RelayEnvelope.decode(frame.payload)
            } catch (e: Exception) {
                null
            }
            if (envelope == null) {
                stats.invalid += 1
                emptyList()
            } else {
                receive(envelope, from, now)
            }
        }
        FrameType.relaySummary -> {
            val summary = try {
                RelaySummary.decode(frame.payload)
            } catch (e: Exception) {
                null
            }
            if (summary == null) {
                stats.invalid += 1
                emptyList()
            } else {
                receive(summary, from, now)
            }
        }
        else -> emptyList()
    }

    fun receive(envelope: RelayEnvelope, from: String, now: TimeInterval): List<RelayAction> {
        val neighbor = from
        try {
            envelope.validate()
        } catch (e: Exception) {
            stats.invalid += 1
            return emptyList()
        }
        capable.add(neighbor)
        val id = key(envelope.messageId)
        if (envelope.originId == selfId || envelope.path.contains(selfId)) {
            stats.loops += 1
            stored[id]?.knownBy?.add(neighbor)
            return emptyList()
        }
        if (seen[id] != null) {
            stats.duplicates += 1
            stored[id]?.knownBy?.add(neighbor)
            return emptyList()
        }
        remember(id, now)
        if (envelope.isExpired) {
            stats.expired += 1
            return emptyList()
        }
        stats.accepted += 1

        val actions = mutableListOf<RelayAction>()
        val confirmed = envelope.acknowledges
        if (envelope.isReceipt && confirmed != null) {
            // Delivered: stop carrying the message, and don't accept a late copy of it.
            if (stored.remove(key(confirmed)) != null) stats.cleared += 1
            remember(confirmed, now)
        }
        val isForMe = envelope.destinationId == selfId
        if (isForMe || envelope.destinationId == null) {
            stats.delivered += 1
            actions.add(RelayAction.deliver(RelayDelivery(envelope = envelope, fromNeighbor = neighbor, receivedAt = now)))
        }
        if (isForMe) {
            if (configuration.sendsReceipts && !envelope.isReceipt) {
                val info = RelayReceiptInfo(path = envelope.path, ageMs = envelope.ageMs)
                val receipt = try {
                    originate(
                        kind = RelayEnvelope.receiptKind, body = info.encodedBody(), to = envelope.originId,
                        ttlMs = envelope.ttlMs, acknowledges = id, now = now,
                    )
                } catch (e: Exception) {
                    null
                }
                if (receipt != null) actions += receipt.second
            }
            return actions
        }
        if (envelope.hopsRemaining <= 0) {
            stats.hopLimited += 1
            return actions
        }
        val known = (envelope.path + listOf(envelope.originId, neighbor)).toHashSet()
        store(Stored(envelope, now, known), actions, now)
        return actions
    }

    /** Answers a neighbor's summary with the stored messages it lacks. */
    fun receive(summary: RelaySummary, from: String, now: TimeInterval): List<RelayAction> {
        val neighbor = from
        try {
            summary.validate()
        } catch (e: Exception) {
            stats.invalid += 1
            return emptyList()
        }
        capable.add(neighbor)
        val has = summary.have.map { key(it) }.toHashSet()
        val actions = mutableListOf<RelayAction>()
        for (id in storedIdsOldestFirst()) {
            val entry = stored[id] ?: continue
            if (has.contains(id)) {
                entry.knownBy.add(neighbor)
                continue
            }
            if (entry.knownBy.contains(neighbor)) continue
            val sentAt = entry.sentTo[neighbor]
            if (sentAt != null && now - sentAt < configuration.resendGuard) continue
            val copy = outgoingCopy(entry, now) ?: continue
            entry.sentTo[neighbor] = now
            stats.sent += 1
            actions.add(RelayAction.send(copy, to = neighbor))
        }
        return actions
    }

    // MARK: Topology and time

    /** A neighbor gained a ready link. Starts the summary exchange. */
    fun neighborReady(neighbor: String, now: TimeInterval): List<RelayAction> {
        readyNeighbors.add(neighbor)
        lastSummary[neighbor] = now
        return listOf(RelayAction.sendSummary(summary(), to = neighbor))
    }

    fun neighborLost(neighbor: String) {
        readyNeighbors.remove(neighbor)
        capable.remove(neighbor)
        lastSummary.remove(neighbor)
    }

    /** Drops expired messages and old IDs, and repeats summaries. Call about once per second. */
    fun tick(now: TimeInterval): List<RelayAction> {
        val iterator = stored.values.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            if (outgoingAgeMs(entry, now) >= entry.envelope.ttlMs) {
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

        val actions = mutableListOf<RelayAction>()
        for (neighbor in readyNeighbors.sorted()) {
            if (now - (lastSummary[neighbor] ?: Double.NEGATIVE_INFINITY) >= configuration.summaryInterval) {
                lastSummary[neighbor] = now
                actions.add(RelayAction.sendSummary(summary(), to = neighbor))
            }
        }
        return actions
    }

    /** The most recently seen message IDs, newest first. */
    fun summary(): RelaySummary = RelaySummary(have = seenOrder.takeLast(RelaySummary.maxIds).reversed())

    fun reset() {
        stats = RelayStatistics()
        readyNeighbors.clear()
        capable.clear()
        stored.clear()
        seen.clear()
        seenOrder.clear()
        lastSummary.clear()
    }

    // MARK: Internals

    private fun key(messageId: String): String = messageId.uppercase()

    private fun store(entry: Stored, actions: MutableList<RelayAction>, now: TimeInterval) {
        for (neighbor in capable.intersect(readyNeighbors).sorted()) {
            if (entry.knownBy.contains(neighbor)) continue
            val copy = outgoingCopy(entry, now) ?: break
            entry.sentTo[neighbor] = now
            stats.sent += 1
            actions.add(RelayAction.send(copy, to = neighbor))
        }
        if (stored.size >= configuration.maxStored) {
            // Make room by dropping the message closest to expiry.
            val victim = stored.entries.minByOrNull { remainingMs(it.value, now) }
            if (victim != null) {
                stored.remove(victim.key)
                stats.evicted += 1
            }
        }
        stored[key(entry.envelope.messageId)] = entry
    }

    /** Age a copy sent now would carry: the age on arrival plus the time held here. */
    private fun outgoingAgeMs(entry: Stored, now: TimeInterval): Int =
        entry.envelope.ageMs + swiftRounded(max(0.0, now - entry.receivedAt) * 1000).toInt()

    private fun remainingMs(entry: Stored, now: TimeInterval): Int =
        entry.envelope.ttlMs - outgoingAgeMs(entry, now)

    private fun outgoingCopy(entry: Stored, now: TimeInterval): RelayEnvelope? {
        val envelope = entry.envelope
        val age = outgoingAgeMs(entry, now)
        if (age >= envelope.ttlMs) return null
        if (envelope.originId == selfId) {
            return envelope.copy(ageMs = age, hopsRemaining = envelope.hopsRemaining, path = envelope.path)
        }
        return envelope.relayed(selfId, age - envelope.ageMs)
    }

    private fun storedIdsOldestFirst(): List<String> =
        stored.entries.sortedBy { it.value.receivedAt }.map { it.key }

    private fun remember(messageId: String, now: TimeInterval) {
        val id = key(messageId)
        if (seen[id] != null) return
        if (seenOrder.size >= configuration.maxSeen) {
            seen.remove(seenOrder.removeFirst())
        }
        seen[id] = now
        seenOrder.addLast(id)
    }
}
