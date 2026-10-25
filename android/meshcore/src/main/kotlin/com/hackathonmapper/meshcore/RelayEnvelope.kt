package com.hackathonmapper.meshcore

import java.util.UUID
import kotlinx.serialization.Required
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException

sealed class RelayError : Exception() {
    data object invalidEnvelope : RelayError()
    data object invalidSummary : RelayError()
    data object tooLarge : RelayError()
}

/** Swift's `UUID()` as a wire string: uppercase, like `uuidString`. */
private fun newUUIDString(): String = UUID.randomUUID().toString().uppercase()

/** Swift's `UUID` decoding: a malformed UUID string is a decoding error; valid ones become canonical. */
private fun decodedUUID(value: String): String =
    canonicalUUID(value) ?: throw SerializationException("Invalid UUID string: $value")

/**
 * A store-and-forward message (frame type 5). Position packets only ever carry the latest report
 * per origin; an envelope is delivered once per phone and held for neighbors that appear later,
 * until its TTL runs out or a delivery receipt clears it.
 *
 * Time: wall clocks on the phones are not synchronized, so `createdAt` is advisory only. `ageMs`
 * is the time the message spent on the origin and on each relay, measured on each phone's
 * monotonic clock and summed hop by hop. It leaves out link queue and air time, so it is a lower
 * bound. TTL is enforced on `ageMs`, never on wall clock differences.
 *
 * UUIDs (`messageId`, `acknowledges`) are uppercase strings; decoding rejects malformed ones and
 * canonicalizes the rest, like Swift's `UUID`. `schemaVersion` is a trailing parameter defaulting to
 * the current version (Swift sets it in init); it, `messageId`, `ageMs` and `path` are required on
 * the wire, as in Swift's synthesized decoder.
 */
@Serializable
data class RelayEnvelope(
    /** Created by the origin and preserved across relays; duplicates are suppressed by it. */
    @Required val messageId: String = newUUIDString(),
    val originId: String,
    /** Null broadcasts to every phone. */
    val destinationId: String? = null,
    /** Short machine name: `text`, `ping`, `receipt`, or a module's own such as `ghostcore.sos`. */
    val kind: String,
    val body: String,
    /** Origin wall clock in milliseconds since 1970. Advisory: never used for ages or expiry. */
    val createdAt: Double? = null,
    @Required val ageMs: Int = 0,
    val ttlMs: Int,
    /** How many more phones may relay this copy. */
    val hopsRemaining: Int,
    /** Device IDs of the phones that relayed this copy, oldest first. Empty when sent by the origin. */
    @Required val path: List<String> = emptyList(),
    /** For receipts: the message whose delivery this confirms. */
    val acknowledges: String? = null,
    @Required val schemaVersion: Int = RelayEnvelope.schemaVersion,
) {
    companion object {
        const val schemaVersion = 1
        const val maxBodyBytes = 1_024
        const val maxTTLMs = 15 * 60_000
        /** Relays a copy may still pass through plus relays it already passed through. */
        const val maxHops = MeshProtocol.maxPathLength
        const val maxEncodedSize = 3_072
        const val receiptKind = "receipt"

        private val kindPattern = Regex("^[a-z0-9._-]{1,32}$")

        fun decode(data: ByteArray): RelayEnvelope {
            if (data.size > maxEncodedSize) throw RelayError.tooLarge
            val raw = decodeMeshJson(serializer(), data)
            val envelope = raw.copy(messageId = decodedUUID(raw.messageId), acknowledges = raw.acknowledges?.let { decodedUUID(it) })
            envelope.validate()
            return envelope
        }
    }

    val isReceipt: Boolean get() = kind == receiptKind
    val isExpired: Boolean get() = ageMs >= ttlMs

    /** The contract's view of the time fields: age and TTL in seconds (`GhostCoreContract`). */
    val freshness: Freshness get() = Freshness(ageAtHandoff = ageMs.toDouble() / 1000, maxAge = ttlMs.toDouble() / 1000)
    /** Origin wall clock in Unix seconds, advisory only. */
    val timestamp: Double? get() = createdAt?.let { it / 1000 }

    /**
     * The copy a relay sends on: one hop fewer, itself appended to the path, and the time it held
     * the message added to the age.
     */
    internal fun relayed(by: String, heldMs: Int): RelayEnvelope? {
        if (hopsRemaining <= 0) return null
        return copy(ageMs = ageMs + maxOf(0, heldMs), hopsRemaining = hopsRemaining - 1, path = path + by)
    }

    fun validate() {
        val valid = schemaVersion == RelayEnvelope.schemaVersion &&
            canonicalUUID(messageId) != null &&
            DashboardContract.isValidId(originId) &&
            (destinationId?.let { DashboardContract.isValidId(it) && it != originId } ?: true) &&
            kindPattern.matches(kind) &&
            body.encodeToByteArray().size <= maxBodyBytes &&
            (createdAt?.let { it.isFinite() && it >= 0 } ?: true) &&
            ttlMs in 1..maxTTLMs &&
            // An expired copy is still well formed; the engine counts it separately.
            ageMs >= 0 && ageMs <= 4 * maxTTLMs &&
            hopsRemaining >= 0 && path.size + hopsRemaining <= maxHops &&
            pathIsValid &&
            (acknowledges?.let { canonicalUUID(it) != null } ?: true) &&
            isReceipt == (acknowledges != null)
        if (!valid) throw RelayError.invalidEnvelope
    }

    private val pathIsValid: Boolean
        get() {
            val seen = HashSet<String>()
            return path.all { DashboardContract.isValidId(it) && it != originId && seen.add(it) }
        }

    fun encoded(): ByteArray {
        validate()
        val data = encodeMeshJson(serializer(), this)
        if (data.size > maxEncodedSize) throw RelayError.tooLarge
        return data
    }
}

/** Body of a delivery receipt: how the confirmed message reached its destination. */
@Serializable
data class RelayReceiptInfo(
    /** Relays of the copy the destination accepted, oldest first. */
    val path: List<String>,
    /** `ageMs` of that copy on arrival: a lower bound on delivery time. */
    val ageMs: Int,
) {
    fun encodedBody(): String = try {
        MeshJson.encodeToString(serializer(), this)
    } catch (e: Exception) {
        "{}"
    }

    companion object {
        fun decode(body: String): RelayReceiptInfo? = try {
            decodeMeshJson(serializer(), body.encodeToByteArray())
        } catch (e: Exception) {
            null
        }
    }
}

/**
 * Link-local summary (frame type 6): the most recent message IDs this phone has seen. A neighbor
 * answers by sending the stored messages missing from it, which repairs copies lost when a link
 * dropped mid-transfer and brings a phone that just arrived up to date.
 */
@Serializable
data class RelaySummary(
    val have: List<String>,
    @Required val schemaVersion: Int = RelayEnvelope.schemaVersion,
) {
    companion object {
        const val maxIds = 64

        fun decode(data: ByteArray): RelaySummary {
            if (data.size > Framing.maxPayload) throw RelayError.tooLarge
            val raw = decodeMeshJson(serializer(), data)
            val summary = raw.copy(have = raw.have.map { decodedUUID(it) })
            summary.validate()
            return summary
        }
    }

    fun validate() {
        if (!(schemaVersion == RelayEnvelope.schemaVersion && have.size <= maxIds)) {
            throw RelayError.invalidSummary
        }
    }

    fun encoded(): ByteArray {
        validate()
        return encodeMeshJson(serializer(), this)
    }
}
