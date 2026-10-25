package com.hackathonmapper.meshcore

// MARK: - Engine slots

/** Judges this phone's own GNSS (gnss trust agent: GNSSIntegrityMonitor). */
interface GhostIntegrityEngine {
    /** The latest raw fix, after scenario faults; judged at the next `assess`. */
    fun ingest(fix: PositionEstimate)
    fun ingest(motion: MotionObservation)
    /** `evidence`: current estimates of this phone from other sources (Bluetooth, typed spots). */
    fun assess(subjectId: String, evidence: List<PositionEstimate>, now: Double): IntegrityAssessment
}

/** Places phones that have no trusted position of their own (positioning agent). */
interface GhostPositioningEngine {
    /**
     * `anchors`: positions that may anchor others. `lost`: phones to place. `links`: averaged RSSI per
     * phone pair from the mesh reports. Returns estimates for the lost phones it could place.
     */
    fun place(
        anchors: List<PositionEstimate>,
        lost: List<String>,
        links: List<LinkMeasurement>,
        observations: List<PeerObservation>,
        now: Double,
    ): List<PositionEstimate>
}

/** Predicts where a phone went after it was last observed (prediction agent). */
interface GhostPredictionEngine {
    fun observe(estimate: PositionEstimate, receivedAt: Double)
    fun observe(motion: MotionObservation)
    /** Nil while the subject is observed live, or once it is lost beyond the horizon. Swift: `predict(subjectId:at:)`. */
    fun predict(subjectId: String, now: Double): Prediction?
}

// MARK: - Baselines (today's code)

/** The on-phone Bluetooth particle filter that build 7 runs (BluetoothEstimator). */
class EstimatorPositioning(
    private val producerId: String,
    private val frameId: String,
    options: BluetoothEstimator.Options = BluetoothEstimator.Options(),
) : GhostPositioningEngine {
    private val estimator = BluetoothEstimator(options)

    override fun place(
        anchors: List<PositionEstimate>,
        lost: List<String>,
        links: List<LinkMeasurement>,
        observations: List<PeerObservation>,
        now: Double,
    ): List<PositionEstimate> {
        if (lost.isEmpty()) return emptyList()
        val usable = anchors.filter { it.position != null }
        val estimates = estimator.update(
            anchors = usable.map { a ->
                EstimatorAnchor(id = a.subjectId, x = a.position!!.x, z = a.position.z,
                    // The estimator expects a ~68 % radius, like iOS horizontalAccuracy.
                    accuracy = a.uncertainty.r95 / PositionUncertainty.r95(fromRadius68 = 1.0))
            },
            lost = lost, measurements = links)
        val lastAbsolute = usable.maxOfOrNull { it.timestamp }
        val inputs = usable.take(GhostCoreContract.maxInputs - 1).map {
            ProvenanceInput(source = it.source, id = it.subjectId, used = true, reason = "anchor")
        } + ProvenanceInput(source = EvidenceSource.bluetooth, used = true, reason = "${links.size} link RSSI")
        val provenance = Provenance.derived(producerId = producerId, algorithm = "bluetooth-estimator@1", inputs = inputs,
            from = usable.map { it.provenance })
        return lost.mapNotNull { id ->
            val e = estimates[id] ?: return@mapNotNull null
            if (e.hops == null) return@mapNotNull null
            PositionEstimate(subjectId = id, timestamp = now, frameId = frameId, kind = PositionEstimate.Kind.estimated,
                method = PositionEstimate.Method.particle,
                position = Position(x = e.x, y = 0.0, z = e.z),
                uncertainty = PositionUncertainty(r95 = minOf(e.r95, GhostCoreContract.maxRadius), ambiguous = e.ambiguous),
                lastAbsoluteAt = lastAbsolute, source = EvidenceSource.bluetooth,
                freshness = Freshness(maxAge = 6.0), provenance = provenance)
        }
    }
}

/** Build 7's "last seen" rule as a prediction: the last spot, with a circle growing at walking pace. */
class WalkingCirclePrediction(private val producerId: String) : GhostPredictionEngine {
    private data class LastSeen(val estimate: PositionEstimate, val at: Double)

