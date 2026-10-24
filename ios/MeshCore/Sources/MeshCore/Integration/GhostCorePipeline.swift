import Foundation

// MARK: - Engine slots

/// Judges this phone's own GNSS (gnss trust agent: GNSSIntegrityMonitor).
public protocol GhostIntegrityEngine: AnyObject {
    /// The latest raw fix, after scenario faults; judged at the next `assess`.
    func ingest(fix: PositionEstimate)
    func ingest(motion: MotionObservation)
    /// `evidence`: current estimates of this phone from other sources (Bluetooth, typed spots).
    func assess(subjectId: String, evidence: [PositionEstimate], now: Double) -> IntegrityAssessment
}

/// Places phones that have no trusted position of their own (positioning agent).
public protocol GhostPositioningEngine: AnyObject {
    /// `anchors`: positions that may anchor others. `lost`: phones to place. `links`: averaged RSSI per
    /// phone pair from the mesh reports. Returns estimates for the lost phones it could place.
    func place(anchors: [PositionEstimate], lost: [String], links: [LinkMeasurement],
               observations: [PeerObservation], now: Double) -> [PositionEstimate]
}

/// Predicts where a phone went after it was last observed (prediction agent).
public protocol GhostPredictionEngine: AnyObject {
    func observe(_ estimate: PositionEstimate, receivedAt: Double)
    func observe(_ motion: MotionObservation)
    /// Nil while the subject is observed live, or once it is lost beyond the horizon.
    func predict(subjectId: String, at now: Double) -> Prediction?
}

// MARK: - Baselines (today's code)

/// The on-phone Bluetooth particle filter that build 7 runs (BluetoothEstimator).
public final class EstimatorPositioning: GhostPositioningEngine {
    private let producerId: String
    private let frameId: String
    private var estimator: BluetoothEstimator

    public init(producerId: String, frameId: String, options: BluetoothEstimator.Options = .init()) {
        self.producerId = producerId
        self.frameId = frameId
        estimator = BluetoothEstimator(options: options)
    }

    public func place(anchors: [PositionEstimate], lost: [String], links: [LinkMeasurement],
                      observations: [PeerObservation], now: Double) -> [PositionEstimate] {
        guard !lost.isEmpty else { return [] }
        let usable = anchors.filter { $0.position != nil }
        let estimates = estimator.update(
            anchors: usable.map { a in
                EstimatorAnchor(id: a.subjectId, x: a.position!.x, z: a.position!.z,
                                // The estimator expects a ~68 % radius, like iOS horizontalAccuracy.
                                accuracy: a.uncertainty.r95 / PositionUncertainty.r95(fromRadius68: 1))
            },
            lost: lost, measurements: links)
        let lastAbsolute = usable.map(\.timestamp).max()
        let inputs = usable.prefix(GhostCoreContract.maxInputs - 1).map {
            ProvenanceInput(source: $0.source, id: $0.subjectId, used: true, reason: "anchor")
        } + [ProvenanceInput(source: .bluetooth, used: true, reason: "\(links.count) link RSSI")]
        let provenance = Provenance.derived(producerId: producerId, algorithm: "bluetooth-estimator@1", inputs: inputs,
                                            from: usable.map(\.provenance))
        return lost.compactMap { id in
            guard let e = estimates[id], e.hops != nil else { return nil }
            return PositionEstimate(subjectId: id, timestamp: now, frameId: frameId, kind: .estimated, method: .particle,
                                    position: Position(x: e.x, y: 0, z: e.z),
                                    uncertainty: PositionUncertainty(r95: min(e.r95, GhostCoreContract.maxRadius),
                                                                     ambiguous: e.ambiguous),
                                    lastAbsoluteAt: lastAbsolute, source: .bluetooth,
                                    freshness: Freshness(maxAge: 6), provenance: provenance)
        }
    }
}

/// Build 7's "last seen" rule as a prediction: the last spot, with a circle growing at walking pace.
public final class WalkingCirclePrediction: GhostPredictionEngine {
    public static let walkingSpeed = 1.4
    /// An observation newer than this is live: no prediction.
    public static let liveFor = 5.0
    public static let horizon = 600.0

