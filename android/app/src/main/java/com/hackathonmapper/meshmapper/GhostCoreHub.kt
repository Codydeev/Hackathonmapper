package com.hackathonmapper.meshmapper

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.hackathonmapper.meshcore.DeviceUpdate
import com.hackathonmapper.meshcore.EstimatorPositioning
import com.hackathonmapper.meshcore.EvidenceSource
import com.hackathonmapper.meshcore.FeatureFlags
import com.hackathonmapper.meshcore.Freshness
import com.hackathonmapper.meshcore.GNSSIntegrityMonitor
import com.hackathonmapper.meshcore.GeoFrame
import com.hackathonmapper.meshcore.GhostCoreContract
import com.hackathonmapper.meshcore.GhostCorePipeline
import com.hackathonmapper.meshcore.GhostPositioningEngine
import com.hackathonmapper.meshcore.GhostPredictionEngine
import com.hackathonmapper.meshcore.GhostPredictor
import com.hackathonmapper.meshcore.IntegrityAssessment
import com.hackathonmapper.meshcore.MeshJson
import com.hackathonmapper.meshcore.NoPrediction
import com.hackathonmapper.meshcore.PeerObservation
import com.hackathonmapper.meshcore.PeerPlacement
import com.hackathonmapper.meshcore.Position
import com.hackathonmapper.meshcore.PositionEstimate
import com.hackathonmapper.meshcore.PositionSource
import com.hackathonmapper.meshcore.PositionUncertainty
import com.hackathonmapper.meshcore.Positioning
import com.hackathonmapper.meshcore.Prediction
import com.hackathonmapper.meshcore.PredictionMode
import com.hackathonmapper.meshcore.Provenance
import com.hackathonmapper.meshcore.ReceivedRecord
import com.hackathonmapper.meshcore.RelayMessage
import com.hackathonmapper.meshcore.Scenario
import com.hackathonmapper.meshcore.ScenarioInput
import com.hackathonmapper.meshcore.ScenarioState
import com.hackathonmapper.meshcore.SignalMapPositioning
import com.hackathonmapper.meshcore.WalkingCirclePrediction
import com.hackathonmapper.meshcore.currentTime
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

/**
 * One phone as the GhostCore map shows it. Times are Unix seconds on this phone's clock; a record's
 * age is `record.freshness.age(receivedAt = <its receivedAt>, now = currentTime())`.
 */
data class GhostPhone(
    val id: String,
    val label: String,
    val isSelf: Boolean,
    /** The one position to show (ARCHITECTURE.md §6); its `kind` decides the label. */
    val selected: PositionEstimate?,
    val positionReceivedAt: Double?,
    /** Shown GNSS that the integrity engine has not confirmed: label it "GPS (unchecked)". */
    val gnssUnconfirmed: Boolean,
    /** This phone's raw GNSS fix after any scenario fault, even when rejected (self only). */
    val rawFix: PositionEstimate?,
    /** This phone's assessment, or a peer's as relayed; null means GPS not checked. */
    val integrity: IntegrityAssessment?,
    val integrityReceivedAt: Double?,
    val estimate: PositionEstimate?,
    val prediction: Prediction?,
    val predictionReceivedAt: Double?,
    /** Phones the latest report came through, oldest first. */
    val route: List<String>,
)

/** A Bluetooth link with a fresh RSSI, from the phones' reports. */
data class GhostLink(
    val a: String,
    val b: String,
    val rssi: Double,
) {
    val id: String get() = a + "\n" + b
}

/**
 * The app side of GhostCore: feeds the pipeline (MeshCore GhostCorePipeline) once a second with this
 * phone's GPS, the mesh reports, Bluetooth observations and relayed records, and publishes what it
 * decides. Scenario inputs enter only through `inject` and `play`, and only as raw inputs.
 */
class GhostCoreHub(context: Context) {
    data class Inputs(
        var reports: List<DeviceUpdate>,
        var receivedAt: Map<String, Double>,
        var paths: Map<String, List<String>>,
        var location: LocationFix?,
        var simulateGPSLoss: Boolean,
        /** The typed spot, when the phone's source is manual. */
        var declared: GhostCorePipeline.Declared?,
        var observations: List<PeerObservation>,
        var records: List<ReceivedRecord>,
    )

    /** Swift's `player` tuple. */
    private data class Player(
        val scenario: Scenario,
        val role: String,
        val roles: Map<String, String>,
        val start: Double,
        val next: Int,
        val caption: String?,
    )

    private val appContext = context.applicationContext

    var phones: List<GhostPhone> by mutableStateOf(emptyList())
        private set
    var links: List<GhostLink> by mutableStateOf(emptyList())
        private set
    var scenario: ScenarioState? by mutableStateOf(null)
        private set
    var integrityEngineActive: Boolean by mutableStateOf(false)
        private set