    private val last = HashMap<String, LastSeen>()

    override fun observe(estimate: PositionEstimate, receivedAt: Double) {
        if (estimate.kind == PositionEstimate.Kind.predicted || estimate.kind == PositionEstimate.Kind.unavailable ||
            estimate.position == null
        ) return
        val observedAt = receivedAt - estimate.freshness.ageAtHandoff
        val previous = last[estimate.subjectId]
        if (previous != null && previous.at > observedAt) return
        last[estimate.subjectId] = LastSeen(estimate, observedAt)
    }

    override fun observe(motion: MotionObservation) {}

    override fun predict(subjectId: String, now: Double): Prediction? {
        val (estimate, at) = last[subjectId] ?: return null
        val position = estimate.position ?: return null
        val age = now - at
        if (!(age > liveFor && age <= horizon)) return null
        val r95 = minOf(estimate.uncertainty.r95 + walkingSpeed * age, GhostCoreContract.maxRadius)
        return Prediction(subjectId = subjectId, timestamp = now, frameId = estimate.frameId, method = Prediction.Method.stationary,
            lastObservedAt = at, lastObservedPosition = position, center = position,
            uncertainty = PositionUncertainty(r95 = r95), freshness = Freshness(maxAge = 10.0),
            provenance = Provenance.derived(producerId = producerId, algorithm = "walking-circle@1",
                inputs = listOf(ProvenanceInput(source = estimate.source, id = subjectId, age = age, used = true,
                    reason = "last observed")),
                from = listOf(estimate.provenance)))
    }

    companion object {
        const val walkingSpeed = 1.4
        /** An observation newer than this is live: no prediction. */
        const val liveFor = 5.0
        const val horizon = 600.0
    }
}

/** No prediction: a phone that went silent just ages out (the "off" feature switch). */
class NoPrediction : GhostPredictionEngine {
    override fun observe(estimate: PositionEstimate, receivedAt: Double) {}
    override fun observe(motion: MotionObservation) {}
    override fun predict(subjectId: String, now: Double): Prediction? = null
}

// MARK: - Pipeline

/**
 * Runs the GhostCore engines once a second on one phone and decides what is shown and published
 * (ARCHITECTURE.md §6). Pure and deterministic: the app's GhostCoreHub, the headless scenario world
 * and the tests all drive this same code.
 */