    private let producerId: String
    private var last: [String: (estimate: PositionEstimate, at: Double)] = [:]

    public init(producerId: String) {
        self.producerId = producerId
    }

    public func observe(_ estimate: PositionEstimate, receivedAt: Double) {
        guard estimate.kind != .predicted, estimate.kind != .unavailable, estimate.position != nil else { return }
        let observedAt = receivedAt - estimate.freshness.ageAtHandoff
        if let previous = last[estimate.subjectId], previous.at > observedAt { return }
        last[estimate.subjectId] = (estimate, observedAt)
    }

    public func observe(_ motion: MotionObservation) {}

    public func predict(subjectId: String, at now: Double) -> Prediction? {
        guard let (estimate, at) = last[subjectId], let position = estimate.position else { return nil }
        let age = now - at
        guard age > Self.liveFor, age <= Self.horizon else { return nil }
        let r95 = min(estimate.uncertainty.r95 + Self.walkingSpeed * age, GhostCoreContract.maxRadius)
        return Prediction(subjectId: subjectId, timestamp: now, frameId: estimate.frameId, method: .stationary,
                          lastObservedAt: at, lastObservedPosition: position, center: position,
                          uncertainty: PositionUncertainty(r95: r95), freshness: Freshness(maxAge: 10),
                          provenance: .derived(producerId: producerId, algorithm: "walking-circle@1",
                                               inputs: [ProvenanceInput(source: estimate.source, id: subjectId,
                                                                        age: age, used: true, reason: "last observed")],
                                               from: [estimate.provenance]))
    }
}

// MARK: - Pipeline

/// Runs the GhostCore engines once a second on one phone and decides what is shown and published
/// (ARCHITECTURE.md §6). Pure and deterministic: the app's GhostCoreHub, the headless scenario world
/// and the tests all drive this same code.
public final class GhostCorePipeline {
    public struct Configuration {
        public var selfId: String
        public var frameId: String
        /// A mesh report older than this is not used (matches the dashboard's stale limit).
        public var reportMaxAge = 15.0
        /// Bluetooth links reported longer ago than this are not used to place phones.
        public var linkMaxAge = 6.0
        /// A GNSS fix older than this is not used (a still phone gets few fixes).
        public var gnssMaxAge = 30.0
        /// Fixes claiming worse than this 68 % accuracy are not used.
        public var gnssMaxAccuracy68 = 30.0

        public init(selfId: String, frameId: String) {
            self.selfId = selfId
            self.frameId = frameId
        }
    }

    /// One phone as this phone sees it.
    public struct Phone: Equatable {
        public let id: String
        public let label: String?
        public let isSelf: Bool
        /// The one position to show (selection order in ARCHITECTURE.md §6), or nil.
        public let selected: PositionEstimate?
        /// Local time the selected record was received or produced.
        public let selectedReceivedAt: Double?
        /// GNSS that is shown but not trusted: integrity says insufficientEvidence or degraded.
        public let gnssUnconfirmed: Bool
        /// This phone's own raw GNSS fix after faults, even when rejected (self only).
        public let rawFix: PositionEstimate?
        /// This phone's own assessment, or a peer's as relayed over the mesh.
        public let integrity: IntegrityAssessment?
        /// Local time the assessment was made or received.
        public let integrityReceivedAt: Double?
        public let estimate: PositionEstimate?
        public let prediction: Prediction?
        /// Relays the subject's latest report came through, oldest first.
        public let route: [String]
    }

    /// What this phone should publish in its next mesh report.
    public struct Publication: Equatable {
        public let position: Position
        public let accuracyMeters: Double?
        public let source: PositionSource

        public init(position: Position, accuracyMeters: Double?, source: PositionSource) {
            self.position = position
            self.accuracyMeters = accuracyMeters
            self.source = source
        }
    }

    public struct Output {
        public let phones: [Phone]
        public let publication: Publication
        public let links: [LinkMeasurement]
        public let integrityEngineActive: Bool
        /// Records this phone should send over the mesh: its own integrity assessment.
        public let records: [RelayMessage.Payload]
    }

