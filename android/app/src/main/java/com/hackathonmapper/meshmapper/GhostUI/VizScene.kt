package com.hackathonmapper.meshmapper

import com.hackathonmapper.meshcore.FloorPoint
import com.hackathonmapper.meshcore.GeoFrame
import com.hackathonmapper.meshcore.IntegrityAssessment
import com.hackathonmapper.meshcore.PeerObservation
import com.hackathonmapper.meshcore.Position
import com.hackathonmapper.meshcore.PositionEstimate
import com.hackathonmapper.meshcore.Prediction
import com.hackathonmapper.meshcore.currentTime
import com.hackathonmapper.meshcore.swiftRounded
import java.util.Locale
import kotlin.math.max

// What the GhostCore map draws, one snapshot per second, built from the GhostCore contract records
// (PositionEstimate, IntegrityAssessment, Prediction, PeerObservation, relay routes). This file is
// the only place that knows where the data comes from. Nothing here invents a value: a field the
// pipeline did not provide stays null and the UI says so.
//
// Times are Unix seconds (Double) on this phone's clock where Swift uses Date.

typealias VizKind = PositionEstimate.Kind
typealias VizMethod = PositionEstimate.Method
typealias VizIntegrityStatus = IntegrityAssessment.Status

/** Placed from Bluetooth signal strength of peers. */
val PositionEstimate.Method.isBluetooth: Boolean
    get() = this in listOf(PositionEstimate.Method.particle, PositionEstimate.Method.multilateration, PositionEstimate.Method.proximity)

/** What an estimate made this way is called on screen. */
val PositionEstimate.Method.estimateTitle: String
    get() = when (this) {
        PositionEstimate.Method.uwb -> "UWB estimate"
        PositionEstimate.Method.deadReckoning -> "Dead reckoning"
        PositionEstimate.Method.fusion -> "Fused estimate"
        PositionEstimate.Method.particle, PositionEstimate.Method.multilateration, PositionEstimate.Method.proximity -> "Bluetooth estimate"
        else -> "Estimate"
    }

val PositionEstimate.Method.title: String
    get() = when (this) {
        PositionEstimate.Method.gnss -> "GPS"
        PositionEstimate.Method.uwb -> "UWB"
        PositionEstimate.Method.multilateration -> "Bluetooth multilateration"
        PositionEstimate.Method.proximity -> "Bluetooth proximity"
        PositionEstimate.Method.particle -> "Bluetooth particle filter"
        PositionEstimate.Method.deadReckoning -> "dead reckoning"
        PositionEstimate.Method.fusion -> "fusion"
        PositionEstimate.Method.manual -> "typed spot"
        PositionEstimate.Method.prediction -> "prediction"
        PositionEstimate.Method.none -> "none"
    }

/** Swift `Int(x.rounded())`: half away from zero. */
internal fun vizRound(x: Double): Int = swiftRounded(x).toInt()

/** Swift `String(format:)` with a fixed (US) locale. */
internal fun vizFormat(format: String, vararg args: Any?): String = String.format(Locale.US, format, *args)

private val camelCaseBoundary = Regex("([a-z])([A-Z])")

data class VizEvidence(
    val index: Int,
    val check: String,
    val observed: Double?,
    val threshold: Double?,
    val unit: String,
    /** 1 = fully consistent, 0 = impossible. */
    val score: Double,
    /** False when the evidence itself depends on GNSS (e.g. a peer placed by GPS). */
    val independent: Boolean,
    val reason: String?,
) {
    val id: Int get() = index
}

