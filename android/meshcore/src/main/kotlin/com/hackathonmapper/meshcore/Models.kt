package com.hackathonmapper.meshcore

import java.math.BigDecimal
import java.math.RoundingMode
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.text.BreakIterator
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Required
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.SerializationStrategy
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json

/**
 * The one JSON configuration for every wire and contract type. Matches Swift's
 * `JSONEncoder`/`JSONDecoder` defaults: unknown keys are ignored, nil optionals are omitted on
 * encode and a missing optional decodes as null.
 */
val MeshJson: Json = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
}

/**
 * Decodes UTF-8 JSON like `JSONDecoder().decode(_:from:)`: invalid UTF-8 is an error instead of
 * being replaced. Decoding errors surface as [SerializationException] (Swift: `DecodingError`),
 * never as [MeshCoreError].
 */
internal fun <T> decodeMeshJson(deserializer: DeserializationStrategy<T>, data: ByteArray): T {
    val text = try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(data))
            .toString()
    } catch (e: CharacterCodingException) {
        throw SerializationException("Invalid UTF-8 in JSON payload", e)
    }
    return MeshJson.decodeFromString(deserializer, text)
}

internal fun <T> encodeMeshJson(serializer: SerializationStrategy<T>, value: T): ByteArray =
    MeshJson.encodeToString(serializer, value).encodeToByteArray()

sealed class MeshCoreError : Exception() {
    data object invalidUpdate : MeshCoreError()
    data object invalidPacket : MeshCoreError()
    data object packetTooLarge : MeshCoreError()
    data object frameMismatch : MeshCoreError()
    data object deviceCapacityReached : MeshCoreError()
    data object epochCapacityReached : MeshCoreError()
    data object invalidFrame : MeshCoreError()
    data object invalidHello : MeshCoreError()
    data object invalidRanging : MeshCoreError()
}

/**
 * Mesh wire format. Version 2 added typed frames, the link Hello and `MeshPacket.path`; version 3
 * added UWB ranging frames and skips unknown frame types; version 4 added the `uwb` and `fused`
 * position sources and made `accuracyMeters` a 95 % radius (a version 3 phone cannot decode those
 * reports); version 5 added `NeighborObservation.uwbDistanceM`. Relays re-encode the packets they
 * decode, so an older relay would strip it silently; the bump makes it refuse the link at the Hello
 * instead. Every phone in a demo must run the same version.
 */
object MeshProtocol {
    const val version = 5
    /** Longest relay path a packet may carry; matches the largest accepted hop count. */
    const val maxPathLength = 8
}

/**
 * Limits of the dashboard upload contract (WEBSITE_PLAN.md). The dashboard rejects a whole
 * batch if one entry breaks them, so relayed reports are held to the same limits on ingest.
 */
object DashboardContract {
    /** Lengths are UTF-16 code units, which is how the dashboard (JavaScript) measures strings. Kotlin's `String.length` counts the same units. */
    const val maxIdLength = 64
    const val maxLabelLength = 40
    const val maxCoordinate = 10_000.0
    const val maxAccuracyMeters = 1_000.0
    const val maxNeighbors = 16
    val rssiRange: IntRange = -127..20
    const val maxAgeMs = 86_400_000
    /**
     * Upper bound for a reported UWB distance; Nearby Interaction measures far less in practice.
     * Mirrors `MAX_UWB_DISTANCE_M` in website/shared/contract.ts.
     */
    const val maxUWBDistanceMeters = 200.0

    fun isValidId(value: String): Boolean =
        value.isNotEmpty() && value.length <= maxIdLength && value == trimmingWhitespacesAndNewlines(value)

    /** Truncates on character boundaries so the result fits `maxLabelLength` UTF-16 units. */
    fun truncatedLabel(text: String): String {
        // Swift iterates `Character`s (extended grapheme clusters); BreakIterator is the JVM/ICU equivalent.
        val result = StringBuilder()
        val iterator = BreakIterator.getCharacterInstance()
        iterator.setText(text)
        var start = iterator.first()
        var end = iterator.next()
        while (end != BreakIterator.DONE) {
            val characterLength = end - start
            if (result.length + characterLength > maxLabelLength) break
            result.append(text, start, end)
            start = end
            end = iterator.next()
        }
        return result.toString()
    }

