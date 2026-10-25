package com.hackathonmapper.meshcore

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.UUID
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.sqrt
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Required
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
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
 * GhostCore shared contract: the records the relay, positioning, integrity, prediction and UI
 * modules exchange. ARCHITECTURE.md explains who produces and consumes each one;
 * website/shared/ghostcore.ts mirrors these types and contract/fixtures/ holds golden JSON both
 * sides must accept.
 *
 * Every record carries the same six things:
 * - `timestamp`: Unix seconds on the clock of the phone that produced the record, at which the
 *   value holds (for a `Prediction`, the time it predicts). Never subtract two phones' clocks.
 * - `frameId`: the shared metric frame, e.g. `hervanta-v1`: metres, x east, y up, z north.
 * - `source`: the kind of evidence behind the record.
 * - an uncertainty of its own type; every position carries `r95`, the horizontal radius holding
 *   95 % of the belief.
 * - `freshness`: how old the record already was when it was handed on, and how long it stays usable.
 * - `provenance`: who produced it, with which algorithm, from which inputs. The `simulated` and
 *   `gnssDependent` flags propagate to everything derived from such an input.
 *
 * Kotlin notes: every non-optional field is required on decode (`@Required` where the Kotlin
 * constructor has a default), as in Swift's synthesized `Decodable`; decoding errors are
 * [SerializationException] (Swift: `DecodingError`), rule violations [GhostCoreContractError].
 */
object GhostCoreContract {
    const val version = 1

    const val maxInputs = 16
    const val maxContributors = 16
    val maxReasons: Int get() = IntegrityAssessment.Reason.entries.size
    const val maxEvidence = 16
    const val maxCandidates = 8
    const val maxCloudPoints = 128
    const val maxRawSamples = 16
    const val maxObservationsPerMessage = 16
    const val maxTextLength = 160
    const val maxAlgorithmLength = 64
    /** Predictions further ahead than this are not useful and are not accepted. */
    const val maxHorizonSeconds = 3_600.0
    /**
     * Positions share the dashboard's coordinate limit; radii may grow past the dashboard's accuracy
     * limit (a long prediction), so mapping to a `DeviceUpdate` clamps them.
     */
    val maxCoordinate: Double = DashboardContract.maxCoordinate
    const val maxRadius = 10_000.0
    /** A relayed message must fit inside one mesh packet (4 KiB) together with its envelope. */
    const val maxRelayBytes = 3_072

    /** ASCII letters, digits and `._-`, 1 to 64 UTF-8 bytes (the dashboard's frame ID pattern). */
    fun isValidFrameId(value: String): Boolean =
        value.isNotEmpty() && value.encodeToByteArray().size <= 64 &&
            value.all { (it in 'A'..'Z') || (it in 'a'..'z') || (it in '0'..'9') || it == '.' || it == '_' || it == '-' }
}

sealed class GhostCoreContractError(message: String? = null) : Exception(message) {
    /** The record breaks a contract rule; `field` names the first rule that failed. */
    data class invalid(val field: String) : GhostCoreContractError("invalid($field)")

    data object tooLarge : GhostCoreContractError()
}

private fun requireContract(condition: Boolean, field: String) {
    if (!condition) throw GhostCoreContractError.invalid(field)
}

private fun isContractText(value: String?): Boolean = value?.let { it.length <= GhostCoreContract.maxTextLength } ?: true

private fun isContractCoordinate(value: Double): Boolean = value.isFinite() && abs(value) <= GhostCoreContract.maxCoordinate

private fun isContractRadius(value: Double): Boolean = value.isFinite() && value >= 0 && value <= GhostCoreContract.maxRadius

/** Swift `UUID(uuidString:)`: exactly 8-4-4-4-12 hex digits, either case. */
private val ghostCoreContractUUIDPattern =
    Regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")

// MARK: - Shared parts

/** The kind of evidence behind a record. */
@Serializable
enum class EvidenceSource(val rawValue: String) {
    @SerialName("gnss") gnss("gnss"),
    @SerialName("bluetooth") bluetooth("bluetooth"),
    @SerialName("uwb") uwb("uwb"),
    @SerialName("inertial") inertial("inertial"),
    @SerialName("manual") manual("manual"),
    @SerialName("fusion") fusion("fusion"),
    @SerialName("prediction") prediction("prediction");

