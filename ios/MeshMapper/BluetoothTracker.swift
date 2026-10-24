import Combine
import Foundation
import MeshCore

/// One phone as the Track tab shows it, in the shared frame (x east, z north, meters).
struct TrackedPhone: Identifiable {
    enum State: Equatable {
        /// Reports its own position (GPS or a typed spot).
        case placed(PositionSource)
        /// Has no position of its own; placed from Bluetooth this second.
        case estimated
        /// Nothing fresh: shown at its last spot, with a circle that grows at walking pace.
        case lastSeen
        /// No position and no Bluetooth path to a placed phone yet.
        case unplaced
    }

    let id: String
    let label: String
    let isSelf: Bool
    let state: State
    let point: FloorPoint?
    /// Reported accuracy for a placed phone, r95 for an estimate, the grown circle when last seen.
    let radius: Double?
    let ambiguous: Bool
    let hops: Int?
    let cloud: [FloorPoint]
    let trail: [FloorPoint]
    /// When the shown point was last confirmed.
    let since: Date
}

/// A Bluetooth link with a fresh RSSI, as fed to the estimator.
struct TrackedLink: Identifiable {
    let a: String
    let b: String
    let rssi: Double
    var id: String { a + "\n" + b }
}

/// Runs the Bluetooth estimator on this phone, once a second, over the reports the mesh already
/// delivers (every phone's position source and its neighbours' RSSI). No network is involved, so
/// every phone can see where a phone without GPS is.
@MainActor
final class BluetoothTracker: ObservableObject {
    /// Matches the dashboard's stale limit.
    static let reportMaxAge: TimeInterval = 15
    /// Longer than the dashboard's 4 s: a report may spend a few seconds relaying through the mesh.
    static let linkMaxAge: TimeInterval = 6
    /// How long a phone that went out of reach stays on screen.
    static let rememberFor: TimeInterval = 600
    /// m/s a phone out of reach may have walked since its last spot.
    static let walkingSpeed = 1.4
    static let trailLength = 120

    let radio = RadioModel.outdoors
    @Published private(set) var phones: [TrackedPhone] = []
    @Published private(set) var links: [TrackedLink] = []

    private var estimator = BluetoothEstimator()
    private var lastSpot: [String: (point: FloorPoint, radius: Double, at: Date)] = [:]
    private var trails: [String: [FloorPoint]] = [:]
    private var sources: [String: PositionSource] = [:]

    var me: TrackedPhone? { phones.first { $0.isSelf } }

    func reset() {
        estimator = BluetoothEstimator()
        lastSpot = [:]
        trails = [:]
        sources = [:]
        phones = []
        links = []
    }

    func update(reports: [DeviceUpdate], receivedAt: [String: Date], selfId: String, now: Date = Date()) {
        let input = BluetoothEstimator.input(reports: reports, receivedAt: receivedAt, now: now,
                                             reportMaxAge: Self.reportMaxAge, linkMaxAge: Self.linkMaxAge)
        let estimates = input.lost.isEmpty
            ? [:]
            : estimator.update(anchors: input.anchors, lost: input.lost, measurements: input.measurements)

        var result: [TrackedPhone] = []
        for report in reports {
            let id = report.id
            let source = report.positionSource ?? .manual
            // A placeholder and a real position are different tracks.
            if sources[id] != source { trails[id] = [] }
            sources[id] = source
            let reportedAt = receivedAt[id] ?? .distantPast
            let fresh = now.timeIntervalSince(reportedAt) <= Self.reportMaxAge
            let label = report.label ?? shortID(id)

            func phone(_ state: TrackedPhone.State, _ point: FloorPoint?, radius: Double?, since: Date,
                       estimate: BluetoothEstimate? = nil) -> TrackedPhone {
                TrackedPhone(id: id, label: label, isSelf: id == selfId, state: state, point: point, radius: radius,
                             ambiguous: estimate?.ambiguous ?? false, hops: estimate?.hops,
                             cloud: estimate?.cloud ?? [], trail: trails[id] ?? [], since: since)
            }

            if fresh, source != .none {
                let point = FloorPoint(x: report.position.x, z: report.position.z)
                lastSpot[id] = (point, report.accuracyMeters ?? 0, reportedAt)
                appendTrail(id, point)
                result.append(phone(.placed(source), point, radius: report.accuracyMeters, since: reportedAt))
            } else if fresh, let estimate = estimates[id] {
                let point = FloorPoint(x: estimate.x, z: estimate.z)
                lastSpot[id] = (point, estimate.r95, now)
                appendTrail(id, point)
                result.append(phone(.estimated, point, radius: estimate.r95, since: now, estimate: estimate))
            } else if let last = lastSpot[id], now.timeIntervalSince(last.at) <= Self.rememberFor {
                let grown = last.radius + Self.walkingSpeed * now.timeIntervalSince(last.at)
                result.append(phone(.lastSeen, last.point, radius: grown, since: last.at))
            } else if fresh {
                result.append(phone(.unplaced, nil, radius: nil, since: reportedAt))
            }
        }
        lastSpot = lastSpot.filter { now.timeIntervalSince($0.value.at) <= Self.rememberFor }
        phones = result.sorted { ($0.isSelf ? 0 : 1, $0.label) < ($1.isSelf ? 0 : 1, $1.label) }
        links = input.measurements.map { TrackedLink(a: $0.a, b: $0.b, rssi: $0.rssi) }
    }

    private func appendTrail(_ id: String, _ point: FloorPoint) {
        var trail = trails[id] ?? []
        trail.append(point)
        if trail.count > Self.trailLength { trail.removeFirst(trail.count - Self.trailLength) }
        trails[id] = trail
    }
}
