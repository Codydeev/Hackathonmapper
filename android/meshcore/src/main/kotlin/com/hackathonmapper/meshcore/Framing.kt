package com.hackathonmapper.meshcore

/** Swift `UInt8` raw values, held as Int (0...255). */
enum class FrameType(val rawValue: Int) {
    hello(1),
    position(2),
    /** Link-local `RangingToken`. */
    rangingToken(3),
    /** Link-local `RangingFix`. */
    rangingFix(4);

    companion object {
        /** Swift `FrameType(rawValue:)`. */
        fun fromRawValue(rawValue: Int): FrameType? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/** Equality compares payload contents, like Swift `Data ==`. */
data class Frame(val type: FrameType, val payload: ByteArray) {
    override fun equals(other: Any?): Boolean =
        other is Frame && type == other.type && payload.contentEquals(other.payload)

    override fun hashCode(): Int = 31 * type.hashCode() + payload.contentHashCode()

    override fun toString(): String = "Frame(type=$type, payload=${payload.size} bytes)"
}

/** BLE stream framing: `[type: UInt8][length: UInt32 big-endian][payload]`. */
object Framing {
    const val headerLength = 5
    const val maxPayload = 4_096

    fun encode(payload: ByteArray, type: FrameType): ByteArray? {
        if (payload.size !in 1..maxPayload) return null
        val size = payload.size
        val header = byteArrayOf(
            type.rawValue.toByte(),
            (size ushr 24 and 255).toByte(),
            (size ushr 16 and 255).toByte(),
            (size ushr 8 and 255).toByte(),
            (size and 255).toByte(),
        )
        return header + payload
    }
}

/**
 * Reassembles frames from the chunks of one link. Not thread-safe; one instance per link.
 * A Swift struct: use [copy] where Swift relies on a value copy.
 */
class FrameAssembler {
    companion object {
        const val maxBuffered = 8_192
        /** A partial frame older than this is discarded, so a lost chunk cannot wedge the link. */
        const val timeout: TimeInterval = 10.0
    }

    private var buffer = ByteArray(0)
    private var updatedAt: Double? = null

    val hasPartialFrame: Boolean get() = buffer.isNotEmpty()

    /** Returns the frames completed by `chunk`. Throws on malformed input and clears the buffer. */
    fun append(chunk: ByteArray, now: Double = currentTime()): List<Frame> {
        buffer += chunk
        if (buffer.size > maxBuffered) {
            reset()
            throw MeshCoreError.invalidFrame
        }
        val frames = mutableListOf<Frame>()
        while (buffer.size >= Framing.headerLength) {
            val type = buffer[0].toInt() and 0xFF
            var length = 0L
            for (index in 1 until Framing.headerLength) length = (length shl 8) or (buffer[index].toLong() and 0xFF)
            // Type 0 is how a version 1 length prefix starts, so it is never valid.
            if (type == 0 || length !in 1L..Framing.maxPayload.toLong()) {
                reset()
                throw MeshCoreError.invalidFrame
            }
            val end = Framing.headerLength + length.toInt()
            if (buffer.size < end) break
            // Unknown types are skipped, so a later frame type does not need another version bump.
            FrameType.fromRawValue(type)?.let { frames.add(Frame(it, buffer.copyOfRange(Framing.headerLength, end))) }
            buffer = buffer.copyOfRange(end, buffer.size)
        }
        updatedAt = if (buffer.isEmpty()) null else now
        return frames
    }

    /** Drops a partial frame that has waited longer than `timeout`. Returns true if one was dropped. */
    fun expire(now: Double = currentTime()): Boolean {
        val updatedAt = updatedAt ?: return false
        if (!(now - updatedAt > timeout)) return false
        reset()
        return true
    }

    fun reset() {
        buffer = ByteArray(0)
        updatedAt = null
    }

    /** Value copy (Swift struct semantics). */
    fun copy(): FrameAssembler = FrameAssembler().also {
        it.buffer = buffer.copyOf()
        it.updatedAt = updatedAt
    }
}

/**
 * Outgoing queue for one link. Holds at most one pending frame per key, so a slow link only
 * ever delivers the latest report for each origin. The frame being sent is never interrupted,
 * which keeps the receiver's framing intact. A Swift struct: use [copy] where Swift relies on a value copy.
 */
class LinkOutbox {
    var chunks: List<ByteArray> = emptyList()
        private set
    private var pending: MutableMap<String, ByteArray> = HashMap()
    private var order: ArrayDeque<String> = ArrayDeque()

    val isEmpty: Boolean get() = chunks.isEmpty() && order.isEmpty()
    val pendingCount: Int get() = order.size

    /** A newer frame for the same key replaces the queued one and keeps its place in line. */
    fun enqueue(framed: ByteArray, key: String) {
        if (pending.put(key, framed) == null) order.addLast(key)
    }

    fun nextChunk(maxLength: Int): ByteArray? {
        if (chunks.isEmpty() && order.isNotEmpty()) {
            val framed = pending.remove(order.removeFirst())
            if (framed != null) {
                val size = maxOf(1, maxLength)
                chunks = (0 until framed.size step size).map { framed.copyOfRange(it, minOf(it + size, framed.size)) }
            }
        }
        return chunks.firstOrNull()
    }

    fun chunkSent() {
        if (chunks.isNotEmpty()) chunks = chunks.drop(1)
    }

    fun removeAll() {
        chunks = emptyList()
        pending.clear()
        order.clear()
    }

    /** Value copy (Swift struct semantics). */
    fun copy(): LinkOutbox = LinkOutbox().also {
        it.chunks = chunks
        it.pending = HashMap(pending)
        it.order = ArrayDeque(order)
    }
}
