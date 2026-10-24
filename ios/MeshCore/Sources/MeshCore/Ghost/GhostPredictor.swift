import Foundation

/// Ghost Mode behind the GhostCore contract: position estimates and this phone's motion in,
/// `Prediction` records out. A thin layer over `GhostTracker`, which does the work.
///
/// - Estimates that are themselves predictions (`kind == .predicted`) are never taken in, so a
///   prediction cannot confirm itself; nor are `.unavailable` ones or other frames.
/// - `.deadReckoning` estimates are skipped too: Ghost Mode does its own dead reckoning from
///   `MotionObservation`, and taking both would count the same steps twice.
/// - `predict` returns nil while the subject is live (a fresh estimate supersedes the prediction
///   at once) and after `maxHorizon` (only the last observation is shown then).
public final class GhostPredictor: GhostPredictionEngine {
    public static let algorithm = "kalman-ou@1"

    public let producerId: String
    public let frameId: String
    public let tracker: GhostTracker
    /// How long a published prediction may be used before a newer one replaces it, seconds.
    public var predictionMaxAge: Double = 10
    /// Points in `Prediction.cloud` (the contract allows 128).
    public var cloudPoints = 64

    public init(producerId: String, frameId: String = GeoFrame.defaultFrameId,
                config: GhostTracker.Config = GhostTracker.Config()) {
        self.producerId = producerId
        self.frameId = frameId
        tracker = GhostTracker(config: config)
    }

    /// Folds in an estimate received at local time `receivedAt` (for this phone's own estimates,
    /// the time it made them). The same estimate may come again; repeats change nothing.
    public func observe(_ estimate: PositionEstimate, receivedAt: Double) {
        ingest(estimate, receivedAt: receivedAt)
    }

    /// `observe`, returning the recovery check when the subject had been out of sight.
    @discardableResult
    public func ingest(_ estimate: PositionEstimate, receivedAt: Double) -> GhostRecovery? {
        guard let o = GhostObservation(estimate, receivedAt: receivedAt, frameId: frameId) else { return nil }
        return tracker.observe(estimate.subjectId, o)
    }

    /// This phone's own motion sensors.
    public func observe(_ motion: MotionObservation) {
        guard motion.frameId == frameId else { return }
        tracker.motion(motion.subjectId, GhostMotionHint(motion))
    }

    /// The prediction for local time `now`, or nil when there is nothing to predict: unknown,
    /// live, or gone longer than `maxHorizon`.
    public func predict(subjectId: String, at now: Double) -> Prediction? {
        guard let e = tracker.estimate(subjectId, at: now), e.status == .ghost, let belief = e.belief,
              let r95 = e.r95 else { return nil }
        let used = Array(tracker.observations(of: subjectId).suffix(4))
        var inputs = used.enumerated().map { i, o in
            ProvenanceInput(source: o.source.evidence, id: subjectId, age: max(0, now - o.t), used: true,
                            reason: i == used.count - 1 ? "last observation" : "track")
        }
        if e.basis == .deadReckoned {
            inputs.append(ProvenanceInput(source: .inertial, id: subjectId, used: true, reason: "steps and heading"))
        }
        let upstream = used.compactMap(\.provenance)
        let provenance = Provenance.derived(producerId: producerId, algorithm: Self.algorithm, inputs: inputs,
                                            from: upstream, usesGNSS: used.contains { $0.source == .gps })
        let last = e.lastObserved
        let c = belief.core
        // Same dots every second of one gap, so the cloud grows instead of flickering.
        let seed = Self.stableHash(subjectId) ^ last.t.bitPattern
        let cloud = cloudPoints > 0 ? belief.samples(min(cloudPoints, GhostCoreContract.maxCloudPoints), seed: seed)
            .map { FloorVector(x: $0.x, z: $0.z) } : nil
        return Prediction(
            subjectId: subjectId, timestamp: now, frameId: frameId, method: .kalman, lastObservedAt: last.t,
            lastObservedPosition: Position(x: last.x, y: 0, z: last.z), center: Position(x: c.x, y: 0, z: c.z),
            uncertainty: PositionUncertainty(r95: min(r95, GhostCoreContract.maxRadius),
                                             covariance: FloorCovariance(xx: c.xx, xz: c.xz, zz: c.zz)),
            cloud: cloud, freshness: Freshness(maxAge: predictionMaxAge), provenance: provenance)
    }

    /// Status, last observation and the belief, for views (see `GhostEstimate.summary`).
    public func estimate(subjectId: String, at now: Double) -> GhostEstimate? {
        tracker.estimate(subjectId, at: now)
    }

    public func forget(subjectId: String) {
        tracker.forget(subjectId)
    }

    /// FNV-1a: `hashValue` changes between launches.
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return h
    }
}

extension GhostObservation {
    /// The estimate as an observation at local time `receivedAt - ageAtHandoff`, or nil when Ghost
    /// Mode must not use it (see `GhostPredictor`).
    public init?(_ e: PositionEstimate, receivedAt: Double, frameId: String) {
        guard e.frameId == frameId, let p = e.position, p.x.isFinite, p.z.isFinite,
              [.measured, .estimated, .declared].contains(e.kind), e.method != .deadReckoning,
              e.uncertainty.r95.isFinite, e.uncertainty.r95 > 0 else { return nil }
        let source: Source
        switch e.source {
        case .gnss: source = .gps
        case .uwb: source = .uwb
        case .manual: source = .manual
        default: source = .bluetooth
        }
        let velocity = e.velocity.map { GhostVelocity(vx: $0.x, vz: $0.z, sigma: 0.5) }
        self.init(t: receivedAt - e.freshness.ageAtHandoff, x: p.x, z: p.z,
                  sigma: e.uncertainty.r95 / PositionUncertainty.sigmaTo95, source: source, velocity: velocity,
                  provenance: e.provenance)
    }
}

extension GhostObservation.Source {
    var evidence: EvidenceSource {
        switch self {
        case .gps: return .gnss
        case .bluetooth: return .bluetooth
        case .uwb: return .uwb
        case .manual: return .manual
        }
    }
}

extension GhostMotionHint {
    /// Velocity from the interval's displacement, its spread from the displacement's 95% radius
    /// and the heading's sigma (across the direction of travel).
    public init(_ m: MotionObservation) {
        var velocity: GhostVelocity?
        if !m.stationary, let d = m.displacement, m.interval > 0 {
            let vx = d.x / m.interval, vz = d.z / m.interval
            let speed = (vx * vx + vz * vz).squareRoot()
            let r95 = m.uncertainty.displacementR95 ?? (0.3 * d.length + 0.5)
            let along = r95 / PositionUncertainty.sigmaTo95 / m.interval
            velocity = GhostVelocity(vx: vx, vz: vz, sigma: max(along, speed * (m.uncertainty.headingSigma ?? 0.3)))
        }
        self.init(t: m.timestamp, stationary: m.stationary, velocity: velocity)
    }
}
