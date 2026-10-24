import Foundation

extension Positioning {
    /// This phone's two clocks: the engine runs on monotonic seconds, contract records carry Unix
    /// seconds on this phone's clock. Only ever used for this phone's own times.
    public struct Clock: Equatable {
        public let unixMinusMonotonic: Double

        public init(unixMinusMonotonic: Double) { self.unixMinusMonotonic = unixMinusMonotonic }

        public static func now(date: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Clock {
            Clock(unixMinusMonotonic: date.timeIntervalSince1970 - uptime)
        }

        public func unix(_ monotonic: TimeInterval) -> Double { monotonic + unixMinusMonotonic }
        public func monotonic(_ unix: Double) -> TimeInterval { unix - unixMinusMonotonic }
    }

    /// Maps engine values onto the GhostCore contract and relayed contract records onto engine inputs.
    public enum ContractMapping {
        public static let algorithm = "ghostcore-positioning@0.1"
        public static let positionMaxAge = 10.0
        public static let motionMaxAge = 5.0
        /// Relay latency not covered by `ageAtHandoff` (radio and queueing), s.
        public static let relayTimeSigma = 0.5

        // MARK: Engine -> contract

        /// `upstream`: provenance of the anchors behind `e` (their producer is the anchor). GNSS-based
        /// anchors in use are listed as `gnss` inputs with their ids, so circular evidence is visible.
        /// `producerId` defaults to the subject (a phone placing itself).
        public static func positionEstimate(_ e: Estimate, subjectId: String, clock: Clock,
                                            upstream: [Provenance] = [], simulated: Bool = false,
                                            producerId: String? = nil, maxAge: Double = positionMaxAge) -> PositionEstimate {
            let kind: PositionEstimate.Kind
            let method: PositionEstimate.Method
            let source: EvidenceSource
            var ambiguous = false
            switch e.method {
            case .gnss: (kind, method, source) = (.measured, .gnss, .gnss)
            case .deadReckoning: (kind, method, source) = (.estimated, .deadReckoning, .inertial)
            case .fused: (kind, method, source) = (.estimated, .fusion, .fusion)
            case .multilateration: (kind, method, source) = (.estimated, .multilateration, .bluetooth)
            case .proximity:
                (kind, method, source) = (.estimated, .proximity, .bluetooth)
                ambiguous = true
            case .ambiguous:
                (kind, method, source) = (.estimated, .proximity, .bluetooth)
                ambiguous = true
            case .declared: (kind, method, source) = (.declared, .manual, .manual)
            case .unavailable: (kind, method, source) = (.unavailable, .none, .fusion)
            }
            let point = kind == .unavailable ? nil : (e.position ?? e.regionCenter)
            let covariance = e.covariance.map { FloorCovariance(xx: $0.xx, xz: $0.xz, zz: $0.zz) }
            let r95 = min(GhostCoreContract.maxRadius, e.r95 ?? GhostCoreContract.maxRadius)
            let candidates = ambiguous && !e.candidates.isEmpty
                ? Array(e.candidates.prefix(GhostCoreContract.maxCandidates)).map { FloorVector(x: $0.x, z: $0.z) } : nil
            let gnssAnchors = e.anchorIds.filter { id in upstream.contains { $0.producerId == id && $0.gnssDependent } }.map {
                ProvenanceInput(source: .gnss, id: $0, used: true, reason: "anchor: its trusted GNSS position")
            }
            let evidenceInputs = e.provenance.map { c in
                ProvenanceInput(source: evidence(c.source), id: c.peerId.flatMap { DashboardContract.isValidId($0) ? $0 : nil },
                                age: max(0, e.t - c.t), used: c.used, reason: c.reason.map { String($0.prefix(GhostCoreContract.maxTextLength)) })
            }
            let inputs = Array((gnssAnchors + evidenceInputs).prefix(GhostCoreContract.maxInputs))
            let provenance = Provenance.derived(producerId: producerId ?? subjectId, algorithm: algorithm, inputs: inputs,
                                                from: upstream, usesGNSS: e.gnssDependent, simulated: simulated)
            return PositionEstimate(
                subjectId: subjectId, timestamp: clock.unix(e.t), frameId: e.frameId, kind: kind, method: method,
                position: point.map { Position(x: $0.x, y: 0, z: $0.z) }, positionMode: .floor,
                uncertainty: PositionUncertainty(r95: r95, ambiguous: ambiguous, covariance: point == nil ? nil : covariance),
                candidates: candidates, heading: e.heading, headingSigma: e.headingSigma,
                lastAbsoluteAt: e.lastAbsoluteAt.map { min(clock.unix($0), clock.unix(e.t)) },
                source: source, freshness: Freshness(ageAtHandoff: 0, maxAge: maxAge), provenance: provenance)
        }

