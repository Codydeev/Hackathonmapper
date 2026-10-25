package com.hackathonmapper.meshmapper

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.hackathonmapper.meshcore.DeviceUpdate
import com.hackathonmapper.meshcore.DistanceInputs
import com.hackathonmapper.meshcore.DistanceLab
import com.hackathonmapper.meshcore.DistanceReading
import com.hackathonmapper.meshcore.DistanceTrial
import com.hackathonmapper.meshcore.FloorPoint
import com.hackathonmapper.meshcore.PositionSource
import com.hackathonmapper.meshcore.RadioModel
import com.hackathonmapper.meshcore.currentTime

/**
 * The Track tab's distance comparison: every `DistanceMethod`'s reading of this phone's link to one
 * linked neighbor, refreshed each second, and a tape-measure trial that scores them. MeshModel feeds
 * it once a second; the methods and the scoring live in MeshCore (`DistanceLab`, `DistanceTrial`).
 */
class DistanceLabModel {
    /** The neighbor being compared; the first linked one when null or no longer linked. */
    var peerId: String? by mutableStateOf(null)
    var readings: List<DistanceReading> by mutableStateOf(emptyList())
        private set

    /** The trial running now. */
    var trial: DistanceTrial? by mutableStateOf(null)
        private set

    /** The last finished trial, kept for its scores and CSV. */
    var finished: DistanceTrial? by mutableStateOf(null)
        private set

    /** The radio model the signal map calibrated, shown next to the calibrated method. */
    var calibratedRadio: RadioModel by mutableStateOf(RadioModel.standard)
        private set

    private var lab = DistanceLab()

    fun reset() {
        lab = DistanceLab()
        readings = emptyList()
        trial = null
        peerId = null
    }

    fun update(
        neighbors: List<MeshNeighbor>,
        selfId: String,
        reports: Map<String, DeviceUpdate>,
        uwb: UWBRanging,
        tracker: BluetoothTracker,
        ownGPS: GpsPosition?,
        now: Double = currentTime(),
    ) {
        val t = now
        // Raw readings for the median filter, from the same statistics the smoothed value comes from.
        for (neighbor in neighbors) {
            val statistics = neighbor.connectionRSSI ?: neighbor.advertisementRSSI ?: continue
            lab.add(statistics.recentSamples.map { Pair(it.rssi.toDouble(), it.at) }, neighbor.deviceId)
        }
        lab.prune(t)
        lab.calibratedRadio = tracker.radio
        if (calibratedRadio != tracker.radio) calibratedRadio = tracker.radio

        val linked = neighbors.map { it.deviceId }
        val chosen = trial?.peerId ?: peerId?.takeIf { it in linked } ?: linked.firstOrNull()
        if (chosen != peerId) peerId = chosen
        val neighbor = chosen?.let { peer -> neighbors.firstOrNull { it.deviceId == peer } }
        if (chosen == null || neighbor == null) {
            if (readings.isNotEmpty()) readings = emptyList()
            return
        }
        val peer: String = chosen
        val report = reports[peer]
        val inputs = DistanceInputs()
        inputs.uwb = uwb.reading(peer, now)?.distance
        inputs.smoothedRSSI = (neighbor.connectionRSSI ?: neighbor.advertisementRSSI)?.smoothed
        inputs.peerRSSI = report?.neighbors?.firstOrNull { it.id == selfId }?.rssi?.toDouble()
        inputs.signalMap = tracker.link(selfId, peer)?.layout
        if (ownGPS != null) {
            inputs.ownGPS = FloorPoint(ownGPS.position.x, ownGPS.position.z)
            inputs.ownGPSR95 = ownGPS.accuracy
        }
        if (report != null && report.positionSource == PositionSource.gps) {
            inputs.peerGPS = FloorPoint(report.position.x, report.position.z)
            inputs.peerGPSR95 = report.accuracyMeters
        }
        val current = lab.readings(peer, inputs, t)
        if (current != readings) readings = current
        // Swift mutates the published struct in place; here a recorded copy replaces it so Compose sees it.
        val running = trial
        if (running != null) {
            val next = running.copy()
            next.record(current, t)
            trial = next
        }
    }

    fun startTrial(trueDistance: Double, peerLabel: String) {
        val peerId = peerId ?: return
        if (!trueDistance.isFinite() || trueDistance <= 0) return
        trial = DistanceTrial(peerId = peerId, peerLabel = peerLabel, trueDistance = trueDistance, startedAt = currentTime())
    }

    fun stopTrial() {
        finished = trial
        trial = null
    }
}