    /** A scenario fault or a forced link is active on this phone: show SIMULATED. */
    var simulationActive: Boolean by mutableStateOf(false)
        private set

    /** Peers whose link this phone is forcing down (the relay's test link filter, via `inject`). */
    var forcedDown: Set<String> by mutableStateOf(emptySet())
        private set

    /** Scenarios bundled from contract/scenarios/ (S0–S6). */
    val availableScenarios: List<Scenario> = bundledScenarios(appContext)

    /** What this phone should publish as its own report (GPS only when GhostCore lets it). */
    var publication = GhostCorePipeline.Publication(Position(0.0, 0.0, 0.0), null, PositionSource.none)
        private set

    /** Applies a forced link change to the transport (the relay's test link filter). */
    var onPeerLink: ((peerId: String, up: Boolean) -> Unit)? = null

    val me: GhostPhone? get() = phones.firstOrNull { it.isSelf }

    private var pipeline: GhostCorePipeline? = null

    /**
     * The positioning agent's engine for this phone: motion for the integrity engine, and this
     * phone's own dead-reckoned / fused estimate.
     */
    var positioning: PositioningService? = null
        private set
    private var selfId = ""
    private var frameId = GeoFrame.defaultFrameId
    private var lastFixTime: Double? = null
    private var gpsLost = false
    private var player: Player? = null
    private var epochId = UUID.randomUUID().toString().uppercase()
    private var sequence = 0L

    /** The feature switches the engines were built for (`configure`). */
    private var features = FeatureFlags()

    /**
     * Starts over for this phone and frame (mesh start or frame change). `gpsCheck` runs the GNSS
     * integrity engine: then only trusted GPS is published and anchors others. It needs motion, which
     * PositioningService provides; without it no phone could ever be trusted (ARCHITECTURE.md §6).
     */
    fun reset(selfId: String, frameId: String, gpsCheck: Boolean, features: FeatureFlags) {
        stop()
        positioning?.stop()
        this.selfId = selfId
        this.frameId = frameId
        this.features = features.copy()
        val positioning = PositioningService(appContext, selfId, frameId)
        positioning.useMotion = features.motion
        positioning.useCompass = features.compass
        positioning.start()
        this.positioning = positioning
        // By default peers without a position are placed by the signal map, the solver the dashboard
        // and the Track tab run, so all three agree and UWB distances count (docs/AUDIT.md §1.1).
        pipeline = GhostCorePipeline(
            configuration = GhostCorePipeline.Configuration(selfId, frameId),
            integrity = if (gpsCheck) GNSSIntegrityMonitor(subjectId = selfId, frameId = frameId) else null,
            positioning = makePlacement(features),
            prediction = makePrediction(features.prediction),
        )
        lastFixTime = null
        gpsLost = false
        epochId = UUID.randomUUID().toString().uppercase()
        sequence = 0
        phones = emptyList()
        links = emptyList()
        integrityEngineActive = false
        simulationActive = false
    }

    /**
     * Applies changed feature switches while running: the sensors, and the placement and prediction
     * engines (a replaced engine starts without history; a kept one only changes its settings).
     */
    fun configure(new: FeatureFlags) {
        val old = features
        features = new.copy()
        positioning?.useMotion = new.motion
        positioning?.useCompass = new.compass
        val pipeline = pipeline ?: return
        val signalMap = pipeline.positioning as? SignalMapPositioning
        if (new.peerPlacement != old.peerPlacement) {
            pipeline.positioning = makePlacement(new)
        } else if (signalMap != null) {
            signalMap.ranges = new.mainMapRanges
            signalMap.calibrate = new.calibrateRadio
        }
        if (new.prediction != old.prediction) pipeline.prediction = makePrediction(new.prediction)
    }

    private fun makePlacement(features: FeatureFlags): GhostPositioningEngine = when (features.peerPlacement) {
        PeerPlacement.signalMap -> {
            val engine = SignalMapPositioning(producerId = selfId, frameId = frameId)
            engine.ranges = features.mainMapRanges
            engine.calibrate = features.calibrateRadio
            engine
        }
        PeerPlacement.peerLocator -> Positioning.PeerLocator(producerId = selfId, frameId = frameId)
        PeerPlacement.particleFilter -> EstimatorPositioning(producerId = selfId, frameId = frameId)
    }

    private fun makePrediction(mode: PredictionMode): GhostPredictionEngine = when (mode) {
        PredictionMode.model -> GhostPredictor(producerId = selfId, frameId = frameId)
        PredictionMode.walkingCircle -> WalkingCirclePrediction(producerId = selfId)
        PredictionMode.off -> NoPrediction()
    }

