package com.hackathonmapper.meshcore

import kotlin.math.cos
import kotlin.math.sin
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/**
 * A raw input a scenario feeds into the real pipeline: it changes a phone's own sensor streams,
 * never an engine's output. GNSS faults act on the phone named by `subjectId`, which in the app is
 * always the phone running the scenario: other phones are other devices.
 *
 * JSON: `{"type": "gnssJump", "subjectId": "phone-c", "dx": 400, "dz": 0}`.
 */
@Serializable(with = ScenarioInputSerializer::class)
sealed class ScenarioInput {
    abstract val subjectId: String

    /** The phone's GNSS delivers no fixes while active. */
    data class gnssOutage(override val subjectId: String, val active: Boolean) : ScenarioInput()

    /** Every following fix is shifted by (dx, dz) metres at once. */
    data class gnssJump(override val subjectId: String, val dx: Double, val dz: Double) : ScenarioInput()

    /** From now on the shift grows at `metersPerSecond`, towards `bearingDegrees` (0 = +z north, 90 = +x east). */
    data class gnssDrift(override val subjectId: String, val metersPerSecond: Double, val bearingDegrees: Double) :
        ScenarioInput()

    /** Removes outage, jump and drift. */
    data class gnssClear(override val subjectId: String) : ScenarioInput()

    /** Forces this phone's Bluetooth link to `peerId` down (the relay's test link filter) or lets it up again. */
    data class peerLink(override val subjectId: String, val peerId: String, val up: Boolean) : ScenarioInput()
}

/** Swift's custom `Codable` of `ScenarioInput`. JSON only. */
internal object ScenarioInputSerializer : KSerializer<ScenarioInput> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("MeshCore.ScenarioInput")

    override fun serialize(encoder: Encoder, value: ScenarioInput) {
        val json = (encoder as? JsonEncoder)?.json ?: throw SerializationException("ScenarioInput is JSON only")
        val element = buildJsonObject {
            put("subjectId", JsonPrimitive(value.subjectId))
            when (value) {
                is ScenarioInput.gnssOutage -> {
                    put("type", JsonPrimitive("gnssOutage"))
                    put("active", JsonPrimitive(value.active))
                }
                is ScenarioInput.gnssJump -> {
                    put("type", JsonPrimitive("gnssJump"))
                    put("dx", json.encodeToJsonElement(Double.serializer(), value.dx))
                    put("dz", json.encodeToJsonElement(Double.serializer(), value.dz))
                }
                is ScenarioInput.gnssDrift -> {
                    put("type", JsonPrimitive("gnssDrift"))
                    put("metersPerSecond", json.encodeToJsonElement(Double.serializer(), value.metersPerSecond))
                    put("bearingDegrees", json.encodeToJsonElement(Double.serializer(), value.bearingDegrees))
                }
                is ScenarioInput.gnssClear -> put("type", JsonPrimitive("gnssClear"))
                is ScenarioInput.peerLink -> {
                    put("type", JsonPrimitive("peerLink"))
                    put("peerId", JsonPrimitive(value.peerId))
                    put("up", JsonPrimitive(value.up))
                }
            }
        }
        encoder.encodeJsonElement(element)
    }

    override fun deserialize(decoder: Decoder): ScenarioInput {
        val input = decoder as? JsonDecoder ?: throw SerializationException("ScenarioInput is JSON only")
        val json = input.json
        val obj = input.decodeJsonElement() as? JsonObject ?: throw SerializationException("scenario input is not an object")
        fun key(name: String) = obj[name] ?: throw SerializationException("scenario input: missing key '$name'")
        fun string(name: String) = json.decodeFromJsonElement(String.serializer(), key(name))
        fun double(name: String) = json.decodeFromJsonElement(Double.serializer(), key(name))
        fun bool(name: String) = json.decodeFromJsonElement(Boolean.serializer(), key(name))
        val subject = string("subjectId")
        return when (string("type")) {
            "gnssOutage" -> ScenarioInput.gnssOutage(subjectId = subject, active = bool("active"))
            "gnssJump" -> ScenarioInput.gnssJump(subjectId = subject, dx = double("dx"), dz = double("dz"))
            "gnssDrift" -> ScenarioInput.gnssDrift(subjectId = subject, metersPerSecond = double("metersPerSecond"),
                bearingDegrees = double("bearingDegrees"))
            "gnssClear" -> ScenarioInput.gnssClear(subjectId = subject)
            "peerLink" -> ScenarioInput.peerLink(subjectId = subject, peerId = string("peerId"), up = bool("up"))
            else -> throw GhostCoreContractError.invalid("scenario.input.type")
        }
    }
}