data class VizReason(
    val code: String,
    /** One plain sentence, e.g. "GPS jumped 412 m in one step (limit 25 m)". It never names an attacker. */
    val text: String,
) {
    val id: String get() = code

    companion object {
        /**
         * A sentence from a reason code and the numbers of the check behind it. It states what was
         * measured against what is physically possible; it never names an attacker.
         */
        fun sentence(code: String, evidence: VizEvidence?): String {
            fun n(v: Double?): String {
                if (v == null) return "?"
                return if (v >= 100) "${vizRound(v)}" else vizFormat(if (v >= 10) "%.0f" else "%.1f", v)
            }
            val o = n(evidence?.observed)
            val unit = evidence?.let { if (it.unit.isEmpty()) "" else " ${it.unit}" } ?: ""
            val limit = if (evidence?.threshold == null) "" else " (limit ${n(evidence.threshold)}$unit)"
            return when (code) {
                "noFix" -> "No GPS fix"
                "staleFix" -> "Last GPS fix is $o s old$limit"
                "invalidFix" -> "GPS fix is invalid"
                "timestampInconsistent" -> "GPS fix time does not add up"
                "degradedAccuracy" -> "GPS claims only ±$o m$limit"
                "accuracyInconsistent" -> "GPS error is larger than the accuracy it claims"
                "impossibleSpeed" -> "GPS implies $o m/s, faster than a person moves$limit"
                "impossibleAcceleration" -> "GPS implies an impossible acceleration$limit"
                "positionJump" -> "GPS jumped $o m in one step$limit"
                "inertialDisagreement" -> "GPS moved $o m the motion sensors did not feel$limit"
                "slowDrift" -> "GPS is drifting away from the motion sensors$limit"
                "peerDisagreement" ->
                    if (evidence?.check == "positionEvidence") {
                        "GPS is $o m from this phone's own position estimate$limit"
                    } else {
                        "GPS is $o m from where nearby phones place it$limit"
                    }
                "independentEvidenceDisagreement" -> "GPS disagrees with an independent position by $o m$limit"
                "peerEvidenceNotIndependent" -> "Nearby phones agree, but they use GPS too"
                "insufficientEvidence" -> "Nothing independent of GPS confirms it yet"
                "continuityLost" -> "GPS came back after a rejection; waiting for independent confirmation"
                "recovering" -> "Checks pass again; trust is still climbing"
                else -> {
                    val words = code.replace(camelCaseBoundary, "$1 $2").lowercase()
                    words.take(1).uppercase() + words.drop(1)
                }
            }
        }
    }
}

/** The raw GNSS fix the integrity checks judged, in the shared frame. */
data class VizRawFix(
    val point: FloorPoint,
    /** r95 from the receiver's claimed accuracy. */
    val claimedR95: Double,
    val observedAt: Double,
    val simulated: Boolean,
)

data class VizIntegrity(
    val status: VizIntegrityStatus,
    val trustScore: Double?,
    /** The score's coverage interval (lower is 0 with no GNSS-independent check active). */
    val trustLower: Double?,
    val reasons: List<VizReason>,
    val evidence: List<VizEvidence>,
    val evaluatedFix: VizRawFix?,
    /** "GPS could move this phone by up to N m unnoticed"; null = unbounded. */
    val minimumDetectableOffset: Double?,
    val summary: String?,
    val simulated: Boolean,
) {
    /** The one line to show: the engine's summary, else the first reason as a sentence. */
    val headline: String? get() = summary ?: reasons.firstOrNull()?.text
}

data class VizPrediction(
    val lastObservedAt: Double,
    val horizon: Double,
    val center: FloorPoint,
    val r95: Double?,
    val cloud: List<FloorPoint>,
    val method: String,
    val simulated: Boolean,
)

/** One way a lost phone may have walked, from the route model (a prediction, never a measurement). */
data class VizLikelyPath(
    /** 0 = most likely. */
    val rank: Int,
    val probability: Double,
    /** e.g. "straight on at the fork in 240 m". */
    val text: String,
    val line: List<FloorPoint>,
    /** Where along it they probably are by now (median) and the 10-90 % stretch. */
    val here: FloorPoint?,
    val band: List<FloorPoint>,
) {
    val id: Int get() = rank
}

data class VizLikelyPaths(
    val options: List<VizLikelyPath>,
    /** Chance they left the paths altogether. */
    val offPath: Double,
) {
    constructor(routes: MovementPredictor.Routes) : this(
        options = routes.options.map {
            VizLikelyPath(rank = it.id, probability = it.probability, text = it.text, line = it.line, here = it.here, band = it.band)
        },
        offPath = routes.offPath,
    )
}

/** One input behind a position, e.g. "phone-c GNSS, not used: positionJump". */
data class VizInput(
    val index: Int,
    val source: String,
    val deviceId: String?,
    val age: Double?,
    val used: Boolean,
    val reason: String?,
) {
    val id: Int get() = index
}