    /** One step. Returns the records this phone should send over the mesh. */
    fun step(inputs: Inputs, now: Double = currentTime()): List<RelayMessage> {
        val pipeline = pipeline ?: return emptyList()
        val t = now
        advancePlayer(t)

        if (inputs.simulateGPSLoss != gpsLost) {
            gpsLost = inputs.simulateGPSLoss
            pipeline.apply(ScenarioInput.gnssOutage(selfId, gpsLost), t)
        }
        feedPositioning(inputs, t)
        val location = inputs.location
        if (!gpsLost && location != null && location.timestamp != lastFixTime) {
            val fix = fix(location)
            if (fix != null) {
                lastFixTime = location.timestamp
                pipeline.ingest(fix = fix, receivedAt = t)
            }
        }
        for (update in inputs.reports) {
            val at = inputs.receivedAt[update.id] ?: continue
            pipeline.ingest(report = update, receivedAt = at, path = inputs.paths[update.id] ?: emptyList())
        }
        pipeline.ingest(observations = inputs.observations)
        for (record in inputs.records) pipeline.ingest(record = record.message, receivedAt = record.receivedAt)
        pipeline.declared = inputs.declared

        val output = pipeline.step(t)
        publication = output.publication
        // First report wins, like Swift's `uniquingKeysWith: { a, _ in a }`.
        val labels = LinkedHashMap<String, String?>()
        for (report in inputs.reports) if (report.id !in labels) labels[report.id] = report.label
        phones = output.phones.map { p ->
            GhostPhone(
                id = p.id, label = labels[p.id] ?: p.label ?: p.id.take(6), isSelf = p.isSelf,
                selected = p.selected, positionReceivedAt = p.selectedReceivedAt, gnssUnconfirmed = p.gnssUnconfirmed,
                rawFix = p.rawFix, integrity = p.integrity, integrityReceivedAt = p.integrityReceivedAt,
                estimate = p.estimate, prediction = p.prediction, predictionReceivedAt = if (p.prediction == null) null else t,
                route = p.route,
            )
        }
        links = output.links.map { GhostLink(it.a, it.b, it.rssi) }
        integrityEngineActive = output.integrityEngineActive
        simulationActive = pipeline.faults.isActive || forcedDown.isNotEmpty()
        return output.records.mapNotNull { relayMessage(it, t) }
    }

    /**
     * This phone's motion and own estimate from PositioningService, and its inputs: GPS (trusted only
     * with this phone's trusted assessment and no scenario fault), Bluetooth snapshots, and peers'
     * positions that may anchor (their relayed assessment says trusted).
     */
    private fun feedPositioning(inputs: Inputs, t: Double) {
        val positioning = positioning ?: return
        val pipeline = pipeline ?: return
        positioning.gnssHidden = gpsLost || pipeline.faults.outage
        val location = inputs.location
        if (location != null && !positioning.gnssHidden) {
            val trusted = me?.integrity?.mayAnchorOthers == true && !pipeline.faults.isActive
            positioning.ingest(location = location, trusted = trusted)
        }
        for (observation in inputs.observations) positioning.ingest(observation = observation)
        for (phone in phones) {
            if (phone.isSelf) continue
            val selected = phone.selected ?: continue
            val integrity = phone.integrity ?: continue
            if (selected.kind != PositionEstimate.Kind.measured) continue
            positioning.ingest(relayed = selected, integrity = integrity)
        }
        val motion = positioning.motionObservation(window = 1.0)
        val valid = try {
            motion.validate()
            true
        } catch (e: Exception) {
            false
        }
        if (valid) pipeline.ingest(motion = motion)
        val own = positioning.tick(simulated = pipeline.faults.isActive)
        pipeline.ingest(ownEstimate = own, receivedAt = t)
    }

    // MARK: Scenarios

    /**
     * A raw input for this phone. GNSS faults act on this phone's own GPS; a link input forces this
     * phone's link to `peerId` down or lets it up.
     */
    fun inject(input: ScenarioInput) {
        val pipeline = pipeline ?: return
        val t = currentTime()
        if (input is ScenarioInput.peerLink) {
            val peer = input.peerId
            forcedDown = if (input.up) forcedDown - peer else forcedDown + peer
            onPeerLink?.invoke(peer, input.up)
        } else {
            pipeline.apply(retarget(input, selfId), t)
        }
        simulationActive = pipeline.faults.isActive || forcedDown.isNotEmpty()
    }

    /**
     * Plays `scenario` as the phone `role` (e.g. "phone-c"): only that phone's steps run here.
     * `roles` maps the scenario's other phone IDs to device IDs, for link steps.
     */
    fun play(scenario: Scenario, role: String, roles: Map<String, String> = emptyMap()) {
        stop()
        player = Player(scenario, role, roles, currentTime(), 0, null)
        this.scenario = ScenarioState(
            scenarioId = scenario.id, title = scenario.title, elapsed = 0.0, stepIndex = 0,
            caption = null, isRunning = true,
        )
    }