    public let configuration: Configuration
    public var integrity: GhostIntegrityEngine?
    public var positioning: GhostPositioningEngine
    public var prediction: GhostPredictionEngine
    public private(set) var faults = GNSSFaults()
    /// A typed spot for this phone (Position tab / Pin me), published as declared.
    public var declared: (position: Position, accuracyMeters: Double?)?

    private var selfId: String { configuration.selfId }
    private var fix: (estimate: PositionEstimate, receivedAt: Double)?
    private var observations: [PeerObservation] = []
    private var reports: [String: (update: DeviceUpdate, receivedAt: Double, path: [String])] = [:]
    private var lastAssessment: IntegrityAssessment?
    private var peerIntegrity: [String: (assessment: IntegrityAssessment, receivedAt: Double)] = [:]
    private var ownEstimate: PositionEstimate?
    /// This phone's estimate from the positioning engine (dead reckoning, fusion, ranging), if fresh.
    private var positioned: (estimate: PositionEstimate, receivedAt: Double)?

    public init(configuration: Configuration, integrity: GhostIntegrityEngine? = nil,
                positioning: GhostPositioningEngine? = nil, prediction: GhostPredictionEngine? = nil) {
        self.configuration = configuration
        self.integrity = integrity
        self.positioning = positioning ?? EstimatorPositioning(producerId: configuration.selfId,
                                                               frameId: configuration.frameId)
        self.prediction = prediction ?? WalkingCirclePrediction(producerId: configuration.selfId)
    }

    // MARK: Inputs

    /// A raw GNSS fix of this phone, before faults.
    public func ingest(fix raw: PositionEstimate, receivedAt: Double) {
        guard raw.subjectId == selfId, let faulted = faults.apply(to: raw) else { return }
        fix = (faulted, receivedAt)
        integrity?.ingest(fix: faulted)
    }

    public func ingest(motion record: MotionObservation) {
        guard record.subjectId == selfId else { return }
        integrity?.ingest(motion: record)
        prediction.observe(record)
    }

    /// This phone's own estimate from the positioning engine. Only inferred kinds are used; it replaces
    /// the Bluetooth estimator's guess for this phone while it is fresh.
    public func ingest(ownEstimate estimate: PositionEstimate, receivedAt: Double) {
        guard estimate.subjectId == selfId, estimate.kind == .estimated, (try? estimate.validate()) != nil else { return }
        positioned = (estimate, receivedAt)
    }

    /// The latest Bluetooth snapshots this phone made of its peers.
    public func ingest(observations records: [PeerObservation]) {
        observations = records.filter { $0.observerId == selfId }
    }

    /// A mesh report, this phone's own included. Older sequences of the same epoch are ignored.
    public func ingest(report: DeviceUpdate, receivedAt: Double, path: [String] = []) {
        if let known = reports[report.id], known.update.epochId == report.epochId,
           known.update.sequence >= report.sequence { return }
        reports[report.id] = (report, receivedAt, path)
    }

    /// A contract record relayed from another phone. Its age is `freshness.ageAtHandoff` plus the
    /// local time since `receivedAt`. Peers' integrity assessments are kept per subject.
    public func ingest(record message: RelayMessage, receivedAt: Double) {
        guard message.originId != selfId, message.frameId == configuration.frameId,
              (try? message.validate()) != nil else { return }
        if case .integrity(let assessment) = message.payload, assessment.subjectId == message.originId {
            let known = peerIntegrity[assessment.subjectId]
            if let known, known.assessment.timestamp >= assessment.timestamp { return }
            // Store with the receipt time moved back by the age it already had, so age() stays one clock.
            peerIntegrity[assessment.subjectId] = (assessment, receivedAt - message.freshness.ageAtHandoff)
        }
    }

    /// A scenario input. GNSS faults only act on this phone; link inputs are the transport's job.
    public func apply(_ input: ScenarioInput, at t: Double) {
        guard input.subjectId == selfId else { return }
        faults.apply(input, at: t)
        // A simulated outage means "GPS gone now", like the app's toggle; a real one ages out (gnssMaxAge).
        if faults.outage { fix = nil }
    }

    public func forget(_ id: String) {
        reports[id] = nil
    }

    // MARK: Step