    /** `CharacterSet.whitespacesAndNewlines`: Unicode Z* categories, U+0009–U+000D and U+0085. */
    private fun isWhitespaceOrNewline(c: Char): Boolean {
        if (c == '\t' || c in '\n'..'\r' || c == '\u0085') return true
        return when (Character.getType(c).toByte()) {
            Character.SPACE_SEPARATOR, Character.LINE_SEPARATOR, Character.PARAGRAPH_SEPARATOR -> true
            else -> false
        }
    }

    private fun trimmingWhitespacesAndNewlines(value: String): String {
        var start = 0
        var end = value.length
        while (start < end && isWhitespaceOrNewline(value[start])) start++
        while (end > start && isWhitespaceOrNewline(value[end - 1])) end--
        return value.substring(start, end)
    }
}

/**
 * A direct BLE link observed by the reporting phone. Relays forward it unchanged.
 *
 * Swift rounds `uwbDistanceM` in `init` but not when decoding, so the public constructor rounds and
 * the serializer (through a surrogate) builds with the private one, which keeps the decoded value.
 * Equality follows Swift's `Double ==`.
 */
@Serializable(with = NeighborObservationSerializer::class)
class NeighborObservation private constructor(
    val id: String,
    val rssi: Int?,
    val ageMs: Int?,
    /**
     * The reporter's own fresh UWB (Nearby Interaction) distance to `id` in meters,
     * 0...`DashboardContract.maxUWBDistanceMeters`, rounded to 0.01 m. The signal map prefers it
     * to the RSSI range.
     */
    val uwbDistanceM: Double?,
    @Suppress("UNUSED_PARAMETER") decoded: Unit,
) {
    constructor(id: String, rssi: Int? = null, ageMs: Int? = null, uwbDistanceM: Double? = null) : this(
        id, rssi, ageMs,
        // Rounding keeps reports small; an out-of-range value stays out of range so validation sees it.
        uwbDistanceM?.let { if (it.isFinite()) swiftRounded(it * 100) / 100 else it },
        Unit,
    )

    internal val isValidUWB: Boolean
        get() = uwbDistanceM?.let { it.isFinite() && it >= 0 && it <= DashboardContract.maxUWBDistanceMeters } ?: true

    override fun equals(other: Any?): Boolean {
        if (other !is NeighborObservation) return false
        val a = uwbDistanceM
        val b = other.uwbDistanceM
        val sameUWB = if (a == null || b == null) a == null && b == null else a == b
        return id == other.id && rssi == other.rssi && ageMs == other.ageMs && sameUWB
    }

    override fun hashCode(): Int {
        var result = id.hashCode()
        result = 31 * result + (rssi ?: 0)
        result = 31 * result + (ageMs ?: 0)
        // + 0.0 turns -0.0 into 0.0 so equal values hash alike.
        result = 31 * result + (uwbDistanceM?.let { (it + 0.0).hashCode() } ?: 0)
        return result
    }

    override fun toString(): String = "NeighborObservation(id=$id, rssi=$rssi, ageMs=$ageMs, uwbDistanceM=$uwbDistanceM)"

    internal companion object {
        /** Swift's synthesized `init(from:)`: the decoded value as is, not rounded. */
        fun decoded(id: String, rssi: Int?, ageMs: Int?, uwbDistanceM: Double?): NeighborObservation =
            NeighborObservation(id, rssi, ageMs, uwbDistanceM, Unit)
    }
}

@Serializable
private class NeighborObservationSurrogate(
    val id: String,
    val rssi: Int? = null,
    val ageMs: Int? = null,
    val uwbDistanceM: Double? = null,
)

/** Same JSON as Swift's synthesized `Codable`: `id` required, nil optionals omitted. */
internal object NeighborObservationSerializer : KSerializer<NeighborObservation> {
    override val descriptor: SerialDescriptor = NeighborObservationSurrogate.serializer().descriptor

