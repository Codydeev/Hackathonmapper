package com.hackathonmapper.meshcore

/**
 * The signal map in the pipeline's positioning slot, so the app's main map places phones without
 * a position the way the dashboard and the Track tab do (`SignalMap`, golden-tested against
 * website/shared/signalmap.ts): every phone in the mesh is laid out so its distances match the
 * links' UWB distances where measured and RSSI ranges otherwise, with measured and typed
 * positions as priors and the radio model calibrated from UWB distances and placed phones.
 *
 * A lost phone whose group the anchors don't fix in direction gets an ambiguous estimate whose
 * circle covers its whole ring, never a confident spot on it. One that the mesh doesn't connect to
 * any anchor gets no estimate: it has no place in the world.
 */
class SignalMapPositioning(
    val producerId: String,
    val frameId: String,
    /** The radio model the solve starts from; each solve calibrates its own copy. */
    val radio: RadioModel = RadioModel.standard,
) : GhostPositioningEngine {
    /** Which distances it uses (a feature switch for comparing them; both by default). */
    var ranges: SignalRanges = SignalRanges.all
    /** Fit the radio model from UWB distances and placed phones each solve; off keeps `radio`. */
    var calibrate: Boolean = true
    /** The radio model after the last solve. */
    var calibratedRadio: RadioModel = radio
        private set
    /** Last layout, so the picture stays put from one second to the next. */
    private var layout: Map<String, FloorPoint> = emptyMap()

    override fun place(
        anchors: List<PositionEstimate>,
        lost: List<String>,
        links: List<LinkMeasurement>,
        observations: List<PeerObservation>,
        now: Double,
    ): List<PositionEstimate> {
        if (lost.isEmpty()) return emptyList()
        val measured = ranges.apply(links)
        val usable = anchors.filter { it.position != null }
        val ids = HashSet<String>(lost)
        for (anchor in usable) ids.add(anchor.subjectId)
        for (link in measured) {
            ids.add(link.a)
            ids.add(link.b)
        }
        val priors = usable.map { anchor ->
            val p = anchor.position!!
            SignalPrior(id = anchor.subjectId, x = p.x, z = p.z, r95 = anchor.uncertainty.r95)
        }
        val result = SignalMap.solve(ids = ids.sorted(), links = measured.map { SignalLink(a = it.a, b = it.b, rssi = it.rssi, uwb = it.uwb) },
            priors = priors, radio = radio, previous = layout, calibrate = calibrate)
        val newLayout = LinkedHashMap<String, FloorPoint>()
        for (node in result.nodes) newLayout.putIfAbsent(node.id, FloorPoint(x = node.x, z = node.z))
        layout = newLayout
        calibratedRadio = result.radio
        val nodes = LinkedHashMap<String, SignalNode>()
        for (node in result.nodes) nodes.putIfAbsent(node.id, node)

        val out = mutableListOf<PositionEstimate>()
        for (id in lost.toSet().sorted()) {
            val node = nodes[id] ?: continue
            val place = SignalMap.placeInWorld(node, nodes) ?: continue
            // The anchors this phone's group hangs on: its evidence and its provenance.
            val group = usable.filter { nodes[it.subjectId]?.component == node.component && it.subjectId != id }
            if (group.isEmpty()) continue
            val usesUWB = result.links.any { (it.a == id || it.b == id) && it.uwb != null }
            val linkCount = result.links.count { it.a == id || it.b == id }
            val inputs = group.take(GhostCoreContract.maxInputs - 1).map {
                ProvenanceInput(source = it.source, id = it.subjectId, used = true, reason = "anchor")
            } + ProvenanceInput(source = if (usesUWB) EvidenceSource.uwb else EvidenceSource.bluetooth, used = true,
                reason = "$linkCount link${if (linkCount == 1) "" else "s"}${if (usesUWB) " with UWB" else ""}")
            val provenance = Provenance.derived(producerId = producerId, algorithm = algorithm, inputs = inputs,
                from = group.map { it.provenance })
            val r95 = minOf(maxOf(place.r95, 0.1), GhostCoreContract.maxRadius)
            val estimate = PositionEstimate(subjectId = id, timestamp = now, frameId = frameId,
                kind = PositionEstimate.Kind.estimated, method = PositionEstimate.Method.multilateration,
                position = Position(x = place.x, y = 0.0, z = place.z),
                uncertainty = PositionUncertainty(r95 = r95, ambiguous = place.ambiguous),
                lastAbsoluteAt = group.maxOfOrNull { it.timestamp },
                source = if (usesUWB) EvidenceSource.uwb else EvidenceSource.bluetooth,
                freshness = Freshness(maxAge = maxAge), provenance = provenance)
            if (runCatching { estimate.validate() }.isSuccess) out.add(estimate)
        }
        return out
    }

    companion object {
        const val algorithm = "signal-map@1"
        /** Matches the other engines' freshness for placed peers. */
        const val maxAge = 6.0
    }
}
