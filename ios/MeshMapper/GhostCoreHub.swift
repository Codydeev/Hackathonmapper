import CoreLocation
import Foundation
import MeshCore

/// One phone as the GhostCore map shows it. Times are Unix seconds on this phone's clock; a record's
/// age is `record.freshness.age(receivedAt: <its receivedAt>, now: Date().timeIntervalSince1970)`.
struct GhostPhone: Identifiable, Equatable {
    let id: String
    let label: String
    let isSelf: Bool
    /// The one position to show (ARCHITECTURE.md §6); its `kind` decides the label.
    let selected: PositionEstimate?
    let positionReceivedAt: Double?
    /// Shown GNSS that the integrity engine has not confirmed: label it "GPS (unchecked)".
    let gnssUnconfirmed: Bool
    /// This phone's raw GNSS fix after any scenario fault, even when rejected (self only).
    let rawFix: PositionEstimate?
    /// This phone's assessment, or a peer's as relayed; nil means GPS not checked.
    let integrity: IntegrityAssessment?
    let integrityReceivedAt: Double?
    let estimate: PositionEstimate?
    let prediction: Prediction?
    let predictionReceivedAt: Double?
    /// Phones the latest report came through, oldest first.
    let route: [String]
}

/// A Bluetooth link with a fresh RSSI, from the phones' reports.
struct GhostLink: Identifiable, Equatable {
    let a: String
    let b: String
    let rssi: Double
    var id: String { a + "\n" + b }
}

/// The app side of GhostCore: feeds the pipeline (MeshCore GhostCorePipeline) once a second with this
/// phone's GPS, the mesh reports, Bluetooth observations and relayed records, and publishes what it
/// decides. Scenario inputs enter only through `inject` and `play`, and only as raw inputs.
@MainActor
final class GhostCoreHub: ObservableObject {
    struct Inputs {
        var reports: [DeviceUpdate]
        var receivedAt: [String: Date]
        var paths: [String: [String]]
        var location: CLLocation?
        var simulateGPSLoss: Bool
        /// The typed spot, when the phone's source is manual.
        var declared: (position: Position, accuracyMeters: Double?)?
        var observations: [PeerObservation]
        var records: [ReceivedRecord]
    }

    @Published private(set) var phones: [GhostPhone] = []
    @Published private(set) var links: [GhostLink] = []
    @Published private(set) var scenario: ScenarioState?
    @Published private(set) var integrityEngineActive = false
    /// A scenario fault or a forced link is active on this phone: show SIMULATED.
    @Published private(set) var simulationActive = false
    /// Scenarios bundled from contract/scenarios/ (S0–S6).
    let availableScenarios: [Scenario]
    /// What this phone should publish as its own report (GPS only when GhostCore lets it).
    private(set) var publication = GhostCorePipeline.Publication(position: Position(x: 0, y: 0, z: 0),
                                                                 accuracyMeters: nil, source: .none)
    /// Applies a forced link change to the transport (the relay's test link filter).
    var onPeerLink: ((_ peerId: String, _ up: Bool) -> Void)?

    var me: GhostPhone? { phones.first { $0.isSelf } }

    private var pipeline: GhostCorePipeline?
    /// The positioning agent's engine for this phone: motion for the integrity engine, and this
    /// phone's own dead-reckoned / fused estimate.
    private(set) var positioning: PositioningService?
    private var selfId = ""
    private var frameId = GeoFrame.defaultFrameId
    private var lastFixTime: Date?
    private var gpsLost = false
    private var forcedDown = Set<String>()
    private var player: (scenario: Scenario, role: String, roles: [String: String], start: Double, next: Int, caption: String?)?
    private var epochId = UUID().uuidString
    private var sequence = 0

    init() {
        availableScenarios = Self.bundledScenarios()
    }

    /// Starts over for this phone and frame (mesh start or frame change). `gpsCheck` runs the GNSS
    /// integrity engine: then only trusted GPS is published and anchors others. It needs motion, which
    /// PositioningService provides; without it no phone could ever be trusted (ARCHITECTURE.md §6).
    func reset(selfId: String, frameId: String, gpsCheck: Bool) {
        stop()
        positioning?.stop()
        self.selfId = selfId
        self.frameId = frameId
        let positioning = PositioningService(selfId: selfId, frameId: frameId)
        positioning.start()
        self.positioning = positioning
        pipeline = GhostCorePipeline(configuration: .init(selfId: selfId, frameId: frameId),
                                     integrity: gpsCheck ? GNSSIntegrityMonitor(subjectId: selfId, frameId: frameId) : nil,
                                     prediction: GhostPredictor(producerId: selfId, frameId: frameId))
        lastFixTime = nil
        gpsLost = false
        epochId = UUID().uuidString
        sequence = 0
        phones = []
        links = []
        integrityEngineActive = false
        simulationActive = false
    }