data class VizPhone(
    val id: String,
    val label: String,
    val isSelf: Boolean,
    val kind: VizKind,
    val method: VizMethod,
    val point: FloorPoint?,
    val r95: Double?,
    val ambiguous: Boolean,
    /** Spots an ambiguous estimate cannot choose between; drawn instead of a single dot. */
    val candidates: List<FloorPoint>,
    /** Particle cloud of a Bluetooth estimate (the prediction cloud lives in `prediction`). */
    val cloud: List<FloorPoint>,
    /** When the shown position was last measured; the age shown on screen counts from here. */
    val observedAt: Double?,
    val hops: Int?,
    val integrity: VizIntegrity?,
    /** This phone's latest raw GNSS fix, shown even when no trust verdict exists. */
    val rawFix: VizRawFix?,
    val prediction: VizPrediction?,
    /** Which way a predicted phone probably went; only for phones shown as predicted. */
    val likelyPaths: VizLikelyPaths?,
    val inputs: List<VizInput>,
    val simulated: Boolean,
) {
    /** The raw fix to compare with the shown position: the one judged, else the latest. */
    val comparedFix: VizRawFix? get() = integrity?.evaluatedFix ?: rawFix

    fun age(now: Double): Double? = observedAt?.let { max(0.0, now - it) }
}

data class VizLink(val a: String, val b: String, val rssi: Double) {
    val id: String get() = a + "\n" + b
}

/** One accepted report's way to this phone: origin, then relays oldest first, then this phone. */
data class VizRoute(val origin: String, val relays: List<String>) {
    val id: String get() = origin
}

data class VizScenarioState(
    val name: String,
    val elapsed: Double,
    val stepIndex: Int,
    val caption: String?,
    val isRunning: Boolean,
)