    companion object {
        fun fromRawValue(rawValue: String): EvidenceSource? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/**
 * A point or a vector on the floor plane of the shared frame: x east, z north, metres
 * (m/s for a velocity). Equality follows Swift's `Double ==` (0.0 equals -0.0).
 */
@Serializable
data class FloorVector(
    val x: Double,
    val z: Double,
) {
    constructor(point: FloorPoint) : this(x = point.x, z = point.z)

    val length: Double get() = sqrt(x * x + z * z)

    override fun equals(other: Any?): Boolean = other is FloorVector && x == other.x && z == other.z

    override fun hashCode(): Int = 31 * (x + 0.0).hashCode() + (z + 0.0).hashCode()
}

/**
 * How old a record already was when it was handed on, and how long it stays usable. Ages are
 * measured on one clock at a time: the producer sets `ageAtHandoff` (e.g. a GNSS fix's age when
 * published), each relay adds the time it held the record, and a receiver adds the time since it
 * received the record on its own clock.
 */
@Serializable
data class Freshness(
    /** Seconds. */
    @Required val ageAtHandoff: Double = 0.0,
    /** Seconds of age after which the record must not be shown or used as current. */
    val maxAge: Double,
) {
    /** Age now, given when this phone received (or produced) the record on its own clock. */
    fun age(receivedAt: Double, now: Double): Double = ageAtHandoff + maxOf(0.0, now - receivedAt)

    fun isStale(receivedAt: Double, now: Double): Boolean = age(receivedAt, now) > maxAge

    /** The same record handed on after this phone held it for `heldFor` seconds. */
    fun handedOn(heldFor: Double): Freshness = Freshness(ageAtHandoff = ageAtHandoff + maxOf(0.0, heldFor), maxAge = maxAge)

    fun validate() {
        requireContract(ageAtHandoff.isFinite() && ageAtHandoff >= 0, "freshness.ageAtHandoff")
        requireContract(maxAge.isFinite() && maxAge > 0 && maxAge <= 86_400, "freshness.maxAge")
    }
}

/** One input a producer considered: used, or rejected with a reason. */
@Serializable
data class ProvenanceInput(
    val source: EvidenceSource,
    /** The device or record the input came from, when it has one. */
    val id: String? = null,
    /** Seconds old when it was considered. */
    val age: Double? = null,
    @Required val used: Boolean = true,
    /** Why it was rejected, or how it was used. Short, human readable. */
    val reason: String? = null,
)

/**
 * Who produced a record, how, and from what. Swift's `contributors: [String]? = nil` defaults to
 * `[producerId]`; here the default is written out.
 */
@Serializable
data class Provenance(
    /** App device ID of the phone that produced the record. */
    val producerId: String,
    /** "name@version", e.g. "bluetooth-estimator@1", "gnss-integrity@1", "kalman-cv@1". */
    val algorithm: String,
    @Required val inputs: List<ProvenanceInput> = emptyList(),
    /**
     * Device IDs that contributed at any depth, including the producer. A phone drops a relayed
     * estimate that already contains its own ID, so estimates cannot anchor themselves in a loop.
     */
    @Required val contributors: List<String> = listOf(producerId),
    /** The record depends on GNSS somewhere upstream, so it is not independent evidence about GNSS. */
    val gnssDependent: Boolean,
    /** The record comes from a simulator or scenario, or from anything that did. Never dropped. */
    @Required val simulated: Boolean = false,
) {
    fun contains(device: String): Boolean = contributors.contains(device)

    fun validate() {
        requireContract(DashboardContract.isValidId(producerId), "provenance.producerId")
        requireContract(algorithm.isNotEmpty() && algorithm.length <= GhostCoreContract.maxAlgorithmLength,
            "provenance.algorithm")
        requireContract(inputs.size <= GhostCoreContract.maxInputs, "provenance.inputs")
        for (input in inputs) {
            requireContract(input.id?.let { DashboardContract.isValidId(it) } ?: true, "provenance.inputs.id")
            requireContract(input.age?.let { it.isFinite() && it >= 0 } ?: true, "provenance.inputs.age")
            requireContract(isContractText(input.reason), "provenance.inputs.reason")
        }
        requireContract(contributors.firstOrNull() == producerId && contributors.size <= GhostCoreContract.maxContributors &&
            contributors.toSet().size == contributors.size &&
            contributors.all { DashboardContract.isValidId(it) }, "provenance.contributors")
    }

    companion object {
        /**
         * Provenance for a record derived from `upstream` records: the flags are inherited, and the
         * contributors are merged (the producer first, then upstream in order, capped).
         */
        fun derived(
            producerId: String,
            algorithm: String,
            inputs: List<ProvenanceInput> = emptyList(),
            from: List<Provenance>,
            usesGNSS: Boolean = false,
            simulated: Boolean = false,
        ): Provenance {
            val contributors = mutableListOf(producerId)
            for (id in from.flatMap { it.contributors }) {
                if (contributors.contains(id)) continue
                if (contributors.size >= GhostCoreContract.maxContributors) break
                contributors.add(id)
            }
            return Provenance(producerId = producerId, algorithm = algorithm, inputs = inputs, contributors = contributors,
                gnssDependent = usesGNSS || from.any { it.gnssDependent },
                simulated = simulated || from.any { it.simulated })
        }
    }
}

/** Floor-plane covariance in m² (x east, z north). */
@Serializable
data class FloorCovariance(
    val xx: Double,
    val xz: Double,
    val zz: Double,
) {
    /** Larger eigenvalue, m². */
    val largestVariance: Double
        get() {
            val mean = (xx + zz) / 2
            val spread = sqrt(((xx - zz) / 2) * ((xx - zz) / 2) + xz * xz)
            return mean + spread
        }

    val isValid: Boolean
        get() = listOf(xx, xz, zz).all { it.isFinite() } && xx >= 0 && zz >= 0 &&
            xx * zz - xz * xz >= -1e-9 * maxOf(1.0, xx * zz)
}

/** Uncertainty of a position on the floor plane. */
@Serializable
data class PositionUncertainty(
    /** Metres around the position holding 95 % of the belief. Required on every position. */
    val r95: Double,
    /** A ring or several separate spots: the position is not a good single guess. */
    @Required val ambiguous: Boolean = false,
    val covariance: FloorCovariance? = null,
    /** Metres, 95 %, when height was estimated; nil means the height is assumed. */
    val vertical95: Double? = null,
) {
    /** 95 % radius from a covariance: the circle around the larger axis of the 95 % ellipse. */
    constructor(covariance: FloorCovariance, ambiguous: Boolean = false) :
        this(r95 = r95(fromSigma = sqrt(covariance.largestVariance)), ambiguous = ambiguous, covariance = covariance)

    fun validate() {
        requireContract(isContractRadius(r95), "uncertainty.r95")
        requireContract(covariance?.isValid ?: true, "uncertainty.covariance")
        requireContract(vertical95?.let { isContractRadius(it) } ?: true, "uncertainty.vertical95")
    }

    companion object {
        /** For a circular Gaussian with per-axis standard deviation sigma, P(r < R) = 1 - exp(-R²/2σ²). */
        val sigmaTo95: Double = sqrt(-2 * ln(0.05))
        internal val sigmaTo68: Double = sqrt(-2 * ln(0.32))

        fun r95(fromSigma: Double): Double = fromSigma * sigmaTo95

        /**
         * iOS `horizontalAccuracy` is treated as a 68 % radius (Apple does not state its level).
         * Kotlin cannot overload on parameter names alone, so the unused trailing parameter keeps
         * the Swift call `r95(fromRadius68 = x)` apart from `r95(fromSigma = x)`; always call it
         * with the `fromRadius68` name.
         */
        fun r95(fromRadius68: Double, @Suppress("UNUSED_PARAMETER") radius68: Unit = Unit): Double =
            fromRadius68 * sigmaTo95 / sigmaTo68
    }
}

/** Fields every GhostCore record has. */
interface GhostRecord {
    val timestamp: Double
    val frameId: String
    val source: EvidenceSource
    val freshness: Freshness
    val provenance: Provenance
    fun validate()

    fun isStale(receivedAt: Double, now: Double): Boolean = freshness.isStale(receivedAt, now)
}

internal fun GhostRecord.validateCommon() {
    requireContract(timestamp.isFinite() && timestamp > 0, "timestamp")
    requireContract(GhostCoreContract.isValidFrameId(frameId), "frameId")
    freshness.validate()
    provenance.validate()
}

// MARK: - PeerObservation

/**
 * What one phone heard of one peer over Bluetooth, as a snapshot at most once a second. It carries
 * the raw RSSI samples since the previous snapshot so the positioning engine can filter them
 * itself. RSSI is link quality: it has no distance field; ranges belong to the positioning
 * engine's calibrated model.
 *
 * `source` is always `bluetooth` (Swift sets it in init); it is the trailing constructor parameter.
 */
@Serializable
data class PeerObservation(
    val observerId: String,
    /** The peer's app device ID from its Hello; nil when it was only heard advertising. */
    val peerId: String?,
    /** Time of the newest sample. */
    override val timestamp: Double,
    override val frameId: String,
    val channel: Channel,
    val linkState: LinkState,
    /** dBm, oldest first, since the previous snapshot. */
    val rawRSSI: List<Double>,
    /** Seconds covered by `rawRSSI`. */
    val window: Double,
    /** dBm, the observer's smoothed value. */
    val smoothedRSSI: Double?,
    val uncertainty: Uncertainty,
    val txPower: Int? = null,
    /** Hardware model string of the peer (e.g. "iPhone16,1"), for per-model calibration. */
    val peerModel: String? = null,
    override val freshness: Freshness,
    override val provenance: Provenance,
    @Required override val source: EvidenceSource = EvidenceSource.bluetooth,
) : GhostRecord {
    @Serializable
    enum class Channel(val rawValue: String) {
        /** readRSSI on a connected link (central side). */
        @SerialName("connection") connection("connection"),
        /** Advertisement RSSI (irregular; coalesced by iOS). */
        @SerialName("advertisement") advertisement("advertisement"),
    }

    @Serializable
    enum class LinkState(val rawValue: String) {
        /** Subscribed and the peer's Hello arrived. */
        @SerialName("ready") ready("ready"),
        @SerialName("connecting") connecting("connecting"),
        /** Heard advertising, no link. */
        @SerialName("advertisementOnly") advertisementOnly("advertisementOnly"),
        /** The link closed; the samples are the last ones heard. */
        @SerialName("lost") lost("lost"),
    }

    /** RSSI spread of this snapshot. */
    @Serializable
    data class Uncertainty(
        /** dB standard deviation over the observer's recent samples; nil with fewer than two. */
        val stdDevDb: Double?,
        /** Samples the observer has heard of this peer in its smoothing window. */
        val sampleCount: Int,
    )

    override fun validate() {
        validateCommon()
        val low = DashboardContract.rssiRange.first.toDouble()
        val high = DashboardContract.rssiRange.last.toDouble()
        val inRange = { value: Double -> value in low..high }
        requireContract(source == EvidenceSource.bluetooth, "source")
        requireContract(DashboardContract.isValidId(observerId) && provenance.producerId == observerId, "observerId")
        requireContract(peerId?.let { DashboardContract.isValidId(it) && it != observerId } ?: true, "peerId")
        requireContract(rawRSSI.size <= GhostCoreContract.maxRawSamples && rawRSSI.all(inRange), "rawRSSI")
        requireContract(window.isFinite() && window >= 0 && window <= 60, "window")
        requireContract(smoothedRSSI?.let(inRange) ?: true, "smoothedRSSI")
        requireContract(uncertainty.stdDevDb?.let { it.isFinite() && it >= 0 && it <= 60 } ?: true, "uncertainty.stdDevDb")
        requireContract(uncertainty.sampleCount >= rawRSSI.size, "uncertainty.sampleCount")
        requireContract(txPower?.let { it in -127..20 } ?: true, "txPower")
        requireContract(peerModel?.let { it.isNotEmpty() && it.length <= 32 } ?: true, "peerModel")
    }
}

// MARK: - PositionEstimate

@Serializable
enum class PositionMode(val rawValue: String) {
    /** y is 0 and the height is assumed. */
    @SerialName("floor") floor("floor"),
    /** y was estimated. */
    @SerialName("3d") threeD("3d");

    companion object {
        fun fromRawValue(rawValue: String): PositionMode? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/** Where a phone is, with what certainty, and how that is known. */
@Serializable
data class PositionEstimate(
    /** The phone this position is about. */
    val subjectId: String,
    override val timestamp: Double,
    override val frameId: String,
    val kind: Kind,
    val method: Method,
    /** Nil only when `kind` is `unavailable`. */
    val position: Position?,
    @Required val positionMode: PositionMode = PositionMode.floor,
    val uncertainty: PositionUncertainty,
    /** The separate spots of an ambiguous belief. */
    val candidates: List<FloorVector>? = null,
    /** Radians from +z (north) toward +x (east). */
    val heading: Double? = null,
    val headingSigma: Double? = null,
    /** m/s on the floor plane. */
    val velocity: FloorVector? = null,
    /** Producer-clock time of the last absolute constraint (GNSS, UWB or an anchor) behind this estimate. */
    val lastAbsoluteAt: Double? = null,
    override val source: EvidenceSource,
    override val freshness: Freshness,
    override val provenance: Provenance,
) : GhostRecord {
    /**
     * How the position may be presented. Only `measured` is a measured coordinate, and a GNSS one
     * only together with a `trusted` IntegrityAssessment.
     */
    @Serializable
    enum class Kind(val rawValue: String) {
        /** A direct fix: GNSS or UWB. */
        @SerialName("measured") measured("measured"),
        /** Inferred from peers and/or motion. */
        @SerialName("estimated") estimated("estimated"),
        /** No fresh evidence; see `Prediction` for the full record. */
        @SerialName("predicted") predicted("predicted"),
        /** Typed by a person: a fixed anchor or a pinned spot. */
        @SerialName("declared") declared("declared"),
        /** Nothing usable; `position` is nil. */
        @SerialName("unavailable") unavailable("unavailable"),
    }

    @Serializable
    enum class Method(val rawValue: String) {
        @SerialName("gnss") gnss("gnss"),
        @SerialName("uwb") uwb("uwb"),
        @SerialName("multilateration") multilateration("multilateration"),
        @SerialName("proximity") proximity("proximity"),
        @SerialName("particle") particle("particle"),
        @SerialName("deadReckoning") deadReckoning("deadReckoning"),
        @SerialName("fusion") fusion("fusion"),
        @SerialName("manual") manual("manual"),
        @SerialName("prediction") prediction("prediction"),
        @SerialName("none") none("none"),
    }

    /**
     * The source the dashboard upload contract can express. Estimates and predictions are `none`:
     * the dashboard places such phones itself and never shows them as measured. Mirrored by
     * `dashboardSource` in website/shared/ghostcore.ts.
     */
    val dashboardSource: PositionSource
        get() = when {
            kind == Kind.measured && method == Method.gnss -> PositionSource.gps
            kind == Kind.measured && method == Method.uwb -> PositionSource.uwb
            kind == Kind.measured || kind == Kind.declared -> PositionSource.manual
            else -> PositionSource.none
        }

    override fun validate() {
        validateCommon()
        requireContract(DashboardContract.isValidId(subjectId), "subjectId")
        uncertainty.validate()
        when (kind) {
            Kind.measured -> requireContract(method in listOf(Method.gnss, Method.uwb) && source.rawValue == method.rawValue,
                "kind.measured")
            Kind.estimated -> requireContract(
                method in listOf(Method.multilateration, Method.proximity, Method.particle, Method.deadReckoning, Method.fusion) &&
                    source in listOf(EvidenceSource.bluetooth, EvidenceSource.uwb, EvidenceSource.inertial, EvidenceSource.fusion),
                "kind.estimated")
            Kind.predicted -> requireContract(method == Method.prediction && source == EvidenceSource.prediction, "kind.predicted")
            Kind.declared -> requireContract(method == Method.manual && source == EvidenceSource.manual, "kind.declared")
            Kind.unavailable -> requireContract(method == Method.none && position == null, "kind.unavailable")
        }
        if (position != null) {
            requireContract(listOf(position.x, position.y, position.z).all(::isContractCoordinate), "position")
            requireContract(positionMode == PositionMode.threeD || position.y == 0.0, "positionMode")
        } else {
            requireContract(kind == Kind.unavailable, "position")
        }
        requireContract(method != Method.gnss || provenance.gnssDependent, "provenance.gnssDependent")
        if (candidates != null) {
            requireContract(uncertainty.ambiguous && candidates.size <= GhostCoreContract.maxCandidates &&
                candidates.all { isContractCoordinate(it.x) && isContractCoordinate(it.z) }, "candidates")
        }
        requireContract(heading?.isFinite() ?: true, "heading")
        requireContract(headingSigma?.let { it.isFinite() && it >= 0 } ?: true, "headingSigma")
        requireContract(velocity?.let { it.x.isFinite() && it.z.isFinite() && it.length <= 100 } ?: true, "velocity")
        requireContract(lastAbsoluteAt?.let { it.isFinite() && it <= timestamp + 1 } ?: true, "lastAbsoluteAt")
    }
}

// MARK: - IntegrityAssessment

/**
 * Whether this phone's GNSS can be believed right now. Phone data can show that GNSS behaves
 * impossibly or disagrees with independent evidence; it cannot prove spoofing, so the type has no
 * way to say "spoofed".
 */
@Serializable
data class IntegrityAssessment(
    /** The phone whose GNSS was judged. */
    val subjectId: String,
    /** When the assessment was made. */
    override val timestamp: Double,
    override val frameId: String,
    val status: Status,
    /** 0 = do not believe, 1 = fully consistent. */
    val trustScore: Double,
    val uncertainty: TrustInterval,
    @Required val reasons: List<Reason> = emptyList(),
    @Required val evidence: List<Evidence> = emptyList(),
    /** The raw fix that was judged, in the frame, even when rejected, so a UI can show raw vs estimate. */
    val evaluatedFix: PositionEstimate? = null,
    /**
     * Smallest GNSS offset (m) the active independent checks would flag right now; nil when
     * unbounded. The honest answer to "how far could GPS move this phone without anyone noticing".
     */
    val minimumDetectableOffsetMeters: Double? = null,
    /** One readable line for the UI, e.g. "GPS jumped 412 m in 2 s". */
    val summary: String? = null,
    @Required override val source: EvidenceSource = EvidenceSource.fusion,
    override val freshness: Freshness,
    override val provenance: Provenance,
) : GhostRecord {
    @Serializable
    enum class Status(val rawValue: String) {
        /**
         * No anomaly, and at least one GNSS-independent check (inertial, a surveyed anchor, or
         * position evidence with gnssDependent false) agrees. The only status that may anchor others.
         */
        @SerialName("trusted") trusted("trusted"),
        /** No anomaly, but poor accuracy or an aging fix. */
        @SerialName("degraded") degraded("degraded"),
        /** An anomaly; not used to anchor others. */
        @SerialName("suspect") suspect("suspect"),
        /** An anomaly bad enough not to use the fix at all. */
        @SerialName("rejected") rejected("rejected"),
        /** No fix, or one too old or invalid. */
        @SerialName("unavailable") unavailable("unavailable"),
        /**
         * Self-consistent, but nothing independent confirms it. Agreement with GNSS-placed peers
         * never upgrades this to trusted.
         */
        @SerialName("insufficientEvidence") insufficientEvidence("insufficientEvidence"),
    }

    @Serializable
    enum class Reason(val rawValue: String) {
        @SerialName("noFix") noFix("noFix"),
        @SerialName("staleFix") staleFix("staleFix"),
        @SerialName("invalidFix") invalidFix("invalidFix"),
        @SerialName("timestampInconsistent") timestampInconsistent("timestampInconsistent"),
        @SerialName("degradedAccuracy") degradedAccuracy("degradedAccuracy"),
        @SerialName("accuracyInconsistent") accuracyInconsistent("accuracyInconsistent"),
        @SerialName("impossibleSpeed") impossibleSpeed("impossibleSpeed"),
        @SerialName("impossibleAcceleration") impossibleAcceleration("impossibleAcceleration"),
        @SerialName("positionJump") positionJump("positionJump"),
        @SerialName("inertialDisagreement") inertialDisagreement("inertialDisagreement"),
        @SerialName("slowDrift") slowDrift("slowDrift"),
        @SerialName("peerDisagreement") peerDisagreement("peerDisagreement"),
        @SerialName("independentEvidenceDisagreement") independentEvidenceDisagreement("independentEvidenceDisagreement"),
        @SerialName("peerEvidenceNotIndependent") peerEvidenceNotIndependent("peerEvidenceNotIndependent"),
        @SerialName("insufficientEvidence") insufficientEvidence("insufficientEvidence"),
        /**
         * GNSS came back after a rejection while this phone's own reference had grown too loose to
         * tell a real return from a new offset; capped at insufficientEvidence until independent
         * position evidence agrees.
         */
        @SerialName("continuityLost") continuityLost("continuityLost"),
        /** The checks pass again but trust is still climbing after an anomaly. */
        @SerialName("recovering") recovering("recovering"),
    }

    /** One check the engine ran. */
    @Serializable
    data class Evidence(
        /**
         * freshness, accuracy, timing, speed, acceleration, jump, inertial, peerProximity,
         * anchorProximity or positionEvidence.
         */
        val check: String,
        val observed: Double? = null,
        val threshold: Double? = null,
        /** Unit of `observed` and `threshold`, e.g. "m/s", "m". */
        val unit: String? = null,
        /** 1 = fully consistent, 0 = impossible. */
        val score: Double,
        /** False when the evidence itself depends on GNSS (e.g. a peer placed by GPS). */
        val independent: Boolean,
        val reason: Reason? = null,
    )

    /**
     * Coverage heuristic for the trust score: `upper` is the score; `lower` is 0 with no
     * GNSS-independent check active (nothing rules out a slow or common-mode error), half the score
     * with only relative (inertial) or only absolute (anchor, independent position) evidence, and
     * the score with both.
     */
    @Serializable
    data class TrustInterval(
        val lower: Double,
        val upper: Double,
    )

    /** Only trusted GNSS may anchor other phones. */
    val mayAnchorOthers: Boolean get() = status == Status.trusted

    /** Time of the judged fix. */
    val fixTimestamp: Double? get() = evaluatedFix?.timestamp

    override fun validate() {
        validateCommon()
        requireContract(DashboardContract.isValidId(subjectId), "subjectId")
        requireContract(trustScore in 0.0..1.0, "trustScore")
        requireContract(uncertainty.lower >= 0 && uncertainty.lower <= trustScore && trustScore <= uncertainty.upper &&
            uncertainty.upper <= 1, "uncertainty")
        requireContract(reasons.size <= GhostCoreContract.maxReasons && reasons.toSet().size == reasons.size, "reasons")
        requireContract(status !in listOf(Status.suspect, Status.rejected, Status.degraded) || reasons.isNotEmpty(),
            "reasons.required")
        requireContract(evidence.size <= GhostCoreContract.maxEvidence, "evidence")
        for (item in evidence) {
            requireContract(item.check.isNotEmpty() && item.check.length <= 48, "evidence.check")
            requireContract(item.score in 0.0..1.0, "evidence.score")
            requireContract((item.observed?.isFinite() ?: true) && (item.threshold?.isFinite() ?: true), "evidence.value")
            requireContract(item.unit?.let { it.length <= 16 } ?: true, "evidence.unit")
        }
        if (evaluatedFix != null) {
            evaluatedFix.validate()
            requireContract(evaluatedFix.method == PositionEstimate.Method.gnss && evaluatedFix.subjectId == subjectId &&
                evaluatedFix.frameId == frameId, "evaluatedFix")
        }
        requireContract(status != Status.unavailable || evaluatedFix == null, "evaluatedFix.unavailable")
        requireContract(minimumDetectableOffsetMeters?.let { isContractRadius(it) } ?: true, "minimumDetectableOffsetMeters")
        requireContract(isContractText(summary), "summary")
    }
}

// MARK: - MotionObservation

/** How this phone moved over a short interval, from its own sensors. */
@Serializable
data class MotionObservation(
    val subjectId: String,
    /** End of the interval. */
    override val timestamp: Double,
    /** Seconds; the interval starts at `timestamp - interval`. */
    val interval: Double,
    override val frameId: String,
    val method: Method,
    val steps: Int? = null,
    /** Metres moved over the interval in the frame (x east, z north). */
    val displacement: FloorVector? = null,
    /** Radians from +z (north) toward +x (east), at the end of the interval. */
    val heading: Double? = null,
    val stationary: Boolean,
    val uncertainty: Uncertainty,
    @Required override val source: EvidenceSource = EvidenceSource.inertial,
    override val freshness: Freshness,
    override val provenance: Provenance,
) : GhostRecord {
    @Serializable
    enum class Method(val rawValue: String) {
        @SerialName("pedometer") pedometer("pedometer"),
        @SerialName("stepDetector") stepDetector("stepDetector"),
        @SerialName("deviceMotion") deviceMotion("deviceMotion"),
        @SerialName("visualOdometry") visualOdometry("visualOdometry"),
    }

    @Serializable
    data class Uncertainty(
        /** Metres, 95 % radius of the displacement's end point. */
        val displacementR95: Double?,
        /** Radians, 1-sigma of `heading`. */
        val headingSigma: Double?,
    )

    override fun validate() {
        validateCommon()
        requireContract(DashboardContract.isValidId(subjectId), "subjectId")
        requireContract(source in listOf(EvidenceSource.inertial, EvidenceSource.fusion), "source")
        requireContract(interval.isFinite() && interval > 0 && interval <= 60, "interval")
        requireContract(steps?.let { it in 0..1_000 } ?: true, "steps")
        // 12 m/s is far beyond walking; it only rejects garbage.
        requireContract(displacement?.let { it.x.isFinite() && it.z.isFinite() && it.length <= 12 * interval } ?: true,
            "displacement")
        requireContract(heading?.let { it.isFinite() && abs(it) <= 2 * Math.PI } ?: true, "heading")
        requireContract(!stationary || (steps ?: 0) == 0, "stationary")
        requireContract(uncertainty.displacementR95?.let { isContractRadius(it) } ?: true, "uncertainty.displacementR95")
        requireContract(uncertainty.headingSigma?.let { it.isFinite() && it >= 0 } ?: true, "uncertainty.headingSigma")
    }
}

// MARK: - Prediction

/**
 * Where a phone has probably gone since it was last observed. Never presented as live: it ages
 * from `lastObservedAt`, and a fresh observation of the subject replaces it.
 *
 * `source` is always `prediction` (Swift sets it in init); it is the trailing constructor parameter.
 */
@Serializable
data class Prediction(
    val subjectId: String,
    /** The time predicted. */
    override val timestamp: Double,
    override val frameId: String,
    val method: Method,
    /** Producer-clock time of the last observation the prediction starts from. */
    val lastObservedAt: Double,
    val lastObservedPosition: Position,
    /** Most likely spot. */
    val center: Position,
    val uncertainty: PositionUncertainty,
    /** A sample of the belief for drawing. Local only: a RelayMessage never carries it. */
    val cloud: List<FloorVector>? = null,
    override val freshness: Freshness,
    override val provenance: Provenance,
    @Required override val source: EvidenceSource = EvidenceSource.prediction,
) : GhostRecord {
    @Serializable
    enum class Method(val rawValue: String) {
        @SerialName("stationary") stationary("stationary"),
        @SerialName("constantVelocity") constantVelocity("constantVelocity"),
        @SerialName("kalman") kalman("kalman"),
        @SerialName("movementModel") movementModel("movementModel"),
    }

    /** Seconds since the subject was last observed. */
    val horizon: Double get() = timestamp - lastObservedAt

    /** The prediction as a position, for views and consumers that only take positions. */
    val asPositionEstimate: PositionEstimate
        get() = PositionEstimate(subjectId = subjectId, timestamp = timestamp, frameId = frameId,
            kind = PositionEstimate.Kind.predicted, method = PositionEstimate.Method.prediction, position = center,
            positionMode = if (center.y == 0.0) PositionMode.floor else PositionMode.threeD,
            uncertainty = uncertainty, lastAbsoluteAt = lastObservedAt, source = EvidenceSource.prediction,
            freshness = freshness, provenance = provenance)

    /** The same prediction without its cloud, as it may travel over the mesh. */
    val withoutCloud: Prediction
        get() = Prediction(subjectId = subjectId, timestamp = timestamp, frameId = frameId, method = method,
            lastObservedAt = lastObservedAt, lastObservedPosition = lastObservedPosition, center = center,
            uncertainty = uncertainty, cloud = null, freshness = freshness, provenance = provenance)

    override fun validate() {
        validateCommon()
        requireContract(source == EvidenceSource.prediction, "source")
        requireContract(DashboardContract.isValidId(subjectId), "subjectId")
        requireContract(lastObservedAt.isFinite() && lastObservedAt > 0 && horizon >= 0 &&
            horizon <= GhostCoreContract.maxHorizonSeconds, "horizon")
        for ((field, p) in listOf("lastObservedPosition" to lastObservedPosition, "center" to center)) {
            requireContract(listOf(p.x, p.y, p.z).all(::isContractCoordinate), field)
        }
        uncertainty.validate()
        requireContract(cloud?.let { list ->
            list.size <= GhostCoreContract.maxCloudPoints && list.all { isContractCoordinate(it.x) && isContractCoordinate(it.z) }
        } ?: true, "cloud")
    }
}

// MARK: - RelayMessage

/**
 * A contract record travelling over the mesh. The envelope's identity (origin, epoch, sequence,
 * messageId) is set once by the origin and never changed by relays; each relay appends itself to
 * `path`, takes one hop and adds its hold time to `freshness`. `source`, the uncertainty and
 * `provenance` are the payload's own.
 *
 * `sequence` is a Long like `DeviceUpdate.sequence` (Swift `Int` is 64-bit; up to 2^53 − 1).
 */
@Serializable
data class RelayMessage(
    /** UUID chosen by the origin, kept across relays. */
    @Required val messageId: String = UUID.randomUUID().toString().uppercase(),
    val originId: String,
    /** UUID of the origin's current run; a restart starts a new epoch. */
    val epochId: String,
    val sequence: Long,
    /** Origin-clock creation time; advisory only (clocks are not synchronised). */
    override val timestamp: Double,
    override val frameId: String,
    val hopsRemaining: Int,
    /** Device IDs of the phones that relayed this copy, oldest first; empty from the origin. */
    @Required val path: List<String> = emptyList(),
    /** `ageAtHandoff` sums hold times hop by hop; `maxAge` is the message's time to live. */
    override val freshness: Freshness,
    val payload: Payload,
) : GhostRecord {
    /**
     * JSON shape: `{"type": "position", "position": {...}}`, one key per payload type. The
     * associated value is `value` in every case (`val (assessment) = payload` destructures it).
     */
    @Serializable(with = RelayPayloadSerializer::class)
    sealed class Payload {
        data class position(val value: PositionEstimate) : Payload()
        data class integrity(val value: IntegrityAssessment) : Payload()
        data class prediction(val value: Prediction) : Payload()
        data class observations(val value: List<PeerObservation>) : Payload()

        /** Swift's `record` tuple: the payload's frame, source and provenance. */
        internal data class Record(val frameId: String, val source: EvidenceSource, val provenance: Provenance)

        internal val record: Record?
            get() = when (this) {
                is position -> Record(value.frameId, value.source, value.provenance)
                is integrity -> Record(value.frameId, value.source, value.provenance)
                is prediction -> Record(value.frameId, value.source, value.provenance)
                is observations -> value.firstOrNull()?.let { Record(it.frameId, it.source, it.provenance) }
            }
    }

    override val source: EvidenceSource get() = payload.record?.source ?: EvidenceSource.bluetooth

    override val provenance: Provenance
        get() = payload.record?.provenance ?: Provenance(producerId = originId, algorithm = "relay@1", gnssDependent = false)

    /** The copy a relay sends on: one hop fewer, itself appended to the path, its hold time added. */
    fun relayed(by: String, heldFor: Double): RelayMessage? {
        if (!(hopsRemaining > 0 && by != originId && !path.contains(by) && path.size < MeshProtocol.maxPathLength)) return null
        return RelayMessage(messageId = messageId, originId = originId, epochId = epochId, sequence = sequence,
            timestamp = timestamp, frameId = frameId, hopsRemaining = hopsRemaining - 1,
            path = path + by, freshness = freshness.handedOn(heldFor), payload = payload)
    }

    override fun validate() {
        validateCommon()
        requireContract(ghostCoreContractUUIDPattern.matches(messageId), "messageId")
        requireContract(DashboardContract.isValidId(originId), "originId")
        requireContract(ghostCoreContractUUIDPattern.matches(epochId), "epochId")
        requireContract(sequence >= 0 && sequence <= 9_007_199_254_740_991L, "sequence")
        requireContract(hopsRemaining in 0..8, "hopsRemaining")
        requireContract(path.size <= MeshProtocol.maxPathLength && path.toSet().size == path.size &&
            path.all { DashboardContract.isValidId(it) && it != originId }, "path")
        requireContract(payload.record?.frameId == frameId, "payload.frameId")
        requireContract(payload.record?.provenance?.producerId == originId, "payload.producerId")
        when (payload) {
            is Payload.position -> payload.value.validate()
            is Payload.integrity -> payload.value.validate()
            is Payload.prediction -> {
                requireContract(payload.value.cloud == null, "payload.cloud")
                payload.value.validate()
            }
            is Payload.observations -> {
                requireContract(payload.value.isNotEmpty() && payload.value.size <= GhostCoreContract.maxObservationsPerMessage,
                    "payload.observations")
                for (r in payload.value) r.validate()
            }
        }
    }

    fun encoded(): ByteArray {
        validate()
        val data = MeshJson.encodeToString(serializer(), this).encodeToByteArray()
        if (data.size > GhostCoreContract.maxRelayBytes) throw GhostCoreContractError.tooLarge
        return data
    }

    companion object {
        fun decode(data: ByteArray): RelayMessage {
            if (data.size > GhostCoreContract.maxRelayBytes) throw GhostCoreContractError.tooLarge
            val text = try {
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(data))
                    .toString()
            } catch (e: CharacterCodingException) {
                throw SerializationException("Invalid UTF-8 in JSON payload", e)
            }
            val message = MeshJson.decodeFromString(serializer(), text)
            message.validate()
            return message
        }
    }
}

/** Swift's custom `Codable` of `RelayMessage.Payload`: `{"type": ..., "<type>": record}`. JSON only. */
internal object RelayPayloadSerializer : KSerializer<RelayMessage.Payload> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("MeshCore.RelayMessage.Payload")

    private val observationsSerializer = ListSerializer(PeerObservation.serializer())

    override fun serialize(encoder: Encoder, value: RelayMessage.Payload) {
        val json = (encoder as? JsonEncoder)?.json ?: throw SerializationException("RelayMessage.Payload is JSON only")
        val element = buildJsonObject {
            when (value) {
                is RelayMessage.Payload.position -> {
                    put("type", JsonPrimitive("position"))
                    put("position", json.encodeToJsonElement(PositionEstimate.serializer(), value.value))
                }
                is RelayMessage.Payload.integrity -> {
                    put("type", JsonPrimitive("integrity"))
                    put("integrity", json.encodeToJsonElement(IntegrityAssessment.serializer(), value.value))
                }
                is RelayMessage.Payload.prediction -> {
                    put("type", JsonPrimitive("prediction"))
                    put("prediction", json.encodeToJsonElement(Prediction.serializer(), value.value))
                }
                is RelayMessage.Payload.observations -> {
                    put("type", JsonPrimitive("observations"))
                    put("observations", json.encodeToJsonElement(observationsSerializer, value.value))
                }
            }
        }
        encoder.encodeJsonElement(element)
    }

    override fun deserialize(decoder: Decoder): RelayMessage.Payload {
        val input = decoder as? JsonDecoder ?: throw SerializationException("RelayMessage.Payload is JSON only")
        val json = input.json
        val obj = input.decodeJsonElement() as? JsonObject ?: throw SerializationException("payload is not an object")
        fun key(name: String) = obj[name] ?: throw SerializationException("payload: missing key '$name'")
        val type = (key("type") as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?: throw SerializationException("payload.type is not a string")
        return when (type) {
            "position" -> RelayMessage.Payload.position(json.decodeFromJsonElement(PositionEstimate.serializer(), key("position")))
            "integrity" -> RelayMessage.Payload.integrity(json.decodeFromJsonElement(IntegrityAssessment.serializer(), key("integrity")))
            "prediction" -> RelayMessage.Payload.prediction(json.decodeFromJsonElement(Prediction.serializer(), key("prediction")))
            "observations" -> RelayMessage.Payload.observations(json.decodeFromJsonElement(observationsSerializer, key("observations")))
            else -> throw GhostCoreContractError.invalid("payload.type")
        }
    }
}
