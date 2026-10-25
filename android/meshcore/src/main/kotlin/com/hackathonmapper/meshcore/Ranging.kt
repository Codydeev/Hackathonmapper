package com.hackathonmapper.meshcore

import java.util.Base64
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/**
 * `Data` the way `JSONEncoder`/`JSONDecoder` handle it by default (`.base64`): a padded standard
 * base64 string. Like `Data(base64Encoded:)`, decoding rejects missing padding and any character
 * outside the alphabet (including whitespace).
 */
internal object Base64DataSerializer : KSerializer<ByteArray> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("MeshCore.Base64Data", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: ByteArray) {
        encoder.encodeString(Base64.getEncoder().encodeToString(value))
    }

    override fun deserialize(decoder: Decoder): ByteArray {
        val text = decoder.decodeString()
        if (text.length % 4 != 0) throw SerializationException("Invalid base64 data")
        return try {
            Base64.getDecoder().decode(text)
        } catch (e: IllegalArgumentException) {
            throw SerializationException("Invalid base64 data", e)
        }
    }
}

/**
 * Link-local: a phone's Nearby Interaction discovery token for one neighbor. Each phone runs one
 * session per neighbor, configured with that neighbor's token. Never relayed.
 */
@Serializable
data class RangingToken(
    /** Archived `NIDiscoveryToken`; opaque to MeshCore. Base64 on the wire. */
    @Serializable(with = Base64DataSerializer::class) val token: ByteArray,
    /** Only links with a direction anchor on at least one side need a session. */
    val isAnchor: Boolean,
) {
    fun encoded(): ByteArray {
        if (token.size !in 1..maxTokenSize) throw MeshCoreError.invalidRanging
        return encodeMeshJson(serializer(), this)
    }

    override fun equals(other: Any?): Boolean =
        other is RangingToken && isAnchor == other.isAnchor && token.contentEquals(other.token)

    override fun hashCode(): Int = 31 * token.contentHashCode() + isAnchor.hashCode()

    companion object {
        const val maxTokenSize = 1_024

        fun decode(data: ByteArray): RangingToken {
            if (data.size > Framing.maxPayload) throw MeshCoreError.invalidRanging
            val value = decodeMeshJson(serializer(), data)
            if (value.token.size !in 1..maxTokenSize) throw MeshCoreError.invalidRanging
            return value
        }
    }
}

/**
 * Link-local: a position an anchor measured for the phone at the other end of the link from UWB
 * distance and direction. The target publishes it as its own report. Never relayed.
 */
@Serializable
data class RangingFix(
    val anchorId: String,
    val targetId: String,
    val position: Position,
    val accuracyMeters: Double,
    val distanceMeters: Double,
) {
    fun validate() {
        val valid = DashboardContract.isValidId(anchorId) && DashboardContract.isValidId(targetId) && anchorId != targetId &&
            listOf(position.x, position.y, position.z).all { it.isFinite() && kotlin.math.abs(it) <= DashboardContract.maxCoordinate } &&
            accuracyMeters.isFinite() && accuracyMeters >= 0 && accuracyMeters <= DashboardContract.maxAccuracyMeters &&
            distanceMeters.isFinite() && distanceMeters >= 0
        if (!valid) throw MeshCoreError.invalidRanging
    }

    fun encoded(): ByteArray {
        validate()
        return encodeMeshJson(serializer(), this)
    }

    companion object {
        /** A target stops using a fix this old; it never falls back to manual coordinates silently. */
        const val maxAge: TimeInterval = 3.0

        fun decode(data: ByteArray): RangingFix {
            if (data.size > Framing.maxPayload) throw MeshCoreError.invalidRanging
            val fix = decodeMeshJson(serializer(), data)
            fix.validate()
            return fix
        }
    }
}

/**
 * Swift: `Vector3(_ x, _ y, _ z)` with mutable components. Equality follows Swift's `Double ==`
 * (0.0 equals -0.0). The operators are Kotlin conveniences over the Swift methods.
 */
class Vector3(var x: Double, var y: Double, var z: Double) {
    val length: Double get() = sqrt(x * x + y * y + z * z)
    fun dot(o: Vector3): Double = x * o.x + y * o.y + z * o.z
    fun cross(o: Vector3): Vector3 = Vector3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    fun scaled(s: Double): Vector3 = Vector3(x * s, y * s, z * s)
    operator fun minus(o: Vector3): Vector3 = Vector3(x - o.x, y - o.y, z - o.z)
    val normalized: Vector3?
        get() {
            val l = length
            return if (l.isFinite() && l > 0) scaled(1 / l) else null
        }

