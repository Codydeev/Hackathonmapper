import Combine
import Foundation
import MeshCore

/// One phone as the Track tab and the map show it, in the shared frame (meters on the floor plane).
struct TrackedPhone: Identifiable {
    enum State: Equatable {
        /// Reports its own position (GPS, UWB, fused or a typed spot).
        case placed(PositionSource)
        /// Has no position of its own; placed from the signal map this second.
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
    /// Where world views draw it. Distances between linked phones are the measured Bluetooth ones.
    let point: FloorPoint?
    /// 95 % radius: reported accuracy, the signal map's estimate, or the grown circle when last seen.
    let radius: Double?
    /// Only the distance is known: the phone is somewhere on `ring`, not necessarily at `point`.
    let ambiguous: Bool
    let ring: (center: FloorPoint, radius: Double)?
    let hops: Int?
    let cloud: [FloorPoint]
    let trail: [FloorPoint]
    /// When the shown point was last confirmed.
    let since: Date
    /// The position it reported, when `point` was moved to agree with its Bluetooth ranges.
    let reported: FloorPoint?
    /// This phone in the signal map (layout coordinates); nil while its report is stale.
    let signal: SignalNode?
}

/// A Bluetooth link with a fresh RSSI, as fed to the signal map.
struct TrackedLink: Identifiable {
    let a: String
    let b: String
    let rssi: Double
    /// UWB distance one or both ends measured, m; nil for an RSSI-only link.
    let uwb: Double?
    /// The UWB distance when there is one, else the range from RSSI, m.
    let measured: Double
    /// One-sigma error of `measured`, m.
    let sigma: Double
    /// Distance on the signal map, m; equal to `measured` when the map fits.
    let layout: Double
    var id: String { a + "\n" + b }
}

/// Runs the signal map on this phone, once a second, over the reports the mesh already delivers
/// (every phone's position source and its neighbours' RSSI and UWB distances). It is the same solver
/// the dashboard and the main map run (MeshCore `SignalMap`, website/shared/signalmap.ts), so they
/// agree, and a phone needs no network to see where a phone without GPS is. This tracker's phones also
/// seed `MovementPredictor`'s likely paths (`MeshModel.tick`).
@MainActor
final class BluetoothTracker: ObservableObject {
    /// Matches the dashboard's stale limit.
    static let reportMaxAge: TimeInterval = 15
    /// How long a phone that went out of reach stays on screen.
    static let rememberFor: TimeInterval = 600
    /// m/s a phone out of reach may have walked since its last spot.
    static let walkingSpeed = 1.4
    static let trailLength = 120
    /// A drawn position this far from the report counts as moved (matches the dashboard), m.
    static let movedReport = 0.5

    /// The shared radio model, calibrated from links between precisely placed phones when there are any.
    @Published private(set) var radio = RadioModel.standard
    @Published private(set) var phones: [TrackedPhone] = []
    @Published private(set) var links: [TrackedLink] = []
    /// Which distances the Track tab uses, to compare them: a test setting, back to both after every
    /// launch (the tracker also seeds the main map's likely paths). Changing it starts the layout afresh.
    @Published var rangeSource = SignalRanges.all {
        didSet { if rangeSource != oldValue { layout = [:] } }
    }
    /// Fit the radio model live (Features → Calibrate radio model); off keeps the default.
    var calibrate = true

    private var layout: [String: FloorPoint] = [:]
    private var lastSpot: [String: (point: FloorPoint, radius: Double, at: Date)] = [:]
    private var trails: [String: [FloorPoint]] = [:]
    private var sources: [String: PositionSource] = [:]

    var me: TrackedPhone? { phones.first { $0.isSelf } }

    func reset() {
        radio = RadioModel.standard
        layout = [:]
        lastSpot = [:]
        trails = [:]
        sources = [:]
        phones = []
        links = []
    }