class VizScene(
    var now: Double = currentTime(),
    var frameId: String = GeoFrame.defaultFrameId,
    var selfId: String = "",
    var phones: List<VizPhone> = emptyList(),
    var links: List<VizLink> = emptyList(),
    var routes: List<VizRoute> = emptyList(),
    var scenario: VizScenarioState? = null,
    /** True when the integrity engine is wired in; without it GPS is shown as not checked, never "trusted". */
    var integrityConnected: Boolean = false,
) {
    val me: VizPhone? get() = phones.firstOrNull { it.isSelf }
    fun phone(id: String): VizPhone? = phones.firstOrNull { it.id == id }
    val anySimulated: Boolean
        get() = scenario?.isRunning == true || phones.any {
            it.simulated || it.integrity?.simulated == true || it.prediction?.simulated == true
        }

    /** Where a phone is drawn: its prediction centre when predicted, otherwise its point. */
    fun drawnPoint(id: String): FloorPoint? {
        val phone = phone(id) ?: return null
        val p = phone.prediction
        if (phone.kind == PositionEstimate.Kind.predicted && p != null) return p.center
        return phone.point
    }

    companion object {
        // MARK: - Feed from the GhostCore contract records

        fun contract(input: VizContractInputs): VizScene {
            val now = input.now
            val scene = VizScene(now = now, frameId = input.frameId, selfId = input.selfId)
            scene.integrityConnected = input.integrityAvailable ?: input.integrity.isNotEmpty()
            scene.scenario = input.scenario

            fun floor(p: Position): FloorPoint = FloorPoint(p.x, p.z)
            fun date(age: Double): Double = now - max(0.0, age)

            val phones = mutableListOf<VizPhone>()
            val ids = (input.positions.keys + input.predictions.keys + input.integrity.keys + input.rawFixes.keys).toSortedSet()
            for (id in ids) {
                val position = input.positions[id]
                val predictionRecord = input.predictions[id]

                var integrity: VizIntegrity? = null
                val record = input.integrity[id]
                if (record != null) {
                    val rx = input.integrityReceivedAt[id] ?: record.timestamp
                    val assessedAge = record.freshness.age(receivedAt = rx, now = now)
                    val evidence = record.evidence.mapIndexed { i, e ->
                        VizEvidence(
                            index = i, check = e.check, observed = e.observed, threshold = e.threshold, unit = e.unit ?: "",
                            score = e.score, independent = e.independent, reason = e.reason?.rawValue,
                        )
                    }
                    val reasons = record.reasons.map { reason ->
                        VizReason(
                            code = reason.rawValue,
                            text = VizReason.sentence(reason.rawValue, evidence.firstOrNull { it.reason == reason.rawValue }),
                        )
                    }
                    val fix = record.evaluatedFix?.let { fix ->
                        val p = fix.position ?: return@let null
                        // The fix's age on this phone: the assessment's age plus how old the fix was when judged.
                        VizRawFix(
                            point = floor(p), claimedR95 = fix.uncertainty.r95,
                            observedAt = date(assessedAge + max(0.0, record.timestamp - fix.timestamp)),
                            simulated = fix.provenance.simulated,
                        )
                    }
                    integrity = VizIntegrity(
                        status = record.status, trustScore = record.trustScore,
                        trustLower = record.uncertainty.lower, reasons = reasons, evidence = evidence,
                        evaluatedFix = fix, minimumDetectableOffset = record.minimumDetectableOffsetMeters,
                        summary = record.summary, simulated = record.provenance.simulated,
                    )
                }

                var prediction: VizPrediction? = null
                if (predictionRecord != null) {
                    val rx = input.predictionReceivedAt[id] ?: predictionRecord.timestamp
                    val sinceObserved = predictionRecord.horizon + predictionRecord.freshness.age(receivedAt = rx, now = now)
                    prediction = VizPrediction(
                        lastObservedAt = date(sinceObserved), horizon = sinceObserved,
                        center = floor(predictionRecord.center), r95 = predictionRecord.uncertainty.r95,
                        cloud = (predictionRecord.cloud ?: emptyList()).map { FloorPoint(it.x, it.z) },
                        method = predictionRecord.method.rawValue, simulated = predictionRecord.provenance.simulated,
                    )
                }

                // A phone with a fresh prediction and no live position is shown predicted.
                val livePosition = position?.takeIf {
                    it.kind == PositionEstimate.Kind.measured || it.kind == PositionEstimate.Kind.estimated ||
                        it.kind == PositionEstimate.Kind.declared
                }
                val kind: VizKind
                val method: VizMethod
                val point: FloorPoint?
                val r95: Double?
                val observedAt: Double?
                val predictedAt = position?.position
                if (livePosition != null) {
                    kind = livePosition.kind
                    method = livePosition.method
                    point = livePosition.position?.let { floor(it) }
                    r95 = livePosition.uncertainty.r95
                    observedAt = date(livePosition.freshness.age(receivedAt = input.positionReceivedAt[id] ?: livePosition.timestamp, now = now))
                } else if (prediction != null) {
                    kind = PositionEstimate.Kind.predicted
                    method = PositionEstimate.Method.prediction
                    point = prediction.center
                    r95 = prediction.r95
                    observedAt = prediction.lastObservedAt
                } else if (position != null && position.kind == PositionEstimate.Kind.predicted && predictedAt != null) {
                    // A predicted position without its Prediction record (e.g. relayed from another phone).
                    val rx = input.positionReceivedAt[id] ?: position.timestamp
                    val since = (position.lastAbsoluteAt?.let { position.timestamp - it } ?: 0.0) +
                        position.freshness.age(receivedAt = rx, now = now)
                    prediction = VizPrediction(
                        lastObservedAt = date(since), horizon = since, center = floor(predictedAt),
                        r95 = position.uncertainty.r95, cloud = emptyList(), method = position.provenance.algorithm,
                        simulated = position.provenance.simulated,
                    )
                    kind = PositionEstimate.Kind.predicted
                    method = PositionEstimate.Method.prediction
                    point = floor(predictedAt)
                    r95 = position.uncertainty.r95
                    observedAt = date(since)
                } else {
                    kind = PositionEstimate.Kind.unavailable
                    method = PositionEstimate.Method.none
                    point = null
                    r95 = null
                    observedAt = null
                }

                val provenance = livePosition?.provenance ?: predictionRecord?.provenance ?: position?.provenance
                val inputs = (provenance?.inputs ?: emptyList()).mapIndexed { i, item ->
                    VizInput(index = i, source = item.source.rawValue, deviceId = item.id, age = item.age, used = item.used, reason = item.reason)
                }
                val rawFix = input.rawFixes[id]?.let { fix ->
                    val p = fix.position ?: return@let null
                    val age = fix.freshness.age(receivedAt = input.positionReceivedAt[id] ?: fix.timestamp, now = now)
                    VizRawFix(point = floor(p), claimedR95 = fix.uncertainty.r95, observedAt = date(age), simulated = fix.provenance.simulated)
                }
                val isSelf = id == input.selfId
                phones.add(
                    VizPhone(
                        id = id, label = if (isSelf) "You" else (input.labels[id] ?: shortID(id)), isSelf = isSelf,
                        kind = kind, method = method, point = point, r95 = r95,
                        ambiguous = livePosition?.uncertainty?.ambiguous ?: false,
                        candidates = (livePosition?.candidates ?: emptyList()).map { FloorPoint(it.x, it.z) }, cloud = emptyList(),
                        observedAt = observedAt, hops = null, integrity = integrity, rawFix = rawFix, prediction = prediction,
                        likelyPaths = if (kind == PositionEstimate.Kind.predicted) input.likelyPaths[id] else null, inputs = inputs,
                        simulated = provenance?.simulated ?: false,
                    ),
                )
            }
            scene.phones = phones.sortedWith(compareBy<VizPhone>({ if (it.isSelf) 0 else 1 }, { it.label }))

            // One line per pair of phones that hear each other, at the mean RSSI either end reports.
            class LinkSum(val a: String, val b: String, var sum: Double, var count: Int)
            val pairs = mutableMapOf<String, LinkSum>()
            for (observation in input.observations) {
                if (observation.linkState == PeerObservation.LinkState.lost) continue
                val peer = observation.peerId ?: continue
                if (peer == observation.observerId) continue
                val samples = observation.rawRSSI
                val rssi = observation.smoothedRSSI ?: (if (samples.isEmpty()) null else samples.sum() / samples.size) ?: continue
                val (a, b) = if (observation.observerId < peer) observation.observerId to peer else peer to observation.observerId
                val pair = pairs.getOrPut(a + "\n" + b) { LinkSum(a, b, 0.0, 0) }
                pair.sum += rssi
                pair.count += 1
            }
            scene.links = input.links ?: pairs.keys.sorted().mapNotNull { key ->
                pairs[key]?.let { VizLink(it.a, it.b, it.sum / it.count) }
            }
            scene.routes = input.routes.keys.sorted().mapNotNull { origin ->
                val relays = input.routes[origin]
                if (origin == input.selfId || relays == null) null else VizRoute(origin, relays)
            }
            return scene
        }

        // MARK: - Feed from GhostCoreHub

        /**
         * The map from what GhostCoreHub published this second. The route model's likely paths come
         * from MovementPredictor (app-side; the contract's Prediction carries no routes).
         */
        fun hub(hub: GhostCoreHub, model: MeshModel, predictor: MovementPredictor, now: Double = currentTime()): VizScene {
            val input = VizContractInputs(selfId = model.deviceID, frameId = model.frameID, now = now)
            for (phone in hub.phones) {
                input.labels[phone.id] = phone.label
                phone.selected?.let { input.positions[phone.id] = it }
                phone.positionReceivedAt?.let { input.positionReceivedAt[phone.id] = it }
                phone.integrity?.let { input.integrity[phone.id] = it }
                phone.integrityReceivedAt?.let { input.integrityReceivedAt[phone.id] = it }
                phone.prediction?.let { input.predictions[phone.id] = it }
                phone.predictionReceivedAt?.let { input.predictionReceivedAt[phone.id] = it }
                phone.rawFix?.let { input.rawFixes[phone.id] = it }
                if (phone.route.isNotEmpty()) input.routes[phone.id] = phone.route
                predictor.routes[phone.id]?.let { input.likelyPaths[phone.id] = VizLikelyPaths(it) }
            }
            input.links = hub.links.map { VizLink(it.a, it.b, it.rssi) }
            input.integrityAvailable = hub.integrityEngineActive
            hub.scenario?.let { scenario ->
                input.scenario = VizScenarioState(
                    name = "${scenario.scenarioId} · ${scenario.title}", elapsed = scenario.elapsed,
                    stepIndex = scenario.stepIndex, caption = scenario.caption, isRunning = scenario.isRunning,
                )
            }
            if (hub.simulationActive && input.scenario?.isRunning != true) {
                input.scenario = VizScenarioState(name = "Fault on this phone", elapsed = 0.0, stepIndex = 0, caption = null, isRunning = true)
            }
            return contract(input)
        }
    }
}