    override fun serialize(encoder: Encoder, value: NeighborObservation) {
        encoder.encodeSerializableValue(
            NeighborObservationSurrogate.serializer(),
            NeighborObservationSurrogate(value.id, value.rssi, value.ageMs, value.uwbDistanceM),
        )
    }

    override fun deserialize(decoder: Decoder): NeighborObservation {
        if (decoder is kotlinx.serialization.json.JsonDecoder) {
            // kotlinx accepts "3" for a number; Swift's JSONDecoder doesn't, so neither do we.
            val element = decoder.decodeJsonElement()
            if (element is kotlinx.serialization.json.JsonObject) {
                for (key in listOf("rssi", "ageMs", "uwbDistanceM")) {
                    val value = element[key]
                    if (value is kotlinx.serialization.json.JsonPrimitive && value.isString) {
                        throw SerializationException("NeighborObservation.$key must be a number")
                    }
                }
            }
            val s = decoder.json.decodeFromJsonElement(NeighborObservationSurrogate.serializer(), element)
            return NeighborObservation.decoded(s.id, s.rssi, s.ageMs, s.uwbDistanceM)
        }
        val s = decoder.decodeSerializableValue(NeighborObservationSurrogate.serializer())
        return NeighborObservation.decoded(s.id, s.rssi, s.ageMs, s.uwbDistanceM)
    }
}

/** Equality follows Swift's `Double ==` (0.0 equals -0.0), not boxed `Double.equals`. */
@Serializable
data class Position(
    val x: Double,
    val y: Double,
    val z: Double,
) {
    override fun equals(other: Any?): Boolean =
        other is Position && x == other.x && y == other.y && z == other.z

    override fun hashCode(): Int {
        // + 0.0 turns -0.0 into 0.0 so equal values hash alike.
        var result = (x + 0.0).hashCode()
        result = 31 * result + (y + 0.0).hashCode()
        result = 31 * result + (z + 0.0).hashCode()
        return result
    }
}

/**
 * Where a report's position came from. `none` means the phone does not know where it is: its
 * `position` is a placeholder and the dashboard places it from the Bluetooth links it reports.
 * `uwb`: a fix measured by a mounted UWB direction anchor. `fused`: dead reckoning corrected by
 * RSSI to BLE anchors (`FusionEngine`), with the filter's own accuracy.
 */
@Serializable
enum class PositionSource(val rawValue: String) {
    @SerialName("gps") gps("gps"),
    @SerialName("manual") manual("manual"),
    @SerialName("none") none("none"),
    @SerialName("uwb") uwb("uwb"),
    @SerialName("fused") fused("fused");