/**
 * The GNSS faults active on one phone. Applied to each raw fix before any engine sees it; a
 * changed fix is marked simulated, so everything derived from it carries the SIMULATED badge.
 *
 * A Swift struct with mutating methods: copy with [copy] where Swift relies on a value copy.
 */
class GNSSFaults() {
    /** Swift's `(start:, metersPerSecond:, bearing:)` tuple; `bearing` in radians. */
    data class Drift(val start: Double, val metersPerSecond: Double, val bearing: Double)

    var outage: Boolean = false
        private set
    var jump: FloorVector = FloorVector(x = 0.0, z = 0.0)
        private set
    var drift: Drift? = null
        private set

    val isActive: Boolean get() = outage || jump != FloorVector(x = 0.0, z = 0.0) || drift != null

    fun copy(): GNSSFaults {
        val other = GNSSFaults()
        other.outage = outage
        other.jump = jump
        other.drift = drift
        return other
    }

    fun apply(input: ScenarioInput, t: Double) {
        when (input) {
            is ScenarioInput.gnssOutage -> outage = input.active
            is ScenarioInput.gnssJump -> jump = FloorVector(x = jump.x + input.dx, z = jump.z + input.dz)
            is ScenarioInput.gnssDrift -> drift = Drift(t, input.metersPerSecond, input.bearingDegrees * Math.PI / 180)
            is ScenarioInput.gnssClear -> {
                outage = false
                jump = FloorVector(x = 0.0, z = 0.0)
                drift = null
            }
            is ScenarioInput.peerLink -> Unit
        }
    }

    /** The shift at time `t`. */
    fun offset(t: Double): FloorVector {
        var x = jump.x
        var z = jump.z
        val drift = drift
        if (drift != null) {
            val d = drift.metersPerSecond * maxOf(0.0, t - drift.start)
            x += d * sin(drift.bearing)
            z += d * cos(drift.bearing)
        }
        return FloorVector(x = x, z = z)
    }

    /** The fix as the faulty receiver would report it, or nil during an outage. */
    fun apply(to: PositionEstimate): PositionEstimate? {
        val fix = to
        if (outage) return null
        val position = fix.position
        if (!isActive || position == null) return fix
        val shift = offset(fix.timestamp)
        val limit = GhostCoreContract.maxCoordinate
        val moved = Position(x = minOf(limit, maxOf(-limit, position.x + shift.x)), y = position.y,
            z = minOf(limit, maxOf(-limit, position.z + shift.z)))
        val p = fix.provenance
        return PositionEstimate(subjectId = fix.subjectId, timestamp = fix.timestamp, frameId = fix.frameId, kind = fix.kind,
            method = fix.method, position = moved, positionMode = fix.positionMode,
            uncertainty = fix.uncertainty, heading = fix.heading, headingSigma = fix.headingSigma,
            velocity = fix.velocity, lastAbsoluteAt = fix.lastAbsoluteAt, source = fix.source,
            freshness = fix.freshness,
            provenance = Provenance(producerId = p.producerId, algorithm = p.algorithm, inputs = p.inputs,
                contributors = p.contributors, gnssDependent = p.gnssDependent, simulated = true))
    }