/** How a phone reads on screen: the honest label for its kind, its colour and whether it is live. */
data class VizPresentation(
    val title: String,
    val detail: String?,
    val tint: VizTint,
    val live: Boolean,
) {
    enum class VizTint { confirmed, unchecked, bluetooth, predicted, rejected, suspect, declared, unknown }

    companion object {
        fun of(phone: VizPhone, scene: VizScene): VizPresentation {
            val r95 = phone.r95?.let { "±${vizRound(it)} m" }
            val age = phone.age(scene.now)?.let { ageText(it) }
            return when (phone.kind) {
                PositionEstimate.Kind.measured -> {
                    val method = if (phone.method == PositionEstimate.Method.uwb) "UWB" else "GPS"
                    val why = phone.integrity?.headline
                    when (phone.integrity?.status) {
                        IntegrityAssessment.Status.trusted -> VizPresentation("$method trusted", r95, VizTint.confirmed, true)
                        IntegrityAssessment.Status.degraded -> VizPresentation("$method degraded", why ?: r95, VizTint.suspect, true)
                        IntegrityAssessment.Status.suspect -> VizPresentation("$method suspect", why ?: r95, VizTint.suspect, true)
                        IntegrityAssessment.Status.insufficientEvidence -> VizPresentation("$method unconfirmed", why ?: r95, VizTint.suspect, true)
                        IntegrityAssessment.Status.rejected -> VizPresentation("$method rejected", why, VizTint.rejected, true)
                        IntegrityAssessment.Status.unavailable, null ->
                            // No verdict: never drawn as trusted. UWB fixes are not judged by the GNSS checks.
                            if (phone.method == PositionEstimate.Method.uwb) {
                                VizPresentation("UWB fix", r95, VizTint.confirmed, true)
                            } else {
                                VizPresentation("$method not checked", r95, VizTint.unchecked, true)
                            }
                    }
                }
                PositionEstimate.Kind.estimated -> {
                    val what = phone.method.estimateTitle
                    if (phone.ambiguous) {
                        VizPresentation("$what: 2+ spots", r95, VizTint.bluetooth, true)
                    } else {
                        VizPresentation("$what ${r95 ?: ""}", phone.hops?.let { hopText(it) }, VizTint.bluetooth, true)
                    }
                }
                PositionEstimate.Kind.predicted ->
                    VizPresentation("Predicted", age?.let { "last seen $it ago" }, VizTint.predicted, false)
                PositionEstimate.Kind.declared -> VizPresentation("Typed spot", r95, VizTint.declared, true)
                PositionEstimate.Kind.unavailable ->
                    VizPresentation("Position unknown", "needs GPS or a placed peer", VizTint.unknown, false)
            }
        }

        fun ageText(seconds: Double): String {
            val s = vizRound(seconds)
            return if (s < 90) "$s s" else "${s / 60} min"
        }

        fun hopText(hops: Int): String = "$hops hop${if (hops == 1) "" else "s"} from GPS"
    }
}

