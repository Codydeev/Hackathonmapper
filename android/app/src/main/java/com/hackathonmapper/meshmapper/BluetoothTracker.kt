@file:Suppress("ClassName")

package com.hackathonmapper.meshmapper

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.hackathonmapper.meshcore.DeviceUpdate
import com.hackathonmapper.meshcore.FloorPoint
import com.hackathonmapper.meshcore.PositionSource
import com.hackathonmapper.meshcore.RadioModel
import com.hackathonmapper.meshcore.SignalLink
import com.hackathonmapper.meshcore.SignalMap
import com.hackathonmapper.meshcore.SignalNode
import com.hackathonmapper.meshcore.SignalPrior
import com.hackathonmapper.meshcore.SignalRanges
import com.hackathonmapper.meshcore.WorldPlacement
import com.hackathonmapper.meshcore.currentTime
import kotlin.math.hypot

/** One phone as the Track tab and the map show it, in the shared frame (meters on the floor plane). */
data class TrackedPhone(
    val id: String,
    val label: String,
    val isSelf: Boolean,
    val state: State,
    /** Where world views draw it. Distances between linked phones are the measured Bluetooth ones. */
    val point: FloorPoint?,
    /** 95 % radius: reported accuracy, the signal map's estimate, or the grown circle when last seen. */
    val radius: Double?,
    /** Only the distance is known: the phone is somewhere on `ring`, not necessarily at `point`. */
    val ambiguous: Boolean,
    val ring: Ring?,
    val hops: Int?,
    val cloud: List<FloorPoint>,
    val trail: List<FloorPoint>,
    /** When the shown point was last confirmed. */
    val since: Double,
    /** The position it reported, when `point` was moved to agree with its Bluetooth ranges. */
    val reported: FloorPoint?,
    /** This phone in the signal map (layout coordinates); nil while its report is stale. */
    val signal: SignalNode?,
) {
    data class Ring(val center: FloorPoint, val radius: Double)

    sealed class State {
        /** Reports its own position (GPS, UWB, fused or a typed spot). */
        data class placed(val source: PositionSource) : State()

        /** Has no position of its own; placed from the signal map this second. */
        data object estimated : State()

        /** Nothing fresh: shown at its last spot, with a circle that grows at walking pace. */
        data object lastSeen : State()

        /** No position and no Bluetooth path to a placed phone yet. */
        data object unplaced : State()
    }
}

/** A Bluetooth link with a fresh RSSI, as fed to the signal map. */
data class TrackedLink(
    val a: String,
    val b: String,
    val rssi: Double,
    /** UWB distance one or both ends measured, m; null for an RSSI-only link. */
    val uwb: Double?,
    /** The UWB distance when there is one, else the range from RSSI, m. */
    val measured: Double,
    /** One-sigma error of `measured`, m. */
    val sigma: Double,
    /** Distance on the signal map, m; equal to `measured` when the map fits. */
    val layout: Double,
) {
    val id: String get() = a + "\n" + b
}

/**
 * Runs the signal map on this phone, once a second, over the reports the mesh already delivers
 * (every phone's position source and its neighbours' RSSI and UWB distances). It is the same solver
 * the dashboard and the main map run (MeshCore `SignalMap`, website/shared/signalmap.ts), so they
 * agree, and a phone needs no network to see where a phone without GPS is. This tracker's phones also
 * seed `MovementPredictor`'s likely paths (`MeshModel.tick`).
 */
class BluetoothTracker {
    private data class Spot(val point: FloorPoint, val radius: Double, val at: Double)

    companion object {
        /** Matches the dashboard's stale limit. */
        const val reportMaxAge: Double = 15.0

        /** How long a phone that went out of reach stays on screen. */
        const val rememberFor: Double = 600.0

        /** m/s a phone out of reach may have walked since its last spot. */
        const val walkingSpeed = 1.4
        const val trailLength = 120

        /** A drawn position this far from the report counts as moved (matches the dashboard), m. */
        const val movedReport = 0.5
    }