    /** Stops the scenario and removes every fault and forced link it left. */
    fun stop() {
        player = null
        scenario = null
        pipeline?.apply(ScenarioInput.gnssClear(selfId), currentTime())
        for (peer in forcedDown) onPeerLink?.invoke(peer, true)
        forcedDown = emptySet()
        simulationActive = false
    }

    private fun advancePlayer(t: Double) {
        var p = player ?: return
        val elapsed = t - p.start
        val steps = p.scenario.steps.sortedBy { it.at }
        while (p.next < steps.size && steps[p.next].at <= elapsed) {
            val step = steps[p.next]
            p = p.copy(next = p.next + 1)
            if (step.caption != null) p = p.copy(caption = step.caption)
            if (step.input.subjectId != p.role) continue
            val input = step.input
            if (input is ScenarioInput.peerLink) {
                val peer = p.roles[input.peerId] ?: continue
                inject(ScenarioInput.peerLink(selfId, peer, input.up))
            } else {
                inject(input)
            }
        }
        val done = elapsed > p.scenario.duration
        player = if (done) null else p
        scenario = ScenarioState(
            scenarioId = p.scenario.id, title = p.scenario.title, elapsed = min(elapsed, p.scenario.duration),
            stepIndex = p.next, caption = p.caption, isRunning = !done,
        )
    }

    // MARK: Mapping

    /**
     * An Android fix as a raw GNSS record in the shared frame. `LocationFix` carries no speed or
     * course (Core Location's `speed`/`course`), so the record has no velocity.
     */
    private fun fix(location: LocationFix): PositionEstimate? {
        if (location.horizontalAccuracy < 0) return null
        val position = GeoFrame.position(frameId, location.coordinate.latitude, location.coordinate.longitude) ?: return null
        val t = location.timestamp
        val fix = PositionEstimate(
            subjectId = selfId, timestamp = t, frameId = frameId, kind = PositionEstimate.Kind.measured,
            method = PositionEstimate.Method.gnss, position = position,
            uncertainty = PositionUncertainty(
                r95 = min(PositionUncertainty.r95(fromRadius68 = location.horizontalAccuracy), GhostCoreContract.maxRadius),
            ),
            velocity = null, lastAbsoluteAt = t, source = EvidenceSource.gnss,
            freshness = Freshness(ageAtHandoff = max(0.0, currentTime() - location.timestamp), maxAge = 30.0),
            provenance = Provenance(producerId = selfId, algorithm = "android-location@1", gnssDependent = true),
        )
        return try {
            fix.validate()
            fix
        } catch (e: Exception) {
            null
        }
    }

    /**
     * This phone's record wrapped for the mesh. An assessment too large for one record loses its
     * evidence detail beyond the first four checks; the status and reasons always travel.
     */
    private fun relayMessage(payload: RelayMessage.Payload, t: Double): RelayMessage? {
        val full = (payload as? RelayMessage.Payload.integrity)?.value ?: return null
        val trimmed = full.copy(evidence = full.evidence.take(4))
        for (candidate in listOf(full, trimmed)) {
            sequence += 1
            val message = RelayMessage(
                originId = selfId, epochId = epochId, sequence = sequence, timestamp = t, frameId = frameId,
                hopsRemaining = 4, freshness = candidate.freshness, payload = RelayMessage.Payload.integrity(candidate),
            )
            val fits = try {
                message.encoded()
                true
            } catch (e: Exception) {
                false
            }
            if (fits) return message
        }
        return null
    }

    companion object {
        private fun retarget(input: ScenarioInput, id: String): ScenarioInput = when (input) {
            is ScenarioInput.gnssOutage -> ScenarioInput.gnssOutage(id, input.active)
            is ScenarioInput.gnssJump -> ScenarioInput.gnssJump(id, input.dx, input.dz)
            is ScenarioInput.gnssDrift -> ScenarioInput.gnssDrift(id, input.metersPerSecond, input.bearingDegrees)
            is ScenarioInput.gnssClear -> ScenarioInput.gnssClear(id)
            is ScenarioInput.peerLink -> ScenarioInput.peerLink(id, input.peerId, input.up)
        }

        /** contract/scenarios/S*.json, bundled into the assets by app/build.gradle.kts. */
        private fun bundledScenarios(context: Context): List<Scenario> {
            val assets = context.assets
            val names = try {
                assets.list("")?.toList() ?: emptyList()
            } catch (e: Exception) {
                emptyList()
            }
            return names
                .filter { Regex("^S[0-9]+\\.json$").matches(it) }
                .mapNotNull { name ->
                    try {
                        val text = assets.open(name).use { it.readBytes().decodeToString() }
                        MeshJson.decodeFromString(Scenario.serializer(), text)
                    } catch (e: Exception) {
                        null
                    }
                }
                .sortedBy { it.id }
        }
    }
}