    public func step(now: Double) -> Output {
        let frameId = configuration.frameId

        // 1. Own GNSS and its integrity.
        var usableFix: PositionEstimate?
        if let fix, now - fix.estimate.timestamp <= configuration.gnssMaxAge,
           fix.estimate.uncertainty.r95 <= PositionUncertainty.r95(fromRadius68: configuration.gnssMaxAccuracy68) {
            usableFix = fix.estimate
        }
        if let integrity {
            let evidence = ownEstimate.map { [$0] } ?? []
            lastAssessment = integrity.assess(subjectId: selfId, evidence: evidence, now: now)
        } else {
            lastAssessment = nil
        }
        let status = lastAssessment?.status
        // Without an integrity engine the phone behaves like build 7 and shares its GPS, labelled unchecked.
        let gnssTrusted = usableFix != nil && (integrity == nil || status == .trusted)
        let gnssUnconfirmed = usableFix != nil && integrity != nil && [.insufficientEvidence, .degraded].contains(status)

        // 2. What this phone publishes: only trusted GNSS anchors others.
        let publication: Publication
        if let declared {
            publication = Publication(position: declared.position, accuracyMeters: declared.accuracyMeters, source: .manual)
        } else if gnssTrusted, let usableFix, let position = usableFix.position {
            publication = Publication(position: position,
                                      accuracyMeters: min(usableFix.uncertainty.r95 / PositionUncertainty.r95(fromRadius68: 1),
                                                          DashboardContract.maxAccuracyMeters),
                                      source: .gps)
        } else {
            publication = Publication(position: Position(x: 0, y: 0, z: 0), accuracyMeters: nil, source: .none)
        }

        // 3. Anchors, lost phones and links from the fresh mesh reports.
        let fresh = reports.values.filter { now - $0.receivedAt <= configuration.reportMaxAge }.map(\.update)
        let input = BluetoothEstimator.input(
            reports: fresh,
            receivedAt: reports.mapValues { Date(timeIntervalSince1970: $0.receivedAt) },
            now: Date(timeIntervalSince1970: now), reportMaxAge: configuration.reportMaxAge,
            linkMaxAge: configuration.linkMaxAge)
        var reported: [String: PositionEstimate] = [:]
        for update in fresh {
            if let estimate = Self.estimate(from: update, frameId: frameId, at: reports[update.id]?.receivedAt ?? now) {
                reported[update.id] = estimate
            }
        }
        let anchors = input.anchors.compactMap { reported[$0.id] }
        let placed = positioning.place(anchors: anchors, lost: input.lost, links: input.measurements,
                                       observations: observations, now: now)
        var estimates: [String: PositionEstimate] = [:]
        for estimate in placed where (try? estimate.validate()) != nil { estimates[estimate.subjectId] = estimate }
        if let positioned, !positioned.estimate.isStale(receivedAt: positioned.receivedAt, now: now) {
            estimates[selfId] = positioned.estimate
        }
        ownEstimate = estimates[selfId]

        // 4. Prediction engine observes everything live; predictions for the rest.
        var ids = Set(reports.keys)
        ids.insert(selfId)
        peerIntegrity = peerIntegrity.filter { now - $0.value.receivedAt <= configuration.reportMaxAge * 4 }
        for id in ids {
            if let r = reported[id], let at = reports[id]?.receivedAt { prediction.observe(r, receivedAt: at) }
            if let e = estimates[id] { prediction.observe(e, receivedAt: now) }
        }
        if let usableFix, gnssTrusted || gnssUnconfirmed { prediction.observe(usableFix, receivedAt: fix?.receivedAt ?? now) }

        // 5. Selection, per phone.
        var phones: [Phone] = []
        for id in ids.sorted() {
            let isSelf = id == selfId
            let report = reports[id]
            var candidates: [(PositionEstimate, Double)] = []
            if isSelf {
                if let declared, declared.position.x.isFinite {
                    candidates.append((Self.declaredEstimate(selfId, declared, frameId: frameId, now: now), now))
                }
                if gnssTrusted, let usableFix { candidates.append((usableFix, fix?.receivedAt ?? now)) }
            } else if let r = reported[id], let at = report?.receivedAt {
                candidates.append((r, at))
            }
            if let e = estimates[id] { candidates.append((e, now)) }
            if isSelf, gnssUnconfirmed, let usableFix { candidates.append((usableFix, fix?.receivedAt ?? now)) }
            let predicted = candidates.isEmpty ? prediction.predict(subjectId: id, at: now) : nil
            if let predicted { candidates.append((predicted.asPositionEstimate, now)) }
            let selected = candidates.first
            guard selected != nil || isSelf || report.map({ now - $0.receivedAt <= configuration.reportMaxAge }) == true
            else { continue }
            var integrity: (assessment: IntegrityAssessment, receivedAt: Double)?
            if isSelf {
                integrity = lastAssessment.map { ($0, now) }
            } else if let peer = peerIntegrity[id],
                      !Freshness(maxAge: peer.assessment.freshness.maxAge).isStale(receivedAt: peer.receivedAt, now: now) {
                integrity = peer
            }
            phones.append(Phone(id: id, label: report?.update.label, isSelf: isSelf, selected: selected?.0,
                                selectedReceivedAt: selected?.1,
                                gnssUnconfirmed: isSelf && gnssUnconfirmed && selected?.0.method == .gnss,
                                rawFix: isSelf ? fix?.estimate : nil, integrity: integrity?.assessment,
                                integrityReceivedAt: integrity?.receivedAt,
                                estimate: estimates[id], prediction: predicted, route: report?.path ?? []))
        }
        return Output(phones: phones, publication: publication, links: input.measurements,
                      integrityEngineActive: integrity != nil,
                      records: lastAssessment.map { [.integrity($0)] } ?? [])
    }