    /** The shared radio model, calibrated from links between precisely placed phones when there are any. */
    var radio: RadioModel by mutableStateOf(RadioModel.standard)
        private set
    var phones: List<TrackedPhone> by mutableStateOf(emptyList())
        private set
    var links: List<TrackedLink> by mutableStateOf(emptyList())
        private set

    private var rangeSourceState by mutableStateOf(SignalRanges.all)

    /**
     * Which distances the Track tab uses, to compare them: a test setting, back to both after every
     * launch (the tracker also seeds the main map's likely paths). Changing it starts the layout afresh.
     */
    var rangeSource: SignalRanges
        get() = rangeSourceState
        set(value) {
            val old = rangeSourceState
            rangeSourceState = value
            if (value != old) layout = emptyMap()
        }

    /** Fit the radio model live (Features → Calibrate radio model); off keeps the default. */
    var calibrate = true

    private var layout: Map<String, FloorPoint> = emptyMap()
    private var lastSpot: MutableMap<String, Spot> = mutableMapOf()
    private var trails: MutableMap<String, List<FloorPoint>> = mutableMapOf()
    private var sources: MutableMap<String, PositionSource> = mutableMapOf()

    val me: TrackedPhone? get() = phones.firstOrNull { it.isSelf }

    fun reset() {
        radio = RadioModel.standard
        layout = emptyMap()
        lastSpot = mutableMapOf()
        trails = mutableMapOf()
        sources = mutableMapOf()
        phones = emptyList()
        links = emptyList()
    }