    override fun equals(other: Any?): Boolean =
        other is GNSSFaults && outage == other.outage && jump == other.jump &&
            drift?.start == other.drift?.start && drift?.metersPerSecond == other.drift?.metersPerSecond &&
            drift?.bearing == other.drift?.bearing

    override fun hashCode(): Int = 31 * (31 * outage.hashCode() + jump.hashCode()) + (drift?.hashCode() ?: 0)
}

/**
 * A scripted test: phones with true paths (used only by the headless world), timed raw inputs,
 * and expectations. Files live in contract/scenarios/.
 */
@Serializable
data class Scenario(
    val id: String,
    val title: String,
    val summary: String,
    val frameId: String,
    val seed: UInt,
    val duration: Double,
    val phones: List<Phone>,
    val steps: List<Step>,
    val expectations: List<ScenarioExpectation>,
) {
    @Serializable
    data class Waypoint(
        val t: Double,
        val x: Double,
        val z: Double,
    )

    @Serializable
    data class Phone(
        val id: String,
        val label: String,
        /** False for a phone that never has GNSS (indoors, or GPS off). */
        val hasGNSS: Boolean,
        /** Claimed 68 % accuracy of its fixes, metres; the true error follows it. */
        val accuracy68: Double,
        /** True path; linear between waypoints, held after the last one. */
        val waypoints: List<Waypoint>,
    )

    @Serializable
    data class Step(
        val at: Double,
        val input: ScenarioInput,
        val caption: String? = null,
    )

    fun truth(of: String, t: Double): FloorVector? {
        val points = phones.firstOrNull { it.id == of }?.waypoints ?: return null
        val first = points.firstOrNull() ?: return null
        if (t <= first.t) return FloorVector(x = first.x, z = first.z)
        for ((a, b) in points.zip(points.drop(1))) {
            if (t > b.t) continue
            val f = if (b.t > a.t) (t - a.t) / (b.t - a.t) else 1.0
            return FloorVector(x = a.x + (b.x - a.x) * f, z = a.z + (b.z - a.z) * f)
        }
        return points.lastOrNull()?.let { FloorVector(x = it.x, z = it.z) }
    }
}

/** One checkable claim about a scenario run, seen from `observer`'s pipeline. */
@Serializable
data class ScenarioExpectation(
    val id: String,
    val text: String,
    val check: Check,
    val observer: String,
    val subject: String,
    /** Window start, seconds into the scenario. */
    val from: Double,
    /** Window end. */
    val to: Double,
    /** Pass when the check holds at least once within this many seconds after `from`. */
    val within: Double? = null,
    /** Pass when the check holds in at least this fraction of the seconds in the window. */
    val minFraction: Double? = null,
    val values: List<String>? = null,
    /** Engines the claim is about; with one missing the result is "pending", never "pass". */
    val requires: List<String>,
    /** A failure fails the gate. Acceptance thresholds still being worked towards are not gating. */
    val gate: Boolean,
) {
    @Serializable
    enum class Check(val rawValue: String) {
        /** The subject's integrity status as the observer sees it (its own, or relayed) is one of `values`. */
        integrityStatus("integrityStatus"),
        /** The kind of the subject's selected position is one of `values`. */
        positionKind("positionKind"),
        /** The subject's true position lies inside the selected position's r95. */
        truthInsideR95("truthInsideR95"),
        /** The subject is shown as a prediction. */
        predictionShown("predictionShown"),
        /** The subject is not shown as a prediction. */
        predictionNotShown("predictionNotShown"),
        /** The observer's own estimate does not use the subject as an anchor. */
        notAnchoredBy("notAnchoredBy"),
        /**
         * No selected position anywhere is presented as measured unless its source is GNSS or UWB
         * and its provenance is marked simulated whenever a fault is active.
         */
        simulatedMarked("simulatedMarked"),
    }
}

/** What a running scenario shows in the app. */
data class ScenarioState(
    val scenarioId: String,
    val title: String,
    val elapsed: Double,
    val stepIndex: Int,
    val caption: String?,
    val isRunning: Boolean,
)