    // MARK: Mapping

    /// A peer's mesh report as a contract record. Reports carry no age, so freshness starts at receipt.
    static func estimate(from update: DeviceUpdate, frameId: String, at receivedAt: Double) -> PositionEstimate? {
        let source = update.positionSource ?? .manual
        let accuracy = update.accuracyMeters.map(PositionUncertainty.r95(fromRadius68:)) ?? 10
        let floor = update.positionMode == "floor"
        let position = Position(x: update.position.x, y: floor ? 0 : update.position.y, z: update.position.z)
        switch source {
        case .gps:
            return PositionEstimate(subjectId: update.id, timestamp: receivedAt, frameId: frameId, kind: .measured,
                                    method: .gnss, position: position, positionMode: floor ? .floor : .threeD,
                                    uncertainty: PositionUncertainty(r95: min(accuracy, GhostCoreContract.maxRadius)),
                                    lastAbsoluteAt: receivedAt, source: .gnss, freshness: Freshness(maxAge: 15),
                                    provenance: Provenance(producerId: update.id, algorithm: "mesh-report@1",
                                                           gnssDependent: true))
        case .manual:
            return PositionEstimate(subjectId: update.id, timestamp: receivedAt, frameId: frameId, kind: .declared,
                                    method: .manual, position: position, positionMode: floor ? .floor : .threeD,
                                    uncertainty: PositionUncertainty(r95: min(accuracy, GhostCoreContract.maxRadius)),
                                    lastAbsoluteAt: receivedAt, source: .manual, freshness: Freshness(maxAge: 15),
                                    provenance: Provenance(producerId: update.id, algorithm: "mesh-report@1",
                                                           gnssDependent: false))
        case .none:
            return nil
        }
    }

    static func declaredEstimate(_ id: String, _ declared: (position: Position, accuracyMeters: Double?),
                                 frameId: String, now: Double) -> PositionEstimate {
        let r95 = declared.accuracyMeters.map(PositionUncertainty.r95(fromRadius68:)) ?? 10
        return PositionEstimate(subjectId: id, timestamp: now, frameId: frameId, kind: .declared, method: .manual,
                                position: declared.position, positionMode: declared.position.y == 0 ? .floor : .threeD,
                                uncertainty: PositionUncertainty(r95: min(r95, GhostCoreContract.maxRadius)),
                                lastAbsoluteAt: now, source: .manual, freshness: Freshness(maxAge: 15),
                                provenance: Provenance(producerId: id, algorithm: "typed-spot@1", gnssDependent: false))
    }
}
