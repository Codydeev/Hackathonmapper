package com.hackathonmapper.meshcore

import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlinx.serialization.Serializable

/** Body of a relay-test beacon: one per second from the sending phone, numbered within a run. */
@Serializable
data class BeaconPayload(
    val run: String,
    val seq: Int,
) {
    val body: String
        get() = try {
            MeshJson.encodeToString(serializer(), this)
        } catch (e: Exception) {
            "{}"
        }

    companion object {
        const val kind = "t3.beacon"

        fun decode(body: String): BeaconPayload? = try {
            decodeMeshJson(serializer(), body.encodeToByteArray())
        } catch (e: Exception) {
            null
        }
    }
}

/**
 * What one phone received of another phone's beacon run, for test T3 (AC-3): delivery ratio,
 * routes, and ages. Delivery counts sequences from the first to the last one received, so beacons
 * lost after the last arrival only show against the sender's own count.
 *
 * A Swift struct with `mutating` methods: use [copy] where Swift relies on a value copy.
 */
class BeaconStats(
    val originId: String,
    val run: String,
) {
    var sequences: Set<Int> = emptySet()
        private set
    /** `ageMs` of each received beacon, in arrival order. */
    var agesMs: List<Int> = emptyList()
        private set
    /** Arrivals per relay path, joined with " > "; "" is a direct link. */
    var routes: Map<String, Int> = emptyMap()
        private set
    /** Beacons delivered more than once: duplicate suppression failed. */
    var duplicates: Int = 0
        private set

    /** Records a delivered envelope. False when it isn't a beacon of this run. */
    fun record(envelope: RelayEnvelope): Boolean {
        if (envelope.kind != BeaconPayload.kind || envelope.originId != originId) return false
        val beacon = BeaconPayload.decode(envelope.body) ?: return false
        if (beacon.run != run) return false
        if (beacon.seq in sequences) {
            duplicates += 1
            return true
        }
        sequences = sequences + beacon.seq
        agesMs = agesMs + envelope.ageMs
        val key = routeKey(envelope.path)
        routes = routes + (key to (routes[key] ?: 0) + 1)
        return true
    }

    companion object {
        fun routeKey(path: List<String>): String = path.joinToString(" > ")
    }

    val received: Int get() = sequences.size
    val firstSequence: Int? get() = sequences.minOrNull()
    val lastSequence: Int? get() = sequences.maxOrNull()

    /** Beacons the sender must have sent between the first and last received. */
    val expected: Int
        get() {
            val first = firstSequence ?: return 0
            val last = lastSequence ?: return 0
            return last - first + 1
        }

    val deliveryRatio: Double? get() = if (expected > 0) received.toDouble() / expected else null

    /** Share of received beacons that came over exactly `path`. */
    fun share(of: List<String>): Double? =
        if (received > 0) (routes[routeKey(of)] ?: 0).toDouble() / received else null

    /** Nearest-rank percentile of the ages, 0...100. */
    fun ageMs(percentile: Double): Int? {
        if (agesMs.isEmpty()) return null
        val sorted = agesMs.sorted()
        val rank = ceil(percentile / 100 * sorted.size).toInt()
        return sorted[min(sorted.size - 1, max(0, rank - 1))]
    }

    val medianAgeMs: Int? get() = ageMs(percentile = 50.0)

    /** Value copy (Swift struct semantics). */
    fun copy(): BeaconStats = BeaconStats(originId, run).also {
        it.sequences = sequences
        it.agesMs = agesMs
        it.routes = routes
        it.duplicates = duplicates
    }

    override fun equals(other: Any?): Boolean =
        other is BeaconStats && originId == other.originId && run == other.run && sequences == other.sequences &&
            agesMs == other.agesMs && routes == other.routes && duplicates == other.duplicates

    override fun hashCode(): Int = listOf(originId, run, sequences, agesMs, routes, duplicates).hashCode()
}