    companion object {
        /** Swift `PositionSource(rawValue:)`. */
        fun fromRawValue(rawValue: String): PositionSource? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/**
 * Shared frames anchored to a fixed GPS origin, so GPS fixes from different phones land in the
 * same metric frame, meters on the floor plane. +z points along the origin's bearing (north by
 * default, so x east and z north); a room frame can turn +z towards a wall and keep GPS working.
 * A frame without an origin is a room frame of its own: x right, z forward, no GPS.
 */
object GeoFrame {
    data class Origin(
        val latitude: Double,
        val longitude: Double,
        /** Compass bearing of +z, degrees clockwise from north. */
        val bearingDegrees: Double = 0.0,
    )

    /** Swift's `(x: Double, z: Double)` tuple. */
    data class Projection(val x: Double, val z: Double)

    /** Swift's `(latitude: Double, longitude: Double)` tuple. */
    data class Coordinate(val latitude: Double, val longitude: Double)

    /** Swift's `(x: String, z: String)` tuple. */
    data class AxisNames(val x: String, val z: String)

    const val defaultFrameId = "hervanta-v1"

    /** Tietotalo, Tampere University Hervanta campus. Keep identical to Models.swift and website/shared/geoframe.ts. */
    val origins: Map<String, Origin> = mapOf(
        "hervanta-v1" to Origin(latitude = 61.4499, longitude = 23.8560),
    )

    private const val metersPerDegree = 6_371_008.8 * PI / 180

    /**
     * GPS fix in the frame's floor plane, or null if the frame has no origin or the fix is
     * outside the dashboard's coordinate limit.
     */
    fun position(frameId: String, latitude: Double, longitude: Double): Position? {
        val origin = origins[frameId] ?: return null
        if (!latitude.isFinite() || !longitude.isFinite()) return null
        val (x, z) = project(origin, latitude, longitude)
        if (!(abs(x) <= DashboardContract.maxCoordinate && abs(z) <= DashboardContract.maxCoordinate)) return null
        return Position(x = x, y = 0.0, z = z)
    }

    fun project(origin: Origin, latitude: Double, longitude: Double): Projection {
        val east = (longitude - origin.longitude) * metersPerDegree * cos(origin.latitude * PI / 180)
        val north = (latitude - origin.latitude) * metersPerDegree
        val bearing = origin.bearingDegrees * PI / 180
        return Projection(east * cos(bearing) - north * sin(bearing), east * sin(bearing) + north * cos(bearing))
    }

    /** The inverse: a point in the frame's floor plane as GPS coordinates, for maps. */
    fun coordinate(frameId: String, x: Double, z: Double): Coordinate? {
        val origin = origins[frameId] ?: return null
        if (!x.isFinite() || !z.isFinite()) return null
        return unproject(origin, x, z)
    }

    fun unproject(origin: Origin, x: Double, z: Double): Coordinate {
        val bearing = origin.bearingDegrees * PI / 180
        val east = x * cos(bearing) + z * sin(bearing)
        val north = -x * sin(bearing) + z * cos(bearing)
        return Coordinate(
            origin.latitude + north / metersPerDegree,
            origin.longitude + east / (metersPerDegree * cos(origin.latitude * PI / 180)),
        )
    }

    /** What +z means in this frame, for "face +z" instructions: "north", "bearing 35°" or "forward". */
    fun forwardName(frameId: String): String {
        val origin = origins[frameId] ?: return "forward (+z)"
        val bearing = ((origin.bearingDegrees % 360) + 360) % 360
        if (bearing == 0.0) return "north (+z)"
        // C's %.0f rounds the exact binary value half to even.
        val rounded = BigDecimal(bearing).setScale(0, RoundingMode.HALF_EVEN).toPlainString()
        return "+z (bearing $rounded°)"
    }

    /** Axis names for typed coordinates: east/north in a north-up geo frame, right/forward otherwise. */
    fun axisNames(frameId: String): AxisNames =
        if (origins[frameId]?.bearingDegrees == 0.0) AxisNames("east", "north") else AxisNames("right", "forward")
}

/** `UUID(uuidString:)`: exactly 8-4-4-4-12 hex digits, either case. */
private val uuidPattern = Regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")

/** Canonical (uppercase) form of a UUID string, or null if Swift's `UUID(uuidString:)` would fail. */
internal fun canonicalUUID(value: String): String? = if (uuidPattern.matches(value)) value.uppercase() else null

/**
 * `sequence` is a Long: Swift's `Int` is 64-bit and validation accepts sequences up to 2^53 − 1
 * (JavaScript's largest safe integer).
 */
@Serializable
data class DeviceUpdate(
    val id: String,
    val label: String? = null,
    val epochId: String,
    val sequence: Long,
    val role: String,
    val position: Position,
    val positionMode: String,
    val accuracyMeters: Double? = null,
    val neighbors: List<NeighborObservation>? = null,
    /** Absent in reports from older builds, which means `manual`. */
    val positionSource: PositionSource? = null,
) {
    fun validate() {
        // Bounds follow DashboardContract; sequences must round-trip through JSON numbers.
        val coordinates = listOf(position.x, position.y, position.z)
        val valid = DashboardContract.isValidId(id) &&
            (label?.let { it.length <= DashboardContract.maxLabelLength } ?: true) &&
            canonicalUUID(epochId) != null &&
            sequence >= 0 && sequence <= 9_007_199_254_740_991L &&
            role in listOf("anchor", "mobile", "gateway") &&
            coordinates.all { it.isFinite() && abs(it) <= DashboardContract.maxCoordinate } &&
            positionMode in listOf("3d", "floor") &&
            (positionMode != "floor" || position.y == 0.0) &&
            (accuracyMeters?.let { it.isFinite() && it >= 0 && it <= DashboardContract.maxAccuracyMeters } ?: true) &&
            neighborsAreValid
        if (!valid) throw MeshCoreError.invalidUpdate
    }

    private val neighborsAreValid: Boolean
        get() {
            val neighbors = neighbors ?: return true
            if (neighbors.size > DashboardContract.maxNeighbors) return false
            val seen = HashSet<String>()
            return neighbors.all { neighbor ->
                DashboardContract.isValidId(neighbor.id) &&
                    neighbor.id != id &&
                    seen.add(neighbor.id) &&
                    (neighbor.rssi?.let { it in DashboardContract.rssiRange } ?: true) &&
                    (neighbor.ageMs?.let { it in 0..DashboardContract.maxAgeMs } ?: true) &&
                    neighbor.isValidUWB
            }
        }
}

/**
 * Swift: `init(frameId:hopsRemaining:update:path:)` always sets `schemaVersion` to the current
 * version. Here `schemaVersion` is a trailing parameter with that default, so it can be omitted the
 * same way. `schemaVersion` and `path` are required on the wire, as in Swift's synthesized decoder.
 */
@Serializable
data class MeshPacket(
    val frameId: String,
    val hopsRemaining: Int,
    val update: DeviceUpdate,
    /** Device IDs of the phones that relayed this copy, oldest first. Empty when sent by the origin. */
    @Required val path: List<String> = emptyList(),
    @Required val schemaVersion: Int = MeshProtocol.version,
) {
    fun validate() {
        if (!(schemaVersion == MeshProtocol.version && frameId.isNotEmpty() && frameId.encodeToByteArray().size <= 128 &&
                hopsRemaining in 0..8 && pathIsValid)
        ) {
            throw MeshCoreError.invalidPacket
        }
        update.validate()
    }

    private val pathIsValid: Boolean
        get() {
            if (path.size > MeshProtocol.maxPathLength) return false
            val seen = HashSet<String>()
            return path.all { DashboardContract.isValidId(it) && it != update.id && seen.add(it) }
        }

    fun encoded(): ByteArray {
        validate()
        val data = encodeMeshJson(serializer(), this)
        if (data.size > 4_096) throw MeshCoreError.packetTooLarge
        return data
    }

    companion object {
        fun decode(data: ByteArray): MeshPacket {
            if (data.size > 4_096) throw MeshCoreError.packetTooLarge
            val packet = decodeMeshJson(serializer(), data)
            packet.validate()
            return packet
        }
    }
}

/**
 * First message on every BLE link, in both directions. A link carries mesh packets only after
 * both sides have subscribed and a valid Hello with the same protocol version and frame arrived.
 * `protocolVersion` is a trailing parameter defaulting to the current version (Swift sets it in init).
 */
@Serializable
data class Hello(
    val frameId: String,
    val deviceId: String,
    val label: String? = null,
    @Required val protocolVersion: Int = MeshProtocol.version,
) {
    // The protocol version is checked by the caller, so a mismatch can be reported as such.
    fun validate() {
        if (!(frameId.isNotEmpty() && frameId.encodeToByteArray().size <= 128 &&
                DashboardContract.isValidId(deviceId) &&
                (label?.let { it.length <= DashboardContract.maxLabelLength } ?: true))
        ) {
            throw MeshCoreError.invalidHello
        }
    }

    fun encoded(): ByteArray {
        validate()
        val data = encodeMeshJson(serializer(), this)
        if (data.size > maxEncodedSize) throw MeshCoreError.invalidHello
        return data
    }

    companion object {
        const val maxEncodedSize = 512

        fun decode(data: ByteArray): Hello {
            if (data.size > maxEncodedSize) throw MeshCoreError.invalidHello
            val hello = decodeMeshJson(serializer(), data)
            hello.validate()
            return hello
        }
    }
}