    /// One step. Returns the records this phone should send over the mesh.
    func step(_ inputs: Inputs, now: Date = Date()) -> [RelayMessage] {
        guard let pipeline else { return [] }
        let t = now.timeIntervalSince1970
        advancePlayer(at: t)

        if inputs.simulateGPSLoss != gpsLost {
            gpsLost = inputs.simulateGPSLoss
            pipeline.apply(.gnssOutage(subjectId: selfId, active: gpsLost), at: t)
        }
        feedPositioning(inputs, at: t)
        if !gpsLost, let location = inputs.location, location.timestamp != lastFixTime,
           let fix = fix(from: location) {
            lastFixTime = location.timestamp
            pipeline.ingest(fix: fix, receivedAt: t)
        }
        for update in inputs.reports {
            guard let at = inputs.receivedAt[update.id] else { continue }
            pipeline.ingest(report: update, receivedAt: at.timeIntervalSince1970, path: inputs.paths[update.id] ?? [])
        }
        pipeline.ingest(observations: inputs.observations)
        for record in inputs.records { pipeline.ingest(record: record.message, receivedAt: record.receivedAt) }
        pipeline.declared = inputs.declared

        let output = pipeline.step(now: t)
        publication = output.publication
        let labels = Dictionary(inputs.reports.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        phones = output.phones.map { p in
            GhostPhone(id: p.id, label: (labels[p.id] ?? nil) ?? p.label ?? String(p.id.prefix(6)), isSelf: p.isSelf,
                       selected: p.selected, positionReceivedAt: p.selectedReceivedAt, gnssUnconfirmed: p.gnssUnconfirmed,
                       rawFix: p.rawFix, integrity: p.integrity, integrityReceivedAt: p.integrityReceivedAt,
                       estimate: p.estimate, prediction: p.prediction, predictionReceivedAt: p.prediction == nil ? nil : t,
                       route: p.route)
        }
        links = output.links.map { GhostLink(a: $0.a, b: $0.b, rssi: $0.rssi) }
        integrityEngineActive = output.integrityEngineActive
        simulationActive = pipeline.faults.isActive || !forcedDown.isEmpty
        return output.records.compactMap { relayMessage($0, at: t) }
    }

    /// This phone's motion and own estimate from PositioningService, and its inputs: GPS (trusted only
    /// with this phone's trusted assessment and no scenario fault), Bluetooth snapshots, and peers'
    /// positions that may anchor (their relayed assessment says trusted).
    private func feedPositioning(_ inputs: Inputs, at t: Double) {
        guard let positioning, let pipeline else { return }
        positioning.gnssHidden = gpsLost || pipeline.faults.outage
        if let location = inputs.location, !positioning.gnssHidden {
            let trusted = me?.integrity?.mayAnchorOthers == true && !pipeline.faults.isActive
            positioning.ingest(location: location, trusted: trusted)
        }
        for observation in inputs.observations { positioning.ingest(observation: observation) }
        for phone in phones where !phone.isSelf {
            guard let selected = phone.selected, selected.kind == .measured, let integrity = phone.integrity else { continue }
            _ = positioning.ingest(relayed: selected, integrity: integrity)
        }
        let motion = positioning.motionObservation(window: 1)
        if (try? motion.validate()) != nil { pipeline.ingest(motion: motion) }
        let own = positioning.tick(simulated: pipeline.faults.isActive)
        pipeline.ingest(ownEstimate: own, receivedAt: t)
    }

    // MARK: Scenarios

    /// A raw input for this phone. GNSS faults act on this phone's own GPS; a link input forces this
    /// phone's link to `peerId` down or lets it up.
    func inject(_ input: ScenarioInput) {
        guard let pipeline else { return }
        let t = Date().timeIntervalSince1970
        switch input {
        case .peerLink(_, let peer, let up):
            if up { forcedDown.remove(peer) } else { forcedDown.insert(peer) }
            onPeerLink?(peer, up)
        default:
            pipeline.apply(Self.retarget(input, to: selfId), at: t)
        }
        simulationActive = pipeline.faults.isActive || !forcedDown.isEmpty
    }

    /// Plays `scenario` as the phone `role` (e.g. "phone-c"): only that phone's steps run here.
    /// `roles` maps the scenario's other phone IDs to device IDs, for link steps.
    func play(_ scenario: Scenario, as role: String, roles: [String: String] = [:]) {
        stop()
        player = (scenario, role, roles, Date().timeIntervalSince1970, 0, nil)
        self.scenario = ScenarioState(scenarioId: scenario.id, title: scenario.title, elapsed: 0, stepIndex: 0,
                                      caption: nil, isRunning: true)
    }

    /// Stops the scenario and removes every fault and forced link it left.
    func stop() {
        player = nil
        scenario = nil
        if let pipeline { pipeline.apply(.gnssClear(subjectId: selfId), at: Date().timeIntervalSince1970) }
        for peer in forcedDown { onPeerLink?(peer, true) }
        forcedDown.removeAll()
        simulationActive = false
    }

    private func advancePlayer(at t: Double) {
        guard var p = player else { return }
        let elapsed = t - p.start
        let steps = p.scenario.steps.sorted { $0.at < $1.at }
        while p.next < steps.count, steps[p.next].at <= elapsed {
            let step = steps[p.next]
            p.next += 1
            if let caption = step.caption { p.caption = caption }
            guard step.input.subjectId == p.role else { continue }
            if case .peerLink(_, let peerRole, let up) = step.input {
                guard let peer = p.roles[peerRole] else { continue }
                inject(.peerLink(subjectId: selfId, peerId: peer, up: up))
            } else {
                inject(step.input)
            }
        }
        let done = elapsed > p.scenario.duration
        player = done ? nil : p
        scenario = ScenarioState(scenarioId: p.scenario.id, title: p.scenario.title, elapsed: min(elapsed, p.scenario.duration),
                                 stepIndex: p.next, caption: p.caption, isRunning: !done)
    }

    private static func retarget(_ input: ScenarioInput, to id: String) -> ScenarioInput {
        switch input {
        case .gnssOutage(_, let active): return .gnssOutage(subjectId: id, active: active)
        case .gnssJump(_, let dx, let dz): return .gnssJump(subjectId: id, dx: dx, dz: dz)
        case .gnssDrift(_, let speed, let bearing): return .gnssDrift(subjectId: id, metersPerSecond: speed, bearingDegrees: bearing)
        case .gnssClear: return .gnssClear(subjectId: id)
        case .peerLink(_, let peer, let up): return .peerLink(subjectId: id, peerId: peer, up: up)
        }
    }

    private static func bundledScenarios() -> [Scenario] {
        (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.range(of: "^S[0-9]+\\.json$", options: .regularExpression) != nil }
            .compactMap { try? JSONDecoder().decode(Scenario.self, from: Data(contentsOf: $0)) }
            .sorted { $0.id < $1.id }
    }

    // MARK: Mapping

    /// A CoreLocation fix as a raw GNSS record in the shared frame.
    private func fix(from location: CLLocation) -> PositionEstimate? {
        guard location.horizontalAccuracy >= 0,
              let position = GeoFrame.position(frameId: frameId, latitude: location.coordinate.latitude,
                                               longitude: location.coordinate.longitude) else { return nil }
        var velocity: FloorVector?
        if location.speed >= 0, location.course >= 0 {
            let course = location.course * Double.pi / 180
            velocity = FloorVector(x: location.speed * sin(course), z: location.speed * cos(course))
        }
        let t = location.timestamp.timeIntervalSince1970
        let fix = PositionEstimate(
            subjectId: selfId, timestamp: t, frameId: frameId, kind: .measured, method: .gnss, position: position,
            uncertainty: PositionUncertainty(r95: min(PositionUncertainty.r95(fromRadius68: location.horizontalAccuracy),
                                                      GhostCoreContract.maxRadius)),
            velocity: velocity, lastAbsoluteAt: t, source: .gnss,
            freshness: Freshness(ageAtHandoff: max(0, Date().timeIntervalSince(location.timestamp)), maxAge: 30),
            provenance: Provenance(producerId: selfId, algorithm: "corelocation@1", gnssDependent: true))
        return (try? fix.validate()) == nil ? nil : fix
    }

    /// This phone's record wrapped for the mesh. An assessment too large for one record loses its
    /// evidence detail beyond the first four checks; the status and reasons always travel.
    private func relayMessage(_ payload: RelayMessage.Payload, at t: Double) -> RelayMessage? {
        guard case .integrity(let full) = payload else { return nil }
        let trimmed = IntegrityAssessment(
            subjectId: full.subjectId, timestamp: full.timestamp, frameId: full.frameId, status: full.status,
            trustScore: full.trustScore, uncertainty: full.uncertainty, reasons: full.reasons,
            evidence: Array(full.evidence.prefix(4)), evaluatedFix: full.evaluatedFix,
            minimumDetectableOffsetMeters: full.minimumDetectableOffsetMeters, summary: full.summary, source: full.source,
            freshness: full.freshness, provenance: full.provenance)
        for candidate in [full, trimmed] {
            sequence += 1
            let message = RelayMessage(originId: selfId, epochId: epochId, sequence: sequence, timestamp: t, frameId: frameId,
                                       hopsRemaining: 4, freshness: candidate.freshness, payload: .integrity(candidate))
            if (try? message.encoded()) != nil { return message }
        }
        return nil
    }
}