class GhostCorePipeline(
    val configuration: Configuration,
    var integrity: GhostIntegrityEngine? = null,
    positioning: GhostPositioningEngine? = null,
    prediction: GhostPredictionEngine? = null,
) {
    data class Configuration(
        var selfId: String,
        var frameId: String,
        /** A mesh report older than this is not used (matches the dashboard's stale limit). */
        var reportMaxAge: Double = 15.0,
        /** Bluetooth links reported longer ago than this are not used to place phones. */
        var linkMaxAge: Double = 6.0,
        /** A GNSS fix older than this is not used (a still phone gets few fixes). */
        var gnssMaxAge: Double = 30.0,
        /** Fixes claiming worse than this 68 % accuracy are not used. */
        var gnssMaxAccuracy68: Double = 30.0,
    )

    /** One phone as this phone sees it. */
    data class Phone(
        val id: String,
        val label: String?,
        val isSelf: Boolean,
        /** The one position to show (selection order in ARCHITECTURE.md §6), or nil. */
        val selected: PositionEstimate?,
        /** Local time the selected record was received or produced. */
        val selectedReceivedAt: Double?,
        /** GNSS that is shown but not trusted: integrity says insufficientEvidence or degraded. */
        val gnssUnconfirmed: Boolean,
        /** This phone's own raw GNSS fix after faults, even when rejected (self only). */
        val rawFix: PositionEstimate?,
        /** This phone's own assessment, or a peer's as relayed over the mesh. */
        val integrity: IntegrityAssessment?,
        /** Local time the assessment was made or received. */
        val integrityReceivedAt: Double?,
        val estimate: PositionEstimate?,
        val prediction: Prediction?,
        /** Relays the subject's latest report came through, oldest first. */
        val route: List<String>,
    )

    /** What this phone should publish in its next mesh report. */
    data class Publication(
        val position: Position,
        val accuracyMeters: Double?,
        val source: PositionSource,
    )

    data class Output(
        val phones: List<Phone>,
        val publication: Publication,
        val links: List<LinkMeasurement>,
        val integrityEngineActive: Boolean,
        /** Records this phone should send over the mesh: its own integrity assessment. */
        val records: List<RelayMessage.Payload>,
    )

    /** Swift's `(position:, accuracyMeters:)` tuple for a typed spot. */
    data class Declared(val position: Position, val accuracyMeters: Double?)

    private data class Fix(val estimate: PositionEstimate, val receivedAt: Double)
    private data class Report(val update: DeviceUpdate, val receivedAt: Double, val path: List<String>)
    private data class PeerAssessment(val assessment: IntegrityAssessment, val receivedAt: Double)
    private data class Positioned(val estimate: PositionEstimate, val receivedAt: Double)

    var positioning: GhostPositioningEngine =
        positioning ?: EstimatorPositioning(producerId = configuration.selfId, frameId = configuration.frameId)
    var prediction: GhostPredictionEngine = prediction ?: WalkingCirclePrediction(producerId = configuration.selfId)

    private var faultState = GNSSFaults()
    /** The active GNSS faults (a copy: Swift's `private(set) var` of a struct). */
    val faults: GNSSFaults get() = faultState.copy()

    /** A typed spot for this phone (Position tab / Pin me), published as declared. */
    var declared: Declared? = null

    private val selfId: String get() = configuration.selfId
    private var fix: Fix? = null
    private var observations: List<PeerObservation> = emptyList()
    private val reports = HashMap<String, Report>()
    private var lastAssessment: IntegrityAssessment? = null
    private var peerIntegrity: Map<String, PeerAssessment> = emptyMap()
    private var ownEstimate: PositionEstimate? = null
    /** This phone's estimate from the positioning engine (dead reckoning, fusion, ranging), if fresh. */
    private var positioned: Positioned? = null

    // MARK: Inputs

    /** A raw GNSS fix of this phone, before faults. */
    fun ingest(fix: PositionEstimate, receivedAt: Double) {
        if (fix.subjectId != selfId) return
        val faulted = faultState.apply(to = fix) ?: return
        this.fix = Fix(faulted, receivedAt)
        integrity?.ingest(fix = faulted)
    }

    fun ingest(motion: MotionObservation) {
        if (motion.subjectId != selfId) return
        integrity?.ingest(motion = motion)
        prediction.observe(motion = motion)
    }

    /**
     * This phone's own estimate from the positioning engine. Only inferred kinds are used; it replaces
     * the Bluetooth estimator's guess for this phone while it is fresh.
     *
     * Kotlin cannot overload on parameter names alone (`ingest(fix:receivedAt:)` has the same types),
     * so the unused trailing parameter keeps them apart; always call it as
     * `ingest(ownEstimate = e, receivedAt = t)`.
     */
    fun ingest(ownEstimate: PositionEstimate, receivedAt: Double, @Suppress("UNUSED_PARAMETER") ownEstimateOverload: Unit = Unit) {
        if (ownEstimate.subjectId != selfId || ownEstimate.kind != PositionEstimate.Kind.estimated) return
        if (runCatching { ownEstimate.validate() }.isFailure) return
        positioned = Positioned(ownEstimate, receivedAt)
    }

    /** The latest Bluetooth snapshots this phone made of its peers. */
    fun ingest(observations: List<PeerObservation>) {
        this.observations = observations.filter { it.observerId == selfId }
    }

    /** A mesh report, this phone's own included. Older sequences of the same epoch are ignored. */
    fun ingest(report: DeviceUpdate, receivedAt: Double, path: List<String> = emptyList()) {
        val known = reports[report.id]
        if (known != null && known.update.epochId == report.epochId && known.update.sequence >= report.sequence) return
        reports[report.id] = Report(report, receivedAt, path)
    }

    /**
     * A contract record relayed from another phone. Its age is `freshness.ageAtHandoff` plus the
     * local time since `receivedAt`. Peers' integrity assessments are kept per subject.
     */
    fun ingest(record: RelayMessage, receivedAt: Double) {
        if (record.originId == selfId || record.frameId != configuration.frameId) return
        if (runCatching { record.validate() }.isFailure) return
        val payload = record.payload
        if (payload is RelayMessage.Payload.integrity && payload.value.subjectId == record.originId) {
            val assessment = payload.value
            val known = peerIntegrity[assessment.subjectId]
            if (known != null && known.assessment.timestamp >= assessment.timestamp) return
            // Store with the receipt time moved back by the age it already had, so age() stays one clock.
            peerIntegrity = peerIntegrity + (assessment.subjectId to
                PeerAssessment(assessment, receivedAt - record.freshness.ageAtHandoff))
        }
    }

    /** A scenario input. GNSS faults only act on this phone; link inputs are the transport's job. Swift: `apply(_:at:)`. */
    fun apply(input: ScenarioInput, t: Double) {
        if (input.subjectId != selfId) return
        faultState.apply(input, t)
        // A simulated outage means "GPS gone now", like the app's toggle; a real one ages out (gnssMaxAge).
        if (faultState.outage) fix = null
    }

    fun forget(id: String) {
        reports.remove(id)
    }

    // MARK: Step

    fun step(now: Double): Output {
        val frameId = configuration.frameId

        // 1. Own GNSS and its integrity.
        val fix = fix
        var usableFix: PositionEstimate? = null
        if (fix != null && now - fix.estimate.timestamp <= configuration.gnssMaxAge &&
            fix.estimate.uncertainty.r95 <= PositionUncertainty.r95(fromRadius68 = configuration.gnssMaxAccuracy68)
        ) {
            usableFix = fix.estimate
        }
        val engine = integrity
        lastAssessment = if (engine != null) {
            val evidence = ownEstimate?.let { listOf(it) } ?: emptyList()
            engine.assess(subjectId = selfId, evidence = evidence, now = now)
        } else {
            null
        }
        val status = lastAssessment?.status
        // Without an integrity engine the phone behaves like build 7 and shares its GPS, labelled unchecked.
        val gnssTrusted = usableFix != null && (engine == null || status == IntegrityAssessment.Status.trusted)
        val gnssUnconfirmed = usableFix != null && engine != null &&
            (status == IntegrityAssessment.Status.insufficientEvidence || status == IntegrityAssessment.Status.degraded)

        // 2. What this phone publishes: only trusted GNSS anchors others.
        val declared = declared
        val trustedPosition = if (gnssTrusted) usableFix?.position else null
        val publication = when {
            declared != null -> Publication(position = declared.position, accuracyMeters = declared.accuracyMeters,
                source = PositionSource.manual)
            usableFix != null && trustedPosition != null -> Publication(position = trustedPosition,
                accuracyMeters = minOf(usableFix.uncertainty.r95, DashboardContract.maxAccuracyMeters),
                source = PositionSource.gps)
            else -> Publication(position = Position(x = 0.0, y = 0.0, z = 0.0), accuracyMeters = null,
                source = PositionSource.none)
        }

        // 3. Anchors, lost phones and links from the fresh mesh reports.
        val fresh = reports.keys.sorted().mapNotNull { reports[it] }
            .filter { now - it.receivedAt <= configuration.reportMaxAge }.map { it.update }
        val input = BluetoothEstimator.input(
            reports = fresh,
            receivedAt = reports.mapValues { it.value.receivedAt },
            now = now, reportMaxAge = configuration.reportMaxAge,
            linkMaxAge = configuration.linkMaxAge)
        val reported = HashMap<String, PositionEstimate>()
        for (update in fresh) {
            val estimate = estimate(from = update, frameId = frameId, receivedAt = reports[update.id]?.receivedAt ?: now)
            if (estimate != null) reported[update.id] = estimate
        }
        // Only measured or typed positions anchor others; an estimate (a peer's fused tracking) does
        // not, so estimates never prop each other up.
        val anchors = input.anchors.mapNotNull { reported[it.id] }
            .filter { it.kind == PositionEstimate.Kind.measured || it.kind == PositionEstimate.Kind.declared }
        val placed = positioning.place(anchors = anchors, lost = input.lost, links = input.measurements,
            observations = observations, now = now)
        val estimates = HashMap<String, PositionEstimate>()
        for (estimate in placed) {
            if (runCatching { estimate.validate() }.isSuccess) estimates[estimate.subjectId] = estimate
        }
        val positioned = positioned
        if (positioned != null && !positioned.estimate.isStale(receivedAt = positioned.receivedAt, now = now)) {
            estimates[selfId] = positioned.estimate
        }
        ownEstimate = estimates[selfId]

        // 4. Prediction engine observes everything live; predictions for the rest.
        val ids = (reports.keys + selfId).sorted()
        peerIntegrity = peerIntegrity.filter { now - it.value.receivedAt <= configuration.reportMaxAge * 4 }
        for (id in ids) {
            val r = reported[id]
            val at = reports[id]?.receivedAt
            if (r != null && at != null) prediction.observe(estimate = r, receivedAt = at)
            estimates[id]?.let { prediction.observe(estimate = it, receivedAt = now) }
        }
        if (usableFix != null && (gnssTrusted || gnssUnconfirmed)) {
            prediction.observe(estimate = usableFix, receivedAt = fix?.receivedAt ?: now)
        }

        // 5. Selection, per phone.
        val phones = mutableListOf<Phone>()
        for (id in ids) {
            val isSelf = id == selfId
            val report = reports[id]
            val candidates = mutableListOf<Pair<PositionEstimate, Double>>()
            if (isSelf) {
                if (declared != null && declared.position.x.isFinite()) {
                    candidates.add(declaredEstimate(selfId, declared, frameId = frameId, now = now) to now)
                }
                if (gnssTrusted && usableFix != null) candidates.add(usableFix to (fix?.receivedAt ?: now))
            } else {
                val r = reported[id]
                if (r != null && report != null) candidates.add(r to report.receivedAt)
            }
            estimates[id]?.let { candidates.add(it to now) }
            if (isSelf && gnssUnconfirmed && usableFix != null) candidates.add(usableFix to (fix?.receivedAt ?: now))
            val predicted = if (candidates.isEmpty()) prediction.predict(subjectId = id, now = now) else null
            if (predicted != null) candidates.add(predicted.asPositionEstimate to now)
            val selected = candidates.firstOrNull()
            if (!(selected != null || isSelf || (report != null && now - report.receivedAt <= configuration.reportMaxAge))) {
                continue
            }
            var shownIntegrity: PeerAssessment? = null
            if (isSelf) {
                shownIntegrity = lastAssessment?.let { PeerAssessment(it, now) }
            } else {
                val peer = peerIntegrity[id]
                if (peer != null &&
                    !Freshness(maxAge = peer.assessment.freshness.maxAge).isStale(receivedAt = peer.receivedAt, now = now)
                ) {
                    shownIntegrity = peer
                }
            }
            phones.add(Phone(id = id, label = report?.update?.label, isSelf = isSelf, selected = selected?.first,
                selectedReceivedAt = selected?.second,
                gnssUnconfirmed = isSelf && gnssUnconfirmed && selected?.first?.method == PositionEstimate.Method.gnss,
                rawFix = if (isSelf) fix?.estimate else null, integrity = shownIntegrity?.assessment,
                integrityReceivedAt = shownIntegrity?.receivedAt,
                estimate = estimates[id], prediction = predicted, route = report?.path ?: emptyList()))
        }
        return Output(phones = phones, publication = publication, links = input.measurements,
            integrityEngineActive = engine != null,
            records = lastAssessment?.let { listOf(RelayMessage.Payload.integrity(it)) } ?: emptyList())
    }

    // MARK: Mapping

    companion object {
        /**
         * A peer's mesh report as a contract record. Reports carry no age, so freshness starts at receipt.
         * `accuracyMeters` on the wire is a 95 % radius (website/shared/contract.ts). Swift: `estimate(from:frameId:at:)`.
         */
        internal fun estimate(from: DeviceUpdate, frameId: String, receivedAt: Double): PositionEstimate? {
            val update = from
            val source = update.positionSource ?: PositionSource.manual
            val accuracy = update.accuracyMeters ?: 10.0
            val floor = update.positionMode == "floor"
            val position = Position(x = update.position.x, y = if (floor) 0.0 else update.position.y, z = update.position.z)
            val mode = if (floor) PositionMode.floor else PositionMode.threeD
            val uncertainty = PositionUncertainty(r95 = minOf(accuracy, GhostCoreContract.maxRadius))
            return when (source) {
                PositionSource.gps -> PositionEstimate(subjectId = update.id, timestamp = receivedAt, frameId = frameId,
                    kind = PositionEstimate.Kind.measured, method = PositionEstimate.Method.gnss, position = position,
                    positionMode = mode, uncertainty = uncertainty, lastAbsoluteAt = receivedAt, source = EvidenceSource.gnss,
                    freshness = Freshness(maxAge = 15.0),
                    provenance = Provenance(producerId = update.id, algorithm = "mesh-report@1", gnssDependent = true))
                PositionSource.manual -> PositionEstimate(subjectId = update.id, timestamp = receivedAt, frameId = frameId,
                    kind = PositionEstimate.Kind.declared, method = PositionEstimate.Method.manual, position = position,
                    positionMode = mode, uncertainty = uncertainty, lastAbsoluteAt = receivedAt, source = EvidenceSource.manual,
                    freshness = Freshness(maxAge = 15.0),
                    provenance = Provenance(producerId = update.id, algorithm = "mesh-report@1", gnssDependent = false))
                // A fix measured by a UWB direction anchor.
                PositionSource.uwb -> PositionEstimate(subjectId = update.id, timestamp = receivedAt, frameId = frameId,
                    kind = PositionEstimate.Kind.measured, method = PositionEstimate.Method.uwb, position = position,
                    positionMode = mode, uncertainty = uncertainty, lastAbsoluteAt = receivedAt, source = EvidenceSource.uwb,
                    freshness = Freshness(maxAge = 15.0),
                    provenance = Provenance(producerId = update.id, algorithm = "mesh-report@1", gnssDependent = false))
                // The phone's own dead reckoning fused with anchor RSSI: an estimate, never measured. Its
                // anchors may be GPS phones, so it is not independent evidence about GNSS.
                PositionSource.fused -> PositionEstimate(subjectId = update.id, timestamp = receivedAt, frameId = frameId,
                    kind = PositionEstimate.Kind.estimated, method = PositionEstimate.Method.fusion, position = position,
                    positionMode = mode, uncertainty = uncertainty, source = EvidenceSource.fusion,
                    freshness = Freshness(maxAge = 15.0),
                    provenance = Provenance(producerId = update.id, algorithm = "mesh-report@1", gnssDependent = true))
                PositionSource.none -> null
            }
        }

        internal fun declaredEstimate(id: String, declared: Declared, frameId: String, now: Double): PositionEstimate {
            val r95 = declared.accuracyMeters ?: 10.0
            return PositionEstimate(subjectId = id, timestamp = now, frameId = frameId, kind = PositionEstimate.Kind.declared,
                method = PositionEstimate.Method.manual, position = declared.position,
                positionMode = if (declared.position.y == 0.0) PositionMode.floor else PositionMode.threeD,
                uncertainty = PositionUncertainty(r95 = minOf(r95, GhostCoreContract.maxRadius)),
                lastAbsoluteAt = now, source = EvidenceSource.manual, freshness = Freshness(maxAge = 15.0),
                provenance = Provenance(producerId = id, algorithm = "typed-spot@1", gnssDependent = false))
        }
    }
}