/**
 * Everything the map needs from the GhostCore pipeline for one frame. Times are Unix seconds on
 * this phone's clock; `*ReceivedAt` is when each subject's latest record arrived here (a record
 * this phone produced itself counts as received at its own timestamp).
 */
class VizContractInputs(
    var selfId: String,
    var frameId: String,
    var now: Double,
) {
    val labels: MutableMap<String, String> = mutableMapOf()
    val positions: MutableMap<String, PositionEstimate> = mutableMapOf()
    val integrity: MutableMap<String, IntegrityAssessment> = mutableMapOf()
    val predictions: MutableMap<String, Prediction> = mutableMapOf()
    var observations: List<PeerObservation> = emptyList()
    /** Links already paired and averaged by the pipeline; used instead of `observations` when given. */
    var links: List<VizLink>? = null
    /** originId -> relays oldest first. */
    val routes: MutableMap<String, List<String>> = mutableMapOf()
    /** Route-model guesses per lost phone (app-side; the contract Prediction carries no routes). */
    val likelyPaths: MutableMap<String, VizLikelyPaths> = mutableMapOf()
    /** Latest raw GNSS fix per phone, judged or not. */
    val rawFixes: MutableMap<String, PositionEstimate> = mutableMapOf()
    /** Whether an integrity engine runs at all; null = infer from whether any assessment exists. */
    var integrityAvailable: Boolean? = null
    val positionReceivedAt: MutableMap<String, Double> = mutableMapOf()
    val integrityReceivedAt: MutableMap<String, Double> = mutableMapOf()
    val predictionReceivedAt: MutableMap<String, Double> = mutableMapOf()
    var scenario: VizScenarioState? = null
}