    func update(reports: [DeviceUpdate], receivedAt: [String: Date], selfId: String, now: Date = Date()) {
        let fresh = reports.filter { receivedAt[$0.id].map { now.timeIntervalSince($0) <= Self.reportMaxAge } ?? false }
        let freshIds = Set(fresh.map(\.id))
        let byId = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        // A fused phone's position already uses its RSSI to placed anchor phones (FusionEngine); using
        // those links again here would count the same evidence twice. A UWB distance it did not use,
        // nor an anchor reporting no position (MeshModel.isPlacedAnchor). Mirrors server/store.ts.
        func placedAnchor(_ report: DeviceUpdate) -> Bool {
            report.role == "anchor" && report.positionSource != PositionSource.none
        }
        func usedByFusion(_ a: DeviceUpdate, _ b: DeviceUpdate) -> Bool {
            (a.positionSource == .fused && placedAnchor(b)) || (b.positionSource == .fused && placedAnchor(a))
        }
        var signalLinks: [SignalLink] = []
        for report in fresh {
            let reportAge = now.timeIntervalSince(receivedAt[report.id] ?? now)
            for neighbor in report.neighbors ?? [] {
                let uwb = rangeSource == .bluetoothOnly ? nil : neighbor.uwbDistanceM
                if rangeSource == .uwbOnly, uwb == nil { continue }
                guard let rssi = neighbor.rssi, let other = byId[neighbor.id],
                      uwb != nil || !usedByFusion(report, other),
                      reportAge + Double(neighbor.ageMs ?? 0) / 1000 <= SignalMap.linkMaxAge else { continue }
                // Each end's report is a link; the solver averages the two and prefers a UWB distance.
                signalLinks.append(SignalLink(a: report.id, b: neighbor.id, rssi: Double(rssi), uwb: uwb))
            }
        }
        let priors = fresh.compactMap { report -> SignalPrior? in
            // A missing source comes from an older build and means manual.
            guard report.positionSource != PositionSource.none else { return nil }
            return SignalPrior(id: report.id, x: report.position.x, z: report.position.z, r95: report.accuracyMeters)
        }
        let result = SignalMap.solve(ids: fresh.map(\.id), links: signalLinks, priors: priors,
                                     radio: RadioModel.standard, previous: layout, calibrate: calibrate)
        layout = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.id, FloorPoint(x: $0.x, z: $0.z)) })
        radio = result.radio
        let nodes = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.id, $0) })

        var phones: [TrackedPhone] = []
        for report in reports {
            let id = report.id
            let source = report.positionSource ?? .manual
            // A placeholder and a real position are different tracks.
            if sources[id] != source { trails[id] = [] }
            sources[id] = source
            let reportedAt = receivedAt[id] ?? .distantPast
            let isFresh = freshIds.contains(id)
            let label = report.label ?? shortID(id)
            let node = isFresh ? nodes[id] : nil
            let placement = node.flatMap { SignalMap.placeInWorld($0, nodes: nodes) }

            func phone(_ state: TrackedPhone.State, _ point: FloorPoint?, radius: Double?, since: Date,
                       placement: WorldPlacement? = nil, reported: FloorPoint? = nil) -> TrackedPhone {
                let ring = placement.flatMap { p -> (center: FloorPoint, radius: Double)? in
                    guard p.ambiguous, let x = p.ringX, let z = p.ringZ, let r = p.ringRadius else { return nil }
                    return (FloorPoint(x: x, z: z), r)
                }
                return TrackedPhone(id: id, label: label, isSelf: id == selfId, state: state, point: point, radius: radius,
                                    ambiguous: placement?.ambiguous ?? false, ring: ring, hops: node?.hops,
                                    cloud: placement.map { SignalMap.ringPoints($0) } ?? [], trail: trails[id] ?? [],
                                    since: since, reported: reported, signal: node)
            }

            if isFresh, source != .none {
                let own = FloorPoint(x: report.position.x, z: report.position.z)
                if let placement, (node?.degree ?? 0) > 0 {
                    // Linked: drawn where the signal map puts it, so its Bluetooth distances hold.
                    let point = FloorPoint(x: placement.x, z: placement.z)
                    let moved = hypot(point.x - own.x, point.z - own.z) > Self.movedReport
                    lastSpot[id] = (point, placement.r95, reportedAt)
                    appendTrail(id, point)
                    phones.append(phone(.placed(source), point, radius: placement.r95, since: reportedAt,
                                        placement: placement, reported: moved ? own : nil))
                } else {
                    lastSpot[id] = (own, report.accuracyMeters ?? 0, reportedAt)
                    appendTrail(id, own)
                    phones.append(phone(.placed(source), own, radius: report.accuracyMeters, since: reportedAt))
                }
            } else if isFresh, let placement {
                let point = FloorPoint(x: placement.x, z: placement.z)
                lastSpot[id] = (point, placement.r95, now)
                appendTrail(id, point)
                phones.append(phone(.estimated, point, radius: placement.r95, since: now, placement: placement))
            } else if let last = lastSpot[id], now.timeIntervalSince(last.at) <= Self.rememberFor {
                let grown = last.radius + Self.walkingSpeed * now.timeIntervalSince(last.at)
                phones.append(phone(.lastSeen, last.point, radius: grown, since: last.at))
            } else if isFresh {
                phones.append(phone(.unplaced, nil, radius: nil, since: reportedAt))
            }
        }
        lastSpot = lastSpot.filter { now.timeIntervalSince($0.value.at) <= Self.rememberFor }
        self.phones = phones.sorted { ($0.isSelf ? 0 : 1, $0.label) < ($1.isSelf ? 0 : 1, $1.label) }
        links = result.links.map {
            TrackedLink(a: $0.a, b: $0.b, rssi: $0.rssi, uwb: $0.uwb, measured: $0.measured, sigma: $0.sigma, layout: $0.layout)
        }
    }

    /// The measured Bluetooth link between two phones, if they hear each other directly.
    func link(between a: String, and b: String) -> TrackedLink? {
        let (first, second) = a < b ? (a, b) : (b, a)
        return links.first { $0.a == first && $0.b == second }
    }

    private func appendTrail(_ id: String, _ point: FloorPoint) {
        var trail = trails[id] ?? []
        trail.append(point)
        if trail.count > Self.trailLength { trail.removeFirst(trail.count - Self.trailLength) }
        trails[id] = trail
    }
}