    fun update(reports: List<DeviceUpdate>, receivedAt: Map<String, Double>, selfId: String, now: Double = currentTime()) {
        val fresh = reports.filter { report -> receivedAt[report.id]?.let { now - it <= reportMaxAge } ?: false }
        val freshIds = fresh.map { it.id }.toSet()
        val byId = fresh.associateBy { it.id }

        // A fused phone's position already uses its RSSI to placed anchor phones (FusionEngine); using
        // those links again here would count the same evidence twice. A UWB distance it did not use,
        // nor an anchor reporting no position (MeshModel.isPlacedAnchor). Mirrors server/store.ts.
        fun placedAnchor(report: DeviceUpdate): Boolean =
            report.role == "anchor" && report.positionSource != PositionSource.none

        fun usedByFusion(a: DeviceUpdate, b: DeviceUpdate): Boolean =
            (a.positionSource == PositionSource.fused && placedAnchor(b)) ||
                (b.positionSource == PositionSource.fused && placedAnchor(a))

        val signalLinks = mutableListOf<SignalLink>()
        for (report in fresh) {
            val reportAge = now - (receivedAt[report.id] ?: now)
            for (neighbor in report.neighbors ?: emptyList()) {
                val uwb = if (rangeSource == SignalRanges.bluetoothOnly) null else neighbor.uwbDistanceM
                if (rangeSource == SignalRanges.uwbOnly && uwb == null) continue
                val rssi = neighbor.rssi ?: continue
                val other = byId[neighbor.id] ?: continue
                if ((uwb == null && usedByFusion(report, other)) ||
                    reportAge + (neighbor.ageMs ?: 0).toDouble() / 1000 > SignalMap.linkMaxAge
                ) continue
                // Each end's report is a link; the solver averages the two and prefers a UWB distance.
                signalLinks.add(SignalLink(report.id, neighbor.id, rssi.toDouble(), uwb = uwb))
            }
        }
        val priors = fresh.mapNotNull { report ->
            // A missing source comes from an older build and means manual.
            if (report.positionSource == PositionSource.none) null
            else SignalPrior(report.id, report.position.x, report.position.z, report.accuracyMeters)
        }
        val result = SignalMap.solve(fresh.map { it.id }, signalLinks, priors, RadioModel.standard, layout, calibrate = calibrate)
        layout = result.nodes.associate { it.id to FloorPoint(it.x, it.z) }
        radio = result.radio
        val nodes = result.nodes.associateBy { it.id }

        val phones = mutableListOf<TrackedPhone>()
        for (report in reports) {
            val id = report.id
            val source = report.positionSource ?: PositionSource.manual
            // A placeholder and a real position are different tracks.
            if (sources[id] != source) trails[id] = emptyList()
            sources[id] = source
            val reportedAt = receivedAt[id] ?: Double.NEGATIVE_INFINITY
            val isFresh = id in freshIds
            val label = report.label ?: shortID(id)
            val node = if (isFresh) nodes[id] else null
            val placement = node?.let { SignalMap.placeInWorld(it, nodes) }

            fun phone(
                state: TrackedPhone.State,
                point: FloorPoint?,
                radius: Double?,
                since: Double,
                placement: WorldPlacement? = null,
                reported: FloorPoint? = null,
            ): TrackedPhone {
                val ring = placement?.let { p ->
                    val x = p.ringX
                    val z = p.ringZ
                    val r = p.ringRadius
                    if (p.ambiguous && x != null && z != null && r != null) TrackedPhone.Ring(FloorPoint(x, z), r) else null
                }
                return TrackedPhone(
                    id = id, label = label, isSelf = id == selfId, state = state, point = point, radius = radius,
                    ambiguous = placement?.ambiguous ?: false, ring = ring, hops = node?.hops,
                    cloud = placement?.let { SignalMap.ringPoints(it) } ?: emptyList(), trail = trails[id] ?: emptyList(),
                    since = since, reported = reported, signal = node,
                )
            }

            if (isFresh && source != PositionSource.none) {
                val own = FloorPoint(report.position.x, report.position.z)
                if (placement != null && (node?.degree ?: 0) > 0) {
                    // Linked: drawn where the signal map puts it, so its Bluetooth distances hold.
                    val point = FloorPoint(placement.x, placement.z)
                    val moved = hypot(point.x - own.x, point.z - own.z) > movedReport
                    lastSpot[id] = Spot(point, placement.r95, reportedAt)
                    appendTrail(id, point)
                    phones.add(
                        phone(
                            TrackedPhone.State.placed(source), point, radius = placement.r95, since = reportedAt,
                            placement = placement, reported = if (moved) own else null,
                        ),
                    )
                } else {
                    lastSpot[id] = Spot(own, report.accuracyMeters ?: 0.0, reportedAt)
                    appendTrail(id, own)
                    phones.add(phone(TrackedPhone.State.placed(source), own, radius = report.accuracyMeters, since = reportedAt))
                }
            } else if (isFresh && placement != null) {
                val point = FloorPoint(placement.x, placement.z)
                lastSpot[id] = Spot(point, placement.r95, now)
                appendTrail(id, point)
                phones.add(phone(TrackedPhone.State.estimated, point, radius = placement.r95, since = now, placement = placement))
            } else {
                val last = lastSpot[id]
                if (last != null && now - last.at <= rememberFor) {
                    val grown = last.radius + walkingSpeed * (now - last.at)
                    phones.add(phone(TrackedPhone.State.lastSeen, last.point, radius = grown, since = last.at))
                } else if (isFresh) {
                    phones.add(phone(TrackedPhone.State.unplaced, null, radius = null, since = reportedAt))
                }
            }
        }
        lastSpot = lastSpot.filterValues { now - it.at <= rememberFor }.toMutableMap()
        this.phones = phones.sortedWith(compareBy<TrackedPhone> { if (it.isSelf) 0 else 1 }.thenBy { it.label })
        links = result.links.map { TrackedLink(it.a, it.b, it.rssi, it.uwb, it.measured, it.sigma, it.layout) }
    }

    /** The measured Bluetooth link between two phones, if they hear each other directly. */
    fun link(between: String, and: String): TrackedLink? {
        val (first, second) = if (between < and) Pair(between, and) else Pair(and, between)
        return links.firstOrNull { it.a == first && it.b == second }
    }

    private fun appendTrail(id: String, point: FloorPoint) {
        var trail = (trails[id] ?: emptyList()) + point
        if (trail.size > trailLength) trail = trail.drop(trail.size - trailLength)
        trails[id] = trail
    }
}
