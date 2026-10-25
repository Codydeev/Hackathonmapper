import Combine
import Foundation
import MeshCore

/// The Track tab's distance comparison: every `DistanceMethod`'s reading of this phone's link to one
/// linked neighbor, refreshed each second, and a tape-measure trial that scores them. MeshModel feeds
/// it once a second; the methods and the scoring live in MeshCore (`DistanceLab`, `DistanceTrial`).
@MainActor
final class DistanceLabModel: ObservableObject {
    /// The neighbor being compared; the first linked one when nil or no longer linked.
    @Published var peerId: String?
    @Published private(set) var readings: [DistanceReading] = []
    /// The trial running now.
    @Published private(set) var trial: DistanceTrial?
    /// The last finished trial, kept for its scores and CSV.
    @Published private(set) var finished: DistanceTrial?
    /// The radio model the signal map calibrated, shown next to the calibrated method.
    @Published private(set) var calibratedRadio = RadioModel.standard

    private var lab = DistanceLab()

    func reset() {
        lab = DistanceLab()
        readings = []
        trial = nil
        peerId = nil
    }

    func update(neighbors: [MeshNeighbor], selfId: String, reports: [String: DeviceUpdate], uwb: UWBRanging,
                tracker: BluetoothTracker, ownGPS: (position: Position, accuracy: Double)?, now: Date = Date()) {
        let t = now.timeIntervalSince1970
        // Raw readings for the median filter, from the same statistics the smoothed value comes from.
        for neighbor in neighbors {
            guard let statistics = neighbor.connectionRSSI ?? neighbor.advertisementRSSI else { continue }
            lab.add(rawRSSI: statistics.recentSamples.map { (rssi: Double($0.rssi), t: $0.at.timeIntervalSince1970) },
                    from: neighbor.deviceId)
        }
        lab.prune(now: t)
        lab.calibratedRadio = tracker.radio
        if calibratedRadio != tracker.radio { calibratedRadio = tracker.radio }

        let linked = neighbors.map(\.deviceId)
        let chosen = trial?.peerId ?? peerId.flatMap { linked.contains($0) ? $0 : nil } ?? linked.first
        if chosen != peerId { peerId = chosen }
        guard let peer = chosen, let neighbor = neighbors.first(where: { $0.deviceId == peer }) else {
            if !readings.isEmpty { readings = [] }
            return
        }
        let report = reports[peer]
        var inputs = DistanceInputs()
        inputs.uwb = uwb.reading(for: peer, at: now)?.distance
        inputs.smoothedRSSI = (neighbor.connectionRSSI ?? neighbor.advertisementRSSI)?.smoothed
        inputs.peerRSSI = report?.neighbors?.first(where: { $0.id == selfId })?.rssi.map { Double($0) }
        inputs.signalMap = tracker.link(between: selfId, and: peer)?.layout
        if let ownGPS {
            inputs.ownGPS = FloorPoint(x: ownGPS.position.x, z: ownGPS.position.z)
            inputs.ownGPSR95 = ownGPS.accuracy
        }
        if let report, report.positionSource == .gps {
            inputs.peerGPS = FloorPoint(x: report.position.x, z: report.position.z)
            inputs.peerGPSR95 = report.accuracyMeters
        }
        let current = lab.readings(for: peer, inputs: inputs, now: t)
        if current != readings { readings = current }
        trial?.record(current, at: t)
    }

    func startTrial(trueDistance: Double, peerLabel: String) {
        guard let peerId, trueDistance.isFinite, trueDistance > 0 else { return }
        trial = DistanceTrial(peerId: peerId, peerLabel: peerLabel, trueDistance: trueDistance,
                              startedAt: Date().timeIntervalSince1970)
    }

    func stopTrial() {
        finished = trial
        trial = nil
    }
}
