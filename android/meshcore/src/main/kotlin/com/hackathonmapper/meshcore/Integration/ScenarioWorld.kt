package com.hackathonmapper.meshcore

import java.math.BigDecimal
import java.math.RoundingMode
import java.util.UUID
import kotlin.math.atan2
import kotlin.math.sqrt

/**
 * Headless rehearsal of a scenario: every phone walks its true path, runs its own
 * GhostCorePipeline (the code the app runs), hears its neighbours through the radio model, and an
 * idealised mesh carries each phone's report to every phone it is connected to. Seeded, so a run
 * is repeatable. Results are synthetic and are reported as such.
 *
 * Engine factories are called with (phone id, frame id); nil keeps the baseline (or no integrity).
 * Swift names their type `ScenarioWorld.Factory<T>`; Kotlin has no nested type aliases, so the
 * parameters take the function type directly.
 */
class ScenarioWorld(
    val scenario: Scenario,
    val radio: RadioModel = RadioModel.outdoors,
    integrity: ((String, String) -> GhostIntegrityEngine)? = null,
    positioning: ((String, String) -> GhostPositioningEngine)? = null,
    prediction: ((String, String) -> GhostPredictionEngine)? = null,
) {
    enum class Outcome(val rawValue: String) {
        pass("pass"), fail("fail"), pending("pending"),
    }

    data class Result(
        val id: String,
        val text: String,
        val outcome: Outcome,
        val detail: String,
        val gate: Boolean,
    )

    class Report(
        val scenario: Scenario,
        val results: List<Result>,
    ) {
        val gateFailures: List<Result> get() = results.filter { it.gate && it.outcome == Outcome.fail }

        val table: String
            get() = results.joinToString("\n") { r ->
                "scenario|${scenario.id}|${r.id}|${r.outcome.rawValue.uppercase()}${if (r.gate) "" else " (not gating)"}|${r.text}|${r.detail}"
            }
    }

    private val makeIntegrity = integrity
    private val makePositioning = positioning
    private val makePrediction = prediction

    private data class ErrorSample(val error: Double, val r95: Double)

    fun run(): Report {
        val rng = SeededRandom(scenario.seed)
        val ids = scenario.phones.map { it.id }
        val pipelines = HashMap<String, GhostCorePipeline>()
        for (phone in scenario.phones) {
            pipelines[phone.id] = GhostCorePipeline(
                configuration = GhostCorePipeline.Configuration(selfId = phone.id, frameId = scenario.frameId),
                integrity = makeIntegrity?.invoke(phone.id, scenario.frameId),
                positioning = makePositioning?.invoke(phone.id, scenario.frameId),
                prediction = makePrediction?.invoke(phone.id, scenario.frameId))
        }
        val epochs = ids.associateWith { UUID.randomUUID().toString().uppercase() }
        val publications = HashMap<String, GhostCorePipeline.Publication>()
        val records = HashMap<String, List<RelayMessage.Payload>>()
        val blocked = HashSet<String>()
        val activeFaults = HashSet<String>()
        val steps = scenario.steps.sortedBy { it.at }
        var nextStep = 0
        val samples = HashMap<String, MutableList<Boolean>>()
        val errors = HashMap<String, MutableList<ErrorSample>>()
        val firstHold = HashMap<String, Double>()

        fun pair(a: String, b: String): String = if (a < b) a + "\n" + b else b + "\n" + a

        for (second in 0..scenario.duration.toInt()) {
            val t = second.toDouble()
            val now = epoch + t
            while (nextStep < steps.size && steps[nextStep].at <= t) {
                val input = steps[nextStep].input
                pipelines[input.subjectId]?.apply(input, now)
                when {
                    input is ScenarioInput.peerLink ->
                        if (input.up) blocked.remove(pair(input.subjectId, input.peerId)) else blocked.add(pair(input.subjectId, input.peerId))
                    input is ScenarioInput.gnssClear -> activeFaults.remove(input.subjectId)
                    input is ScenarioInput.gnssOutage && !input.active -> activeFaults.remove(input.subjectId)
                    else -> activeFaults.add(input.subjectId)
                }
                nextStep += 1
            }

            // Sensors: motion over the last second and a GNSS fix around the true position.
            val truth = HashMap<String, FloorVector>()
            for (phone in scenario.phones) {
                val p = scenario.truth(of = phone.id, t = t) ?: continue
                val pipeline = pipelines[phone.id] ?: continue
                truth[phone.id] = p
                val before = if (second > 0) scenario.truth(of = phone.id, t = t - 1) else null
                if (before != null) {
                    val dx = p.x - before.x
                    val dz = p.z - before.z
                    val distance = sqrt(dx * dx + dz * dz)
                    val noise = 0.05 + 0.1 * distance
                    val movedX = dx + noise * rng.gauss()
                    val movedZ = dz + noise * rng.gauss()
                    val moved = FloorVector(x = movedX, z = movedZ)
                    val still = distance < 0.1
                    val motion = MotionObservation(
                        subjectId = phone.id, timestamp = now, interval = 1.0, frameId = scenario.frameId,
                        method = MotionObservation.Method.stepDetector,
                        steps = if (still) 0 else swiftRounded(distance / 0.7).toInt(), displacement = moved,
                        heading = if (still) null else atan2(dx, dz), stationary = still,
                        uncertainty = MotionObservation.Uncertainty(displacementR95 = PositionUncertainty.r95(fromSigma = noise),
                            headingSigma = 0.15),
                        freshness = Freshness(maxAge = 5.0),
                        provenance = Provenance(producerId = phone.id, algorithm = "scenario-motion@1", gnssDependent = false,
                            simulated = true))
                    if (runCatching { motion.validate() }.isSuccess) pipeline.ingest(motion = motion)
                }
                if (phone.hasGNSS) {
                    val sigma = phone.accuracy68 / 1.5096
                    val x = p.x + sigma * rng.gauss()
                    val z = p.z + sigma * rng.gauss()
                    val fix = PositionEstimate(
                        subjectId = phone.id, timestamp = now, frameId = scenario.frameId,
                        kind = PositionEstimate.Kind.measured, method = PositionEstimate.Method.gnss,
                        position = Position(x = x, y = 0.0, z = z),
                        uncertainty = PositionUncertainty(r95 = PositionUncertainty.r95(fromRadius68 = phone.accuracy68)),
                        lastAbsoluteAt = now, source = EvidenceSource.gnss, freshness = Freshness(maxAge = 30.0),
                        provenance = Provenance(producerId = phone.id, algorithm = "scenario-gnss@1", gnssDependent = true,
                            simulated = true))
                    pipeline.ingest(fix = fix, receivedAt = now)
                }
            }

            // Radio: which pairs hear each other this second, and how loudly in each direction.
            val heard = HashMap<String, HashMap<String, Int>>()
            for ((i, a) in ids.withIndex()) {
                for (b in ids.drop(i + 1)) {
                    val pa = truth[a] ?: continue
                    val pb = truth[b] ?: continue
                    if (blocked.contains(pair(a, b))) continue
                    val d = sqrt((pa.x - pb.x) * (pa.x - pb.x) + (pa.z - pb.z) * (pa.z - pb.z))
                    if (!(rng.next() < radio.hearProbability(d))) continue
                    val expected = radio.expectedRSSI(d)
                    heard.getOrPut(a) { HashMap() }[b] =
                        swiftRounded(maxOf(-127.0, minOf(20.0, expected + radio.sigma * rng.gauss()))).toInt()
                    heard.getOrPut(b) { HashMap() }[a] =
                        swiftRounded(maxOf(-127.0, minOf(20.0, expected + radio.sigma * rng.gauss()))).toInt()
                }
            }
            for (id in ids) {
                val observations = (heard[id] ?: emptyMap<String, Int>()).entries.sortedBy { it.key }.map { (peer, rssi) ->
                    PeerObservation(observerId = id, peerId = peer, timestamp = now, frameId = scenario.frameId,
                        channel = PeerObservation.Channel.connection, linkState = PeerObservation.LinkState.ready,
                        rawRSSI = listOf(rssi.toDouble()), window = 1.0,
                        smoothedRSSI = rssi.toDouble(), uncertainty = PeerObservation.Uncertainty(stdDevDb = null, sampleCount = 1),
                        freshness = Freshness(maxAge = 6.0),
                        provenance = Provenance(producerId = id, algorithm = "scenario-radio@1",
                            gnssDependent = false, simulated = true))
                }
                pipelines[id]?.ingest(observations = observations)
            }

            // Mesh: each phone's report reaches every phone it is connected to, along the shortest path.
            for (origin in ids) {
                val publication = publications[origin]
                    ?: GhostCorePipeline.Publication(position = Position(x = 0.0, y = 0.0, z = 0.0), accuracyMeters = null,
                        source = PositionSource.none)
                val update = DeviceUpdate(
                    id = origin, label = scenario.phones.firstOrNull { it.id == origin }?.label, epochId = epochs.getValue(origin),
                    sequence = second.toLong(), role = "mobile", position = publication.position, positionMode = "floor",
                    accuracyMeters = publication.accuracyMeters,
                    neighbors = (heard[origin] ?: emptyMap<String, Int>()).entries.sortedBy { it.key }
                        .map { NeighborObservation(id = it.key, rssi = it.value, ageMs = 0) },
                    positionSource = publication.source)
                val parent = LinkedHashMap<String, String>()
                parent[origin] = origin
                val queue = ArrayDeque<String>()
                queue.addLast(origin)
                while (queue.isNotEmpty()) {
                    val node = queue.removeFirst()
                    for (next in (heard[node] ?: emptyMap<String, Int>()).keys.sorted()) {
                        if (parent[next] != null) continue
                        parent[next] = node
                        queue.addLast(next)
                    }
                }
                for (receiver in parent.keys) {
                    val path = mutableListOf<String>()
                    var hop = parent.getValue(receiver)
                    while (hop != origin) {
                        path.add(0, hop)
                        hop = parent.getValue(hop)
                    }
                    val delay = if (receiver == origin) 0.0 else (path.size + 1).toDouble() * hopDelay
                    pipelines[receiver]?.ingest(report = update, receivedAt = now - 1 + delay, path = path)
                    if (receiver == origin) continue
                    for (payload in records[origin] ?: emptyList()) {
                        if (payload !is RelayMessage.Payload.integrity) continue
                        val assessment = payload.value
                        val message = RelayMessage(originId = origin, epochId = epochs.getValue(origin), sequence = second.toLong(),
                            timestamp = now - 1, frameId = scenario.frameId, hopsRemaining = 4,
                            path = path, freshness = assessment.freshness.handedOn(heldFor = delay),
                            payload = payload)
                        pipelines[receiver]?.ingest(record = message, receivedAt = now - 1 + delay)
                    }
                }
            }

            // Every phone's pipeline steps; expectations are checked on what it shows.
            val outputs = HashMap<String, GhostCorePipeline.Output>()
            for (id in ids) {
                val output = pipelines[id]?.step(now = now) ?: continue
                outputs[id] = output
                publications[id] = output.publication
                records[id] = output.records
            }
            for (e in scenario.expectations) {
                if (!(t >= e.from && t <= e.to)) continue
                val holds = check(e, outputs, truth, faultActive = activeFaults.contains(e.subject))
                samples.getOrPut(e.id) { mutableListOf() }.add(holds)
                if (holds && firstHold[e.id] == null) firstHold[e.id] = t
                if (e.check == ScenarioExpectation.Check.truthInsideR95) {
                    val shown = phone(e.subject, outputs[e.observer])?.selected
                    val position = shown?.position
                    val p = truth[e.subject]
                    if (shown != null && position != null && p != null) {
                        val error = sqrt((position.x - p.x) * (position.x - p.x) + (position.z - p.z) * (position.z - p.z))
                        errors.getOrPut(e.id) { mutableListOf() }.add(ErrorSample(error, shown.uncertainty.r95))
                    }
                }
            }
        }

        val results = scenario.expectations.map { e ->
            val missing = e.requires.filter { engine ->
                when (engine) {
                    "integrity" -> makeIntegrity == null
                    "positioning", "prediction" -> false
                    else -> true
                }
            }
            if (missing.isNotEmpty()) {
                return@map Result(id = e.id, text = e.text, outcome = Outcome.pending,
                    detail = "needs ${missing.joinToString(", ")} engine", gate = e.gate)
            }
            val held = samples[e.id] ?: emptyList<Boolean>()
            var detail: String
            val pass: Boolean
            val within = e.within
            if (within != null) {
                val first = firstHold[e.id]
                pass = first?.let { it <= e.from + within } ?: false
                detail = first?.let {
                    "first held ${formatFixed(it - e.from, 0)} s after t=${formatFixed(e.from, 0)} (limit ${formatFixed(within, 0)} s)"
                } ?: "never held"
            } else {
                val fraction = if (held.isEmpty()) 0.0 else held.count { it }.toDouble() / held.size.toDouble()
                pass = fraction >= (e.minFraction ?: 1.0)
                detail = "held ${formatFixed(fraction * 100, 0)}% of ${held.size} s (need ${formatFixed((e.minFraction ?: 1.0) * 100, 0)}%)"
            }
            val list = errors[e.id]
            if (list != null && list.isNotEmpty()) {
                val median = { values: List<Double> -> values.sorted()[values.size / 2] }
                detail += "; median error ${formatFixed(median(list.map { it.error }), 1)} m, " +
                    "median r95 ${formatFixed(median(list.map { it.r95 }), 1)} m"
            }
            Result(id = e.id, text = e.text, outcome = if (pass) Outcome.pass else Outcome.fail, detail = "$detail; synthetic",
                gate = e.gate)
        }
        return Report(scenario = scenario, results = results)
    }

    private fun phone(id: String, output: GhostCorePipeline.Output?): GhostCorePipeline.Phone? =
        output?.phones?.firstOrNull { it.id == id }

    private fun check(
        e: ScenarioExpectation,
        outputs: Map<String, GhostCorePipeline.Output>,
        truth: Map<String, FloorVector>,
        faultActive: Boolean,
    ): Boolean {
        val seen = phone(e.subject, outputs[e.observer])
        val values = (e.values ?: emptyList()).toSet()
        return when (e.check) {
            ScenarioExpectation.Check.integrityStatus -> {
                val status = seen?.integrity?.status ?: return false
                values.contains(status.rawValue)
            }
            ScenarioExpectation.Check.positionKind -> {
                val kind = seen?.selected?.kind ?: return values.contains("none")
                values.contains(kind.rawValue)
            }
            ScenarioExpectation.Check.truthInsideR95 -> {
                val shown = seen?.selected ?: return false
                val position = shown.position ?: return false
                val p = truth[e.subject] ?: return false
                val d = sqrt((position.x - p.x) * (position.x - p.x) + (position.z - p.z) * (position.z - p.z))
                d <= shown.uncertainty.r95
            }
            ScenarioExpectation.Check.predictionShown -> seen?.selected?.kind == PositionEstimate.Kind.predicted
            ScenarioExpectation.Check.predictionNotShown ->
                seen?.selected != null && seen.selected.kind != PositionEstimate.Kind.predicted
            ScenarioExpectation.Check.notAnchoredBy -> {
                val own = phone(e.observer, outputs[e.observer])?.estimate ?: return true
                !own.provenance.inputs.any { it.used && it.id == e.subject && it.source == EvidenceSource.gnss }
            }
            ScenarioExpectation.Check.simulatedMarked -> {
                if (!faultActive) return true
                val fix = phone(e.subject, outputs[e.subject])?.rawFix ?: return true
                fix.provenance.simulated
            }
        }
    }

    companion object {
        /** Scenario seconds are offset by this, so records carry plausible Unix timestamps. */
        const val epoch = 1_793_000_000.0
        /** Seconds a relay hop adds before a report arrives (one mesh tick). */
        const val hopDelay = 0.3

        /**
         * `String(format: "%.Nf")` as Apple's libc prints it: the exact binary value rounded half to
         * even. Java's `%.Nf` rounds the shortest decimal half up, which differs on ties (12.5 → "13").
         */
        internal fun formatFixed(value: Double, digits: Int): String {
            if (!value.isFinite()) return if (value.isNaN()) "nan" else if (value > 0) "inf" else "-inf"
            val text = BigDecimal(value).setScale(digits, RoundingMode.HALF_EVEN).toPlainString()
            return if (value < 0 || (value == 0.0 && 1.0 / value < 0)) {
                if (text.startsWith("-")) text else "-$text"
            } else {
                text
            }
        }
    }
}