    operator fun plus(o: Vector3): Vector3 = Vector3(x + o.x, y + o.y, z + o.z)
    operator fun times(s: Double): Vector3 = scaled(s)
    operator fun unaryMinus(): Vector3 = Vector3(-x, -y, -z)

    fun copy(x: Double = this.x, y: Double = this.y, z: Double = this.z): Vector3 = Vector3(x, y, z)
    operator fun component1(): Double = x
    operator fun component2(): Double = y
    operator fun component3(): Double = z

    override fun equals(other: Any?): Boolean = other is Vector3 && x == other.x && y == other.y && z == other.z
    override fun hashCode(): Int = 31 * (31 * (x + 0.0).hashCode() + (y + 0.0).hashCode()) + (z + 0.0).hashCode()
    override fun toString(): String = "Vector3(x=$x, y=$y, z=$z)"
}

/**
 * Converts a Nearby Interaction measurement taken by a mounted anchor into the shared frame.
 *
 * Device frame (Nearby Interaction, and Core Motion axes): x to the right of the screen, y up the
 * screen, z out of the screen, so a peer straight behind the phone is at (0, 0, -1).
 * `headingDegrees` is the direction the back of the phone faces, projected on the floor plan and
 * measured from map +z towards map +x. Gravity supplies pitch and roll, so only the heading has to
 * be entered. Map frame: x right, y up, z forward.
 */
object AnchorGeometry {
    /** Rough direction error of iPhone UWB plus the error of a hand-entered heading. */
    const val directionErrorDegrees = 10.0
    const val headingErrorDegrees = 5.0
    const val baseErrorMeters = 0.3
    /**
     * The back may point at most this far above or below the horizon; beyond it the heading is
     * too poorly defined.
     */
    const val maxTiltDegrees = 60.0

    /** Returns a fresh instance each time, because [Vector3] is mutable (Swift `let` struct constant). */
    val upright: Vector3 get() = Vector3(0.0, -1.0, 0.0)

    /** Map-frame unit vector for a device-frame direction; null if the phone lies too flat. */
    fun mapDirection(direction: Vector3, gravity: Vector3 = upright, headingDegrees: Double): Vector3? {
        if (!headingDegrees.isFinite()) return null
        val up = gravity.scaled(-1.0).normalized ?: return null
        val d = direction.normalized ?: return null
        val back = Vector3(0.0, 0.0, -1.0)
        val horizontal = back.minus(up.scaled(back.dot(up)))
        if (!(horizontal.length >= cos(maxTiltDegrees * PI / 180))) return null
        val forward = horizontal.normalized ?: return null
        val right = forward.cross(up)
        val a = d.dot(forward)
        val r = d.dot(right)
        val u = d.dot(up)
        val h = headingDegrees * PI / 180
        return Vector3(a * sin(h) + r * cos(h), u, a * cos(h) - r * sin(h))
    }

    /**
     * The direction and heading errors are rough upper bounds added together, so this is used as
     * the 95 % radius `accuracyMeters` carries.
     */
    fun accuracy(distance: Double): Double {
        val angle = (directionErrorDegrees + headingErrorDegrees) * PI / 180
        val value = distance * sin(angle) + baseErrorMeters
        return min(DashboardContract.maxAccuracyMeters, swiftRounded(value * 100) / 100)
    }

    /** Null unless the measurement is usable. With `floor`, the result lies on the floor (y = 0). */
    fun fix(
        anchorId: String,
        targetId: String,
        anchor: Position,
        headingDegrees: Double,
        gravity: Vector3 = upright,
        distance: Double,
        direction: Vector3,
        floor: Boolean,
    ): RangingFix? {
        if (!(distance.isFinite() && distance >= 0)) return null
        val v = mapDirection(direction, gravity = gravity, headingDegrees = headingDegrees) ?: return null
        val position = Position(
            x = anchor.x + distance * v.x,
            y = if (floor) 0.0 else anchor.y + distance * v.y,
            z = anchor.z + distance * v.z,
        )
        val fix = RangingFix(
            anchorId = anchorId, targetId = targetId, position = position,
            accuracyMeters = accuracy(distance), distanceMeters = distance,
        )
        return try {
            fix.validate()
            fix
        } catch (e: MeshCoreError) {
            null
        }
    }
}