        /// The interval's steps and dead-reckoned displacement; nil before any motion data.
        public static func motionObservation(_ m: MotionSummary, subjectId: String, frameId: String, clock: Clock,
                                             method: MotionObservation.Method = .stepDetector,
                                             simulated: Bool = false) -> MotionObservation {
            MotionObservation(
                subjectId: subjectId, timestamp: clock.unix(m.t), interval: m.window, frameId: frameId, method: method,
                steps: m.steps, displacement: m.stationary ? FloorVector(x: 0, z: 0) : FloorVector(x: m.displacement.x, z: m.displacement.z),
                heading: m.heading, stationary: m.stationary,
                uncertainty: .init(displacementR95: min(GhostCoreContract.maxRadius, m.displacementR95), headingSigma: m.headingSigma),
                source: .inertial, freshness: Freshness(ageAtHandoff: 0, maxAge: motionMaxAge),
                provenance: Provenance(producerId: subjectId, algorithm: algorithm, gnssDependent: false, simulated: simulated))
        }

        static func evidence(_ s: Contribution.Source) -> EvidenceSource {
            switch s {
            case .gnss, .gnssCourse: return .gnss
            case .compass, .steps, .stationary: return .inertial
            case .bleRange, .bleProximity, .bleMultilateration, .bleAmbiguous: return .bluetooth
            case .declared: return .manual
            }
        }

        // MARK: Contract -> engine

        public enum AnchorDecision: Equatable {
            case anchor(Anchor)
            case refused(String)
        }

        /// Whether another phone's relayed position may anchor this phone, and as what. A GNSS fix
        /// needs that phone's integrity check to say `mayAnchorOthers`; anything that already
        /// contains this phone is refused (no loops); regions and predictions never anchor.
        /// `receivedAt` is this phone's monotonic receipt time.
        public static func anchor(from p: PositionEstimate, integrity: IntegrityAssessment?, selfId: String,
                                  receivedAt: TimeInterval) -> AnchorDecision {
            guard p.subjectId != selfId else { return .refused("own estimate") }
            guard !p.provenance.contains(device: selfId) else { return .refused("depends on this phone") }
            guard let position = p.position, !p.uncertainty.ambiguous else { return .refused("no single position") }
            guard p.freshness.ageAtHandoff <= p.freshness.maxAge else { return .refused("stale") }
            let sigma = p.uncertainty.covariance.map { $0.largestVariance.squareRoot() }
                ?? p.uncertainty.r95 / PositionUncertainty.sigmaTo95
            let measuredAt = receivedAt - p.freshness.ageAtHandoff
            let speed = p.velocity.map { $0.length + 0.5 } ?? 1.5
            let point = Vec2(x: position.x, z: position.z)
            switch (p.kind, p.method) {
            case (.measured, .gnss):
                guard let integrity, integrity.subjectId == p.subjectId else { return .refused("no integrity assessment") }
                guard integrity.mayAnchorOthers else { return .refused("GNSS not trusted: \(integrity.status.rawValue)") }
                return .anchor(Anchor(id: p.subjectId, position: point, sigma: sigma, kind: .gnss, measuredAt: measuredAt,
                                      timeSigma: relayTimeSigma, speedBound: speed, dependsOn: p.provenance.contributors,
                                      gnssDependent: true))
            case (.measured, _), (.declared, _):
                return .anchor(Anchor(id: p.subjectId, position: point, sigma: sigma, kind: .surveyed, measuredAt: measuredAt,
                                      timeSigma: relayTimeSigma, speedBound: p.kind == .declared ? 0.3 : speed,
                                      dependsOn: p.provenance.contributors, gnssDependent: p.provenance.gnssDependent))
            case (.estimated, .fusion), (.estimated, .multilateration), (.estimated, .deadReckoning), (.estimated, .particle):
                return .anchor(Anchor(id: p.subjectId, position: point, sigma: sigma, kind: .estimated, measuredAt: measuredAt,
                                      timeSigma: relayTimeSigma, speedBound: speed, dependsOn: p.provenance.contributors,
                                      gnssDependent: p.provenance.gnssDependent))
            default:
                return .refused("\(p.kind.rawValue) \(p.method.rawValue) cannot anchor")
            }
        }

        /// Raw RSSI from a snapshot, for the engine's median filter: our own readings of a peer, or a
        /// peer's readings of us (`reciprocal`). Samples are spread evenly over the snapshot window.
        /// Our own snapshots are timed by `clock`; a peer's by receipt time minus its age.
        public static func rssiSamples(from o: PeerObservation, selfId: String, receivedAt: TimeInterval,
                                       clock: Clock) -> [RSSISample] {
            let peer: String
            let channel: RSSIChannel
            let newest: TimeInterval
            if o.observerId == selfId, let id = o.peerId {
                peer = id
                channel = o.channel == .connection ? .connection : .advertisement
                newest = clock.monotonic(o.timestamp)
            } else if o.peerId == selfId {
                peer = o.observerId
                channel = .reciprocal
                newest = receivedAt - o.freshness.ageAtHandoff
            } else {
                return []
            }
            let n = o.rawRSSI.count
            guard n > 0 else { return [] }
            let step = n > 1 ? o.window / Double(n - 1) : 0
            return o.rawRSSI.enumerated().map { i, rssi in
                RSSISample(peerId: peer, rssi: rssi, t: newest - Double(n - 1 - i) * step, channel: channel)
            }
        }
    }
}
