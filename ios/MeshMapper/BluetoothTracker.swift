import Combine
import Foundation
import MeshCore

/// One phone as the Track tab shows it, in the shared frame (x east, z north, meters).
struct TrackedPhone: Identifiable {
    enum State: Equatable {
        /// Reports its own position (GPS or a typed spot).
        case placed(PositionSource)
        /// Has no position of its own; placed from Bluetooth (and UWB distances) this second.
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
    /// Where the shown point comes from; nil when last seen or unplaced.
    let basis: PositionBasis?
    /// Ring or two spots: the direction from the neighbour is unknown, so draw no dot.
    let ambiguous: Bool
    /// For a direction-unresolved phone: the neighbour it is around and the measured distance.
    let ring: EstimateRing?
    let hops: Int?
    let cloud: [FloorPoint]
    let trail: [FloorPoint]
    /// When the shown point was last confirmed.
    let since: Date

    /// No dot for this phone: draw its ring instead.
    var directionUnresolved: Bool { ambiguous && state == .estimated }
}

/// A link with a fresh RSSI and/or UWB distance, as fed to the locator.
struct TrackedLink: Identifiable {
    let a: String
    let b: String
    let rssi: Double?
    /// Distance from `rssi` with the locator's radio model.
    let rssiDistance: Double?
    /// Measured over UWB (meters).
    let uwbDistance: Double?
    /// From `a` towards `b`, map frame.
    let bearing: LinkBearing?
    var id: String { a + "\n" + b }

    /// The distance the map should honour: UWB when there is one.
    var measuredDistance: Double? { uwbDistance ?? rssiDistance }

    func touches(_ id: String) -> Bool { a == id || b == id }
    func other(than id: String) -> String { a == id ? b : a }
}

/// Runs the mesh locator (particle filter plus a layout solver over UWB distances) on this phone,
/// once a second, over the reports the mesh already delivers (every phone's position source and
/// its neighbours' RSSI and UWB distance). No network is involved, so every phone can see where a
/// phone without GPS is.
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

    /// The locator's radio model (calibrated from UWB pairs when it can be).
    var radio: RadioModel { locator.radio }
    @Published private(set) var phones: [TrackedPhone] = []
    @Published private(set) var links: [TrackedLink] = []

    private var locator = MeshLocator()
    private var lastSpot: [String: (point: FloorPoint, radius: Double, at: Date)] = [:]
    private var trails: [String: [FloorPoint]] = [:]
    private var sources: [String: PositionSource] = [:]

    var me: TrackedPhone? { phones.first { $0.isSelf } }

    func reset() {
        locator = MeshLocator()
        lastSpot = [:]
        trails = [:]
        sources = [:]
        phones = []
        links = []
    }

    func update(reports: [DeviceUpdate], receivedAt: [String: Date], selfId: String, now: Date = Date()) {
        let input = BluetoothEstimator.input(reports: reports, receivedAt: receivedAt, now: now,
                                             reportMaxAge: Self.reportMaxAge, linkMaxAge: Self.linkMaxAge)
        // Placed phones too: the solver refines GPS phones that share UWB distances.
        let fixes = locator.update(input)

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
                       basis: PositionBasis? = nil, fix: PhoneFix? = nil) -> TrackedPhone {
                TrackedPhone(id: id, label: label, isSelf: id == selfId, state: state, point: point, radius: radius,
                             basis: basis, ambiguous: fix?.ambiguous ?? false, ring: fix?.ring, hops: fix?.hops,
                             cloud: fix?.cloud ?? [], trail: trails[id] ?? [], since: since)
            }

            if fresh, source != .none {
                let reported = FloorPoint(x: report.position.x, z: report.position.z)
                let fix = fixes[id]
                // The solver moves a GPS phone when UWB distances say where it is relative to others,
                // and a typed or UWB-fix phone by at most its σ; draw that point so rings and links
                // around it line up with what the solver placed.
                if let fix, fix.basis == .gpsRefined {
                    lastSpot[id] = (fix.point, fix.r95, reportedAt)
                    appendTrail(id, fix.point)
                    result.append(phone(.placed(source), fix.point, radius: fix.r95, since: reportedAt, basis: .gpsRefined))
                } else if let fix {
                    lastSpot[id] = (fix.point, report.accuracyMeters ?? 0, reportedAt)
                    appendTrail(id, fix.point)
                    result.append(phone(.placed(source), fix.point, radius: report.accuracyMeters, since: reportedAt,
                                        basis: .reported(source)))
                } else {
                    lastSpot[id] = (reported, report.accuracyMeters ?? 0, reportedAt)
                    appendTrail(id, reported)
                    result.append(phone(.placed(source), reported, radius: report.accuracyMeters, since: reportedAt,
                                        basis: .reported(source)))
                }
            } else if fresh, let fix = fixes[id] {
                if fix.ambiguous, let ring = fix.ring {
                    // A ring's centre is the neighbour, not this phone: remember the whole ring as
                    // the last spot, and keep it out of the trail.
                    lastSpot[id] = (ring.center, max(ring.radius + 1, fix.r95), now)
                } else {
                    lastSpot[id] = (fix.point, fix.r95, now)
                    if !fix.ambiguous { appendTrail(id, fix.point) }
                }
                result.append(phone(.estimated, fix.point, radius: fix.r95, since: now, basis: fix.basis, fix: fix))
            } else if let last = lastSpot[id], now.timeIntervalSince(last.at) <= Self.rememberFor {
                let grown = last.radius + Self.walkingSpeed * now.timeIntervalSince(last.at)
                result.append(phone(.lastSeen, last.point, radius: grown, since: last.at))
            } else if fresh {
                result.append(phone(.unplaced, nil, radius: nil, since: reportedAt))
            }
        }
        lastSpot = lastSpot.filter { now.timeIntervalSince($0.value.at) <= Self.rememberFor }
        phones = result.sorted { ($0.isSelf ? 0 : 1, $0.label) < ($1.isSelf ? 0 : 1, $1.label) }
        let radio = locator.radio
        links = input.measurements.map { m in
            TrackedLink(a: m.a, b: m.b, rssi: m.rssi, rssiDistance: m.rssi.map { radio.distance(forRSSI: $0) },
                        uwbDistance: m.uwbDistance, bearing: m.bearing)
        }
    }

    private func appendTrail(_ id: String, _ point: FloorPoint) {
        var trail = trails[id] ?? []
        trail.append(point)
        if trail.count > Self.trailLength { trail.removeFirst(trail.count - Self.trailLength) }
        trails[id] = trail
    }
}
