import Foundation

/// GhostCore shared contract: the records the relay, positioning, integrity, prediction and UI
/// modules exchange. ARCHITECTURE.md explains who produces and consumes each one;
/// website/shared/ghostcore.ts mirrors these types and contract/fixtures/ holds golden JSON both
/// sides must accept.
///
/// Every record carries the same six things:
/// - `timestamp`: Unix seconds on the clock of the phone that produced the record, at which the
///   value holds (for a `Prediction`, the time it predicts). Never subtract two phones' clocks.
/// - `frameId`: the shared metric frame, e.g. `hervanta-v1`: metres, x east, y up, z north.
/// - `source`: the kind of evidence behind the record.
/// - an uncertainty of its own type; every position carries `r95`, the horizontal radius holding
///   95 % of the belief.
/// - `freshness`: how old the record already was when it was handed on, and how long it stays usable.
/// - `provenance`: who produced it, with which algorithm, from which inputs. The `simulated` and
///   `gnssDependent` flags propagate to everything derived from such an input.
public enum GhostCoreContract {
    public static let version = 1

    public static let maxInputs = 16
    public static let maxContributors = 16
    public static let maxReasons = IntegrityAssessment.Reason.allCases.count
    public static let maxEvidence = 16
    public static let maxCandidates = 8
    public static let maxCloudPoints = 128
    public static let maxRawSamples = 16
    public static let maxObservationsPerMessage = 16
    public static let maxTextLength = 160
    public static let maxAlgorithmLength = 64
    /// Predictions further ahead than this are not useful and are not accepted.
    public static let maxHorizonSeconds = 3_600.0
    /// Positions share the dashboard's coordinate limit; radii may grow past the dashboard's accuracy
    /// limit (a long prediction), so mapping to a `DeviceUpdate` clamps them.
    public static let maxCoordinate = DashboardContract.maxCoordinate
    public static let maxRadius = 10_000.0
    /// A relayed message must fit inside one mesh packet (4 KiB) together with its envelope.
    public static let maxRelayBytes = 3_072

    static func isValidFrameId(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
    }
}

public enum GhostCoreContractError: Error, Equatable {
    /// The record breaks a contract rule; `field` names the first rule that failed.
    case invalid(_ field: String)
    case tooLarge
}

private func require(_ condition: Bool, _ field: String) throws {
    guard condition else { throw GhostCoreContractError.invalid(field) }
}

private func isText(_ value: String?) -> Bool {
    value.map { $0.utf16.count <= GhostCoreContract.maxTextLength } ?? true
}

private func isCoordinate(_ value: Double) -> Bool {
    value.isFinite && abs(value) <= GhostCoreContract.maxCoordinate
}

private func isRadius(_ value: Double) -> Bool {
    value.isFinite && value >= 0 && value <= GhostCoreContract.maxRadius
}

// MARK: - Shared parts

/// The kind of evidence behind a record.
public enum EvidenceSource: String, Codable, CaseIterable {
    case gnss, bluetooth, uwb, inertial, manual, fusion, prediction
}

/// A point or a vector on the floor plane of the shared frame: x east, z north, metres
/// (m/s for a velocity).
public struct FloorVector: Codable, Equatable {
    public let x: Double
    public let z: Double

    public init(x: Double, z: Double) {
        self.x = x
        self.z = z
    }

    public init(_ point: FloorPoint) {
        self.init(x: point.x, z: point.z)
    }

    public var length: Double { (x * x + z * z).squareRoot() }
}

/// How old a record already was when it was handed on, and how long it stays usable. Ages are
/// measured on one clock at a time: the producer sets `ageAtHandoff` (e.g. a GNSS fix's age when
/// published), each relay adds the time it held the record, and a receiver adds the time since it
/// received the record on its own clock.
public struct Freshness: Codable, Equatable {
    /// Seconds.
    public let ageAtHandoff: Double
    /// Seconds of age after which the record must not be shown or used as current.
    public let maxAge: Double

    public init(ageAtHandoff: Double = 0, maxAge: Double) {
        self.ageAtHandoff = ageAtHandoff
        self.maxAge = maxAge
    }

    /// Age now, given when this phone received (or produced) the record on its own clock.
    public func age(receivedAt: Double, now: Double) -> Double {
        ageAtHandoff + max(0, now - receivedAt)
    }

    public func isStale(receivedAt: Double, now: Double) -> Bool {
        age(receivedAt: receivedAt, now: now) > maxAge
    }

    /// The same record handed on after this phone held it for `heldFor` seconds.
    public func handedOn(heldFor: Double) -> Freshness {
        Freshness(ageAtHandoff: ageAtHandoff + max(0, heldFor), maxAge: maxAge)
    }

    func validate() throws {
        try require(ageAtHandoff.isFinite && ageAtHandoff >= 0, "freshness.ageAtHandoff")
        try require(maxAge.isFinite && maxAge > 0 && maxAge <= 86_400, "freshness.maxAge")
    }
}

/// One input a producer considered: used, or rejected with a reason.
public struct ProvenanceInput: Codable, Equatable {
    public let source: EvidenceSource
    /// The device or record the input came from, when it has one.
    public let id: String?
    /// Seconds old when it was considered.
    public let age: Double?
    public let used: Bool
    /// Why it was rejected, or how it was used. Short, human readable.
    public let reason: String?

    public init(source: EvidenceSource, id: String? = nil, age: Double? = nil, used: Bool = true, reason: String? = nil) {
        self.source = source
        self.id = id
        self.age = age
        self.used = used
        self.reason = reason
    }
}

/// Who produced a record, how, and from what.
public struct Provenance: Codable, Equatable {
    /// App device ID of the phone that produced the record.
    public let producerId: String
    /// "name@version", e.g. "bluetooth-estimator@1", "gnss-integrity@1", "kalman-cv@1".
    public let algorithm: String
    public let inputs: [ProvenanceInput]
    /// Device IDs that contributed at any depth, including the producer. A phone drops a relayed
    /// estimate that already contains its own ID, so estimates cannot anchor themselves in a loop.
    public let contributors: [String]
    /// The record depends on GNSS somewhere upstream, so it is not independent evidence about GNSS.
    public let gnssDependent: Bool
    /// The record comes from a simulator or scenario, or from anything that did. Never dropped.
    public let simulated: Bool

    public init(producerId: String, algorithm: String, inputs: [ProvenanceInput] = [], contributors: [String]? = nil,
                gnssDependent: Bool, simulated: Bool = false) {
        self.producerId = producerId
        self.algorithm = algorithm
        self.inputs = inputs
        self.contributors = contributors ?? [producerId]
        self.gnssDependent = gnssDependent
        self.simulated = simulated
    }

    /// Provenance for a record derived from `upstream` records: the flags are inherited, and the
    /// contributors are merged (the producer first, then upstream in order, capped).
    public static func derived(producerId: String, algorithm: String, inputs: [ProvenanceInput] = [],
                               from upstream: [Provenance], usesGNSS: Bool = false, simulated: Bool = false) -> Provenance {
        var contributors = [producerId]
        for id in upstream.flatMap(\.contributors) where !contributors.contains(id) {
            guard contributors.count < GhostCoreContract.maxContributors else { break }
            contributors.append(id)
        }
        return Provenance(producerId: producerId, algorithm: algorithm, inputs: inputs, contributors: contributors,
                          gnssDependent: usesGNSS || upstream.contains { $0.gnssDependent },
                          simulated: simulated || upstream.contains { $0.simulated })
    }

    public func contains(device id: String) -> Bool { contributors.contains(id) }

    func validate() throws {
        try require(DashboardContract.isValidId(producerId), "provenance.producerId")
        try require(!algorithm.isEmpty && algorithm.utf16.count <= GhostCoreContract.maxAlgorithmLength,
                    "provenance.algorithm")
        try require(inputs.count <= GhostCoreContract.maxInputs, "provenance.inputs")
        for input in inputs {
            try require(input.id.map(DashboardContract.isValidId) ?? true, "provenance.inputs.id")
            try require(input.age.map { $0.isFinite && $0 >= 0 } ?? true, "provenance.inputs.age")
            try require(isText(input.reason), "provenance.inputs.reason")
        }
        try require(contributors.first == producerId && contributors.count <= GhostCoreContract.maxContributors
                    && Set(contributors).count == contributors.count
                    && contributors.allSatisfy(DashboardContract.isValidId), "provenance.contributors")
    }
}

/// Floor-plane covariance in m² (x east, z north).
public struct FloorCovariance: Codable, Equatable {
    public let xx: Double
    public let xz: Double
    public let zz: Double

    public init(xx: Double, xz: Double, zz: Double) {
        self.xx = xx
        self.xz = xz
        self.zz = zz
    }

    /// Larger eigenvalue, m².
    public var largestVariance: Double {
        let mean = (xx + zz) / 2
        let spread = (((xx - zz) / 2) * ((xx - zz) / 2) + xz * xz).squareRoot()
        return mean + spread
    }

    var isValid: Bool {
        [xx, xz, zz].allSatisfy(\.isFinite) && xx >= 0 && zz >= 0 && xx * zz - xz * xz >= -1e-9 * max(1, xx * zz)
    }
}

/// Uncertainty of a position on the floor plane.
public struct PositionUncertainty: Codable, Equatable {
    /// Metres around the position holding 95 % of the belief. Required on every position.
    public let r95: Double
    /// A ring or several separate spots: the position is not a good single guess.
    public let ambiguous: Bool
    public let covariance: FloorCovariance?
    /// Metres, 95 %, when height was estimated; nil means the height is assumed.
    public let vertical95: Double?

    public init(r95: Double, ambiguous: Bool = false, covariance: FloorCovariance? = nil, vertical95: Double? = nil) {
        self.r95 = r95
        self.ambiguous = ambiguous
        self.covariance = covariance
        self.vertical95 = vertical95
    }

    /// 95 % radius from a covariance: the circle around the larger axis of the 95 % ellipse.
    public init(covariance: FloorCovariance, ambiguous: Bool = false) {
        self.init(r95: Self.r95(fromSigma: covariance.largestVariance.squareRoot()), ambiguous: ambiguous,
                  covariance: covariance)
    }

    /// For a circular Gaussian with per-axis standard deviation sigma, P(r < R) = 1 - exp(-R²/2σ²).
    public static let sigmaTo95 = (-2 * log(0.05)).squareRoot()
    static let sigmaTo68 = (-2 * log(0.32)).squareRoot()

    public static func r95(fromSigma sigma: Double) -> Double { sigma * sigmaTo95 }

    /// iOS `horizontalAccuracy` is treated as a 68 % radius (Apple does not state its level).
    public static func r95(fromRadius68 radius: Double) -> Double { radius * sigmaTo95 / sigmaTo68 }

    func validate() throws {
        try require(isRadius(r95), "uncertainty.r95")
        try require(covariance?.isValid ?? true, "uncertainty.covariance")
        try require(vertical95.map(isRadius) ?? true, "uncertainty.vertical95")
    }
}

/// Fields every GhostCore record has.
public protocol GhostRecord: Codable, Equatable {
    var timestamp: Double { get }
    var frameId: String { get }
    var source: EvidenceSource { get }
    var freshness: Freshness { get }
    var provenance: Provenance { get }
    func validate() throws
}

extension GhostRecord {
    func validateCommon() throws {
        try require(timestamp.isFinite && timestamp > 0, "timestamp")
        try require(GhostCoreContract.isValidFrameId(frameId), "frameId")
        try freshness.validate()
        try provenance.validate()
    }

    public func isStale(receivedAt: Double, now: Double) -> Bool {
        freshness.isStale(receivedAt: receivedAt, now: now)
    }
}

// MARK: - PeerObservation

/// What one phone heard of one peer over Bluetooth, as a snapshot at most once a second. It carries
/// the raw RSSI samples since the previous snapshot so the positioning engine can filter them
/// itself. RSSI is link quality: it has no distance field; ranges belong to the positioning
/// engine's calibrated model.
public struct PeerObservation: GhostRecord {
    public enum Channel: String, Codable, CaseIterable {
        /// readRSSI on a connected link (central side).
        case connection
        /// Advertisement RSSI (irregular; coalesced by iOS).
        case advertisement
    }

    public enum LinkState: String, Codable, CaseIterable {
        /// Subscribed and the peer's Hello arrived.
        case ready
        case connecting
        /// Heard advertising, no link.
        case advertisementOnly
        /// The link closed; the samples are the last ones heard.
        case lost
    }

    /// RSSI spread of this snapshot.
    public struct Uncertainty: Codable, Equatable {
        /// dB standard deviation over the observer's recent samples; nil with fewer than two.
        public let stdDevDb: Double?
        /// Samples the observer has heard of this peer in its smoothing window.
        public let sampleCount: Int

        public init(stdDevDb: Double?, sampleCount: Int) {
            self.stdDevDb = stdDevDb
            self.sampleCount = sampleCount
        }
    }

    public let observerId: String
    /// The peer's app device ID from its Hello; nil when it was only heard advertising.
    public let peerId: String?
    /// Time of the newest sample.
    public let timestamp: Double
    public let frameId: String
    public let channel: Channel
    public let linkState: LinkState
    /// dBm, oldest first, since the previous snapshot.
    public let rawRSSI: [Double]
    /// Seconds covered by `rawRSSI`.
    public let window: Double
    /// dBm, the observer's smoothed value.
    public let smoothedRSSI: Double?
    public let uncertainty: Uncertainty
    public let txPower: Int?
    /// Hardware model string of the peer (e.g. "iPhone16,1"), for per-model calibration.
    public let peerModel: String?
    public let source: EvidenceSource
    public let freshness: Freshness
    public let provenance: Provenance

    public init(observerId: String, peerId: String?, timestamp: Double, frameId: String, channel: Channel,
                linkState: LinkState, rawRSSI: [Double], window: Double, smoothedRSSI: Double?,
                uncertainty: Uncertainty, txPower: Int? = nil, peerModel: String? = nil,
                freshness: Freshness, provenance: Provenance) {
        self.observerId = observerId
        self.peerId = peerId
        self.timestamp = timestamp
        self.frameId = frameId
        self.channel = channel
        self.linkState = linkState
        self.rawRSSI = rawRSSI
        self.window = window
        self.smoothedRSSI = smoothedRSSI
        self.uncertainty = uncertainty
        self.txPower = txPower
        self.peerModel = peerModel
        self.source = .bluetooth
        self.freshness = freshness
        self.provenance = provenance
    }

    public func validate() throws {
        try validateCommon()
        let rssi = Double(DashboardContract.rssiRange.lowerBound)...Double(DashboardContract.rssiRange.upperBound)
        try require(source == .bluetooth, "source")
        try require(DashboardContract.isValidId(observerId) && provenance.producerId == observerId, "observerId")
        try require(peerId.map { DashboardContract.isValidId($0) && $0 != observerId } ?? true, "peerId")
        try require(rawRSSI.count <= GhostCoreContract.maxRawSamples && rawRSSI.allSatisfy(rssi.contains), "rawRSSI")
        try require(window.isFinite && window >= 0 && window <= 60, "window")
        try require(smoothedRSSI.map(rssi.contains) ?? true, "smoothedRSSI")
        try require(uncertainty.stdDevDb.map { $0.isFinite && $0 >= 0 && $0 <= 60 } ?? true, "uncertainty.stdDevDb")
        try require(uncertainty.sampleCount >= rawRSSI.count, "uncertainty.sampleCount")
        try require(txPower.map { (-127...20).contains($0) } ?? true, "txPower")
        try require(peerModel.map { !$0.isEmpty && $0.utf16.count <= 32 } ?? true, "peerModel")
    }
}

// MARK: - PositionEstimate

public enum PositionMode: String, Codable, CaseIterable {
    /// y is 0 and the height is assumed.
    case floor
    /// y was estimated.
    case threeD = "3d"
}

/// Where a phone is, with what certainty, and how that is known.
public struct PositionEstimate: GhostRecord {
    /// How the position may be presented. Only `measured` is a measured coordinate, and a GNSS one
    /// only together with a `trusted` IntegrityAssessment.
    public enum Kind: String, Codable, CaseIterable {
        /// A direct fix: GNSS or UWB.
        case measured
        /// Inferred from peers and/or motion.
        case estimated
        /// No fresh evidence; see `Prediction` for the full record.
        case predicted
        /// Typed by a person: a fixed anchor or a pinned spot.
        case declared
        /// Nothing usable; `position` is nil.
        case unavailable
    }

    public enum Method: String, Codable, CaseIterable {
        case gnss, uwb, multilateration, proximity, particle, deadReckoning, fusion, manual, prediction, none
    }

    /// The phone this position is about.
    public let subjectId: String
    public let timestamp: Double
    public let frameId: String
    public let kind: Kind
    public let method: Method
    /// Nil only when `kind` is `unavailable`.
    public let position: Position?
    public let positionMode: PositionMode
    public let uncertainty: PositionUncertainty
    /// The separate spots of an ambiguous belief.
    public let candidates: [FloorVector]?
    /// Radians from +z (north) toward +x (east).
    public let heading: Double?
    public let headingSigma: Double?
    /// m/s on the floor plane.
    public let velocity: FloorVector?
    /// Producer-clock time of the last absolute constraint (GNSS, UWB or an anchor) behind this estimate.
    public let lastAbsoluteAt: Double?
    public let source: EvidenceSource
    public let freshness: Freshness
    public let provenance: Provenance

    public init(subjectId: String, timestamp: Double, frameId: String, kind: Kind, method: Method,
                position: Position?, positionMode: PositionMode = .floor, uncertainty: PositionUncertainty,
                candidates: [FloorVector]? = nil, heading: Double? = nil, headingSigma: Double? = nil,
                velocity: FloorVector? = nil, lastAbsoluteAt: Double? = nil, source: EvidenceSource,
                freshness: Freshness, provenance: Provenance) {
        self.subjectId = subjectId
        self.timestamp = timestamp
        self.frameId = frameId
        self.kind = kind
        self.method = method
        self.position = position
        self.positionMode = positionMode
        self.uncertainty = uncertainty
        self.candidates = candidates
        self.heading = heading
        self.headingSigma = headingSigma
        self.velocity = velocity
        self.lastAbsoluteAt = lastAbsoluteAt
        self.source = source
        self.freshness = freshness
        self.provenance = provenance
    }

    /// The source the dashboard upload contract can express. Estimates and predictions are `none`:
    /// the dashboard places such phones itself and never shows them as measured.
    public var dashboardSource: PositionSource {
        switch (kind, method) {
        case (.measured, .gnss): return .gps
        case (.measured, _), (.declared, _): return .manual
        default: return .none
        }
    }

    public func validate() throws {
        try validateCommon()
        try require(DashboardContract.isValidId(subjectId), "subjectId")
        try uncertainty.validate()
        switch kind {
        case .measured:
            try require([.gnss, .uwb].contains(method) && source.rawValue == method.rawValue, "kind.measured")
        case .estimated:
            try require([.multilateration, .proximity, .particle, .deadReckoning, .fusion].contains(method)
                        && [.bluetooth, .uwb, .inertial, .fusion].contains(source), "kind.estimated")
        case .predicted:
            try require(method == .prediction && source == .prediction, "kind.predicted")
        case .declared:
            try require(method == .manual && source == .manual, "kind.declared")
        case .unavailable:
            try require(method == .none && position == nil, "kind.unavailable")
        }
        if let position {
            try require([position.x, position.y, position.z].allSatisfy(isCoordinate), "position")
            try require(positionMode == .threeD || position.y == 0, "positionMode")
        } else {
            try require(kind == .unavailable, "position")
        }
        try require(method != .gnss || provenance.gnssDependent, "provenance.gnssDependent")
        if let candidates {
            try require(uncertainty.ambiguous && candidates.count <= GhostCoreContract.maxCandidates
                        && candidates.allSatisfy { isCoordinate($0.x) && isCoordinate($0.z) }, "candidates")
        }
        try require(heading.map(\.isFinite) ?? true, "heading")
        try require(headingSigma.map { $0.isFinite && $0 >= 0 } ?? true, "headingSigma")
        try require(velocity.map { $0.x.isFinite && $0.z.isFinite && $0.length <= 100 } ?? true, "velocity")
        try require(lastAbsoluteAt.map { $0.isFinite && $0 <= timestamp + 1 } ?? true, "lastAbsoluteAt")
    }
}

// MARK: - IntegrityAssessment

/// Whether this phone's GNSS can be believed right now. Phone data can show that GNSS behaves
/// impossibly or disagrees with independent evidence; it cannot prove spoofing, so the type has no
/// way to say "spoofed".
public struct IntegrityAssessment: GhostRecord {
    public enum Status: String, Codable, CaseIterable {
        /// No anomaly, and at least one GNSS-independent check (inertial, a surveyed anchor, or
        /// position evidence with gnssDependent false) agrees. The only status that may anchor others.
        case trusted
        /// No anomaly, but poor accuracy or an aging fix.
        case degraded
        /// An anomaly; not used to anchor others.
        case suspect
        /// An anomaly bad enough not to use the fix at all.
        case rejected
        /// No fix, or one too old or invalid.
        case unavailable
        /// Self-consistent, but nothing independent confirms it. Agreement with GNSS-placed peers
        /// never upgrades this to trusted.
        case insufficientEvidence
    }

    public enum Reason: String, Codable, CaseIterable {
        case noFix, staleFix, invalidFix, timestampInconsistent, degradedAccuracy, accuracyInconsistent,
             impossibleSpeed, impossibleAcceleration, positionJump, inertialDisagreement, slowDrift,
             peerDisagreement, independentEvidenceDisagreement, peerEvidenceNotIndependent, insufficientEvidence
        /// GNSS came back after a rejection while this phone's own reference had grown too loose to
        /// tell a real return from a new offset; capped at insufficientEvidence until independent
        /// position evidence agrees.
        case continuityLost
        /// The checks pass again but trust is still climbing after an anomaly.
        case recovering
    }

    /// One check the engine ran.
    public struct Evidence: Codable, Equatable {
        /// freshness, accuracy, timing, speed, acceleration, jump, inertial, peerProximity,
        /// anchorProximity or positionEvidence.
        public let check: String
        public let observed: Double?
        public let threshold: Double?
        /// Unit of `observed` and `threshold`, e.g. "m/s", "m".
        public let unit: String?
        /// 1 = fully consistent, 0 = impossible.
        public let score: Double
        /// False when the evidence itself depends on GNSS (e.g. a peer placed by GPS).
        public let independent: Bool
        public let reason: Reason?

        public init(check: String, observed: Double? = nil, threshold: Double? = nil, unit: String? = nil,
                    score: Double, independent: Bool, reason: Reason? = nil) {
            self.check = check
            self.observed = observed
            self.threshold = threshold
            self.unit = unit
            self.score = score
            self.independent = independent
            self.reason = reason
        }
    }

    /// Coverage heuristic for the trust score: `upper` is the score; `lower` is 0 with no
    /// GNSS-independent check active (nothing rules out a slow or common-mode error), half the score
    /// with only relative (inertial) or only absolute (anchor, independent position) evidence, and
    /// the score with both.
    public struct TrustInterval: Codable, Equatable {
        public let lower: Double
        public let upper: Double

        public init(lower: Double, upper: Double) {
            self.lower = lower
            self.upper = upper
        }
    }

    /// The phone whose GNSS was judged.
    public let subjectId: String
    /// When the assessment was made.
    public let timestamp: Double
    public let frameId: String
    public let status: Status
    /// 0 = do not believe, 1 = fully consistent.
    public let trustScore: Double
    public let uncertainty: TrustInterval
    public let reasons: [Reason]
    public let evidence: [Evidence]
    /// The raw fix that was judged, in the frame, even when rejected, so a UI can show raw vs estimate.
    public let evaluatedFix: PositionEstimate?
    /// Smallest GNSS offset (m) the active independent checks would flag right now; nil when
    /// unbounded. The honest answer to "how far could GPS move this phone without anyone noticing".
    public let minimumDetectableOffsetMeters: Double?
    /// One readable line for the UI, e.g. "GPS jumped 412 m in 2 s".
    public let summary: String?
    public let source: EvidenceSource
    public let freshness: Freshness
    public let provenance: Provenance

    public init(subjectId: String, timestamp: Double, frameId: String, status: Status, trustScore: Double,
                uncertainty: TrustInterval, reasons: [Reason] = [], evidence: [Evidence] = [],
                evaluatedFix: PositionEstimate? = nil, minimumDetectableOffsetMeters: Double? = nil,
                summary: String? = nil, source: EvidenceSource = .fusion,
                freshness: Freshness, provenance: Provenance) {
        self.subjectId = subjectId
        self.timestamp = timestamp
        self.frameId = frameId
        self.status = status
        self.trustScore = trustScore
        self.uncertainty = uncertainty
        self.reasons = reasons
        self.evidence = evidence
        self.evaluatedFix = evaluatedFix
        self.minimumDetectableOffsetMeters = minimumDetectableOffsetMeters
        self.summary = summary
        self.source = source
        self.freshness = freshness
        self.provenance = provenance
    }

    /// Only trusted GNSS may anchor other phones.
    public var mayAnchorOthers: Bool { status == .trusted }

    /// Time of the judged fix.
    public var fixTimestamp: Double? { evaluatedFix?.timestamp }

    public func validate() throws {
        try validateCommon()
        try require(DashboardContract.isValidId(subjectId), "subjectId")
        try require((0...1).contains(trustScore), "trustScore")
        try require(uncertainty.lower >= 0 && uncertainty.lower <= trustScore && trustScore <= uncertainty.upper
                    && uncertainty.upper <= 1, "uncertainty")
        try require(reasons.count <= GhostCoreContract.maxReasons && Set(reasons).count == reasons.count, "reasons")
        try require(![.suspect, .rejected, .degraded].contains(status) || !reasons.isEmpty, "reasons.required")
        try require(evidence.count <= GhostCoreContract.maxEvidence, "evidence")
        for item in evidence {
            try require(!item.check.isEmpty && item.check.utf16.count <= 48, "evidence.check")
            try require((0...1).contains(item.score), "evidence.score")
            try require((item.observed?.isFinite ?? true) && (item.threshold?.isFinite ?? true), "evidence.value")
            try require(item.unit.map { $0.utf16.count <= 16 } ?? true, "evidence.unit")
        }
        if let evaluatedFix {
            try evaluatedFix.validate()
            try require(evaluatedFix.method == .gnss && evaluatedFix.subjectId == subjectId
                        && evaluatedFix.frameId == frameId, "evaluatedFix")
        }
        try require(status != .unavailable || evaluatedFix == nil, "evaluatedFix.unavailable")
        try require(minimumDetectableOffsetMeters.map(isRadius) ?? true, "minimumDetectableOffsetMeters")
        try require(isText(summary), "summary")
    }
}

// MARK: - MotionObservation

/// How this phone moved over a short interval, from its own sensors.
public struct MotionObservation: GhostRecord {
    public enum Method: String, Codable, CaseIterable {
        case pedometer, stepDetector, deviceMotion, visualOdometry
    }

    public struct Uncertainty: Codable, Equatable {
        /// Metres, 95 % radius of the displacement's end point.
        public let displacementR95: Double?
        /// Radians, 1-sigma of `heading`.
        public let headingSigma: Double?

        public init(displacementR95: Double?, headingSigma: Double?) {
            self.displacementR95 = displacementR95
            self.headingSigma = headingSigma
        }
    }

    public let subjectId: String
    /// End of the interval.
    public let timestamp: Double
    /// Seconds; the interval starts at `timestamp - interval`.
    public let interval: Double
    public let frameId: String
    public let method: Method
    public let steps: Int?
    /// Metres moved over the interval in the frame (x east, z north).
    public let displacement: FloorVector?
    /// Radians from +z (north) toward +x (east), at the end of the interval.
    public let heading: Double?
    public let stationary: Bool
    public let uncertainty: Uncertainty
    public let source: EvidenceSource
    public let freshness: Freshness
    public let provenance: Provenance

    public init(subjectId: String, timestamp: Double, interval: Double, frameId: String, method: Method,
                steps: Int? = nil, displacement: FloorVector? = nil, heading: Double? = nil, stationary: Bool,
                uncertainty: Uncertainty, source: EvidenceSource = .inertial, freshness: Freshness,
                provenance: Provenance) {
        self.subjectId = subjectId
        self.timestamp = timestamp
        self.interval = interval
        self.frameId = frameId
        self.method = method
        self.steps = steps
        self.displacement = displacement
        self.heading = heading
        self.stationary = stationary
        self.uncertainty = uncertainty
        self.source = source
        self.freshness = freshness
        self.provenance = provenance
    }

    public func validate() throws {
        try validateCommon()
        try require(DashboardContract.isValidId(subjectId), "subjectId")
        try require([.inertial, .fusion].contains(source), "source")
        try require(interval.isFinite && interval > 0 && interval <= 60, "interval")
        try require(steps.map { (0...1_000).contains($0) } ?? true, "steps")
        // 12 m/s is far beyond walking; it only rejects garbage.
        try require(displacement.map { $0.x.isFinite && $0.z.isFinite && $0.length <= 12 * interval } ?? true,
                    "displacement")
        try require(heading.map { $0.isFinite && abs($0) <= 2 * Double.pi } ?? true, "heading")
        try require(!stationary || (steps ?? 0) == 0, "stationary")
        try require(uncertainty.displacementR95.map(isRadius) ?? true, "uncertainty.displacementR95")
        try require(uncertainty.headingSigma.map { $0.isFinite && $0 >= 0 } ?? true, "uncertainty.headingSigma")
    }
}

// MARK: - Prediction

/// Where a phone has probably gone since it was last observed. Never presented as live: it ages
/// from `lastObservedAt`, and a fresh observation of the subject replaces it.
public struct Prediction: GhostRecord {
    public enum Method: String, Codable, CaseIterable {
        case stationary, constantVelocity, kalman, movementModel
    }

    public let subjectId: String
    /// The time predicted.
    public let timestamp: Double
    public let frameId: String
    public let method: Method
    /// Producer-clock time of the last observation the prediction starts from.
    public let lastObservedAt: Double
    public let lastObservedPosition: Position
    /// Most likely spot.
    public let center: Position
    public let uncertainty: PositionUncertainty
    /// A sample of the belief for drawing. Local only: a RelayMessage never carries it.
    public let cloud: [FloorVector]?
    public let source: EvidenceSource
    public let freshness: Freshness
    public let provenance: Provenance

    public init(subjectId: String, timestamp: Double, frameId: String, method: Method, lastObservedAt: Double,
                lastObservedPosition: Position, center: Position, uncertainty: PositionUncertainty,
                cloud: [FloorVector]? = nil, freshness: Freshness, provenance: Provenance) {
        self.subjectId = subjectId
        self.timestamp = timestamp
        self.frameId = frameId
        self.method = method
        self.lastObservedAt = lastObservedAt
        self.lastObservedPosition = lastObservedPosition
        self.center = center
        self.uncertainty = uncertainty
        self.cloud = cloud
        self.source = .prediction
        self.freshness = freshness
        self.provenance = provenance
    }

    /// Seconds since the subject was last observed.
    public var horizon: Double { timestamp - lastObservedAt }

    /// The prediction as a position, for views and consumers that only take positions.
    public var asPositionEstimate: PositionEstimate {
        PositionEstimate(subjectId: subjectId, timestamp: timestamp, frameId: frameId, kind: .predicted,
                         method: .prediction, position: center, positionMode: center.y == 0 ? .floor : .threeD,
                         uncertainty: uncertainty, lastAbsoluteAt: lastObservedAt, source: .prediction,
                         freshness: freshness, provenance: provenance)
    }

    /// The same prediction without its cloud, as it may travel over the mesh.
    public var withoutCloud: Prediction {
        Prediction(subjectId: subjectId, timestamp: timestamp, frameId: frameId, method: method,
                   lastObservedAt: lastObservedAt, lastObservedPosition: lastObservedPosition, center: center,
                   uncertainty: uncertainty, cloud: nil, freshness: freshness, provenance: provenance)
    }

    public func validate() throws {
        try validateCommon()
        try require(source == .prediction, "source")
        try require(DashboardContract.isValidId(subjectId), "subjectId")
        try require(lastObservedAt.isFinite && lastObservedAt > 0 && horizon >= 0
                    && horizon <= GhostCoreContract.maxHorizonSeconds, "horizon")
        for (field, p) in [("lastObservedPosition", lastObservedPosition), ("center", center)] {
            try require([p.x, p.y, p.z].allSatisfy(isCoordinate), field)
        }
        try uncertainty.validate()
        try require(cloud.map { $0.count <= GhostCoreContract.maxCloudPoints
                    && $0.allSatisfy { isCoordinate($0.x) && isCoordinate($0.z) } } ?? true, "cloud")
    }
}

// MARK: - RelayMessage

/// A contract record travelling over the mesh. The envelope's identity (origin, epoch, sequence,
/// messageId) is set once by the origin and never changed by relays; each relay appends itself to
/// `path`, takes one hop and adds its hold time to `freshness`. `source`, the uncertainty and
/// `provenance` are the payload's own.
public struct RelayMessage: GhostRecord {
    public enum Payload: Equatable {
        case position(PositionEstimate)
        case integrity(IntegrityAssessment)
        case prediction(Prediction)
        case observations([PeerObservation])

        var record: (frameId: String, source: EvidenceSource, provenance: Provenance)? {
            switch self {
            case .position(let r): return (r.frameId, r.source, r.provenance)
            case .integrity(let r): return (r.frameId, r.source, r.provenance)
            case .prediction(let r): return (r.frameId, r.source, r.provenance)
            case .observations(let list): return list.first.map { ($0.frameId, $0.source, $0.provenance) }
            }
        }
    }

    /// UUID chosen by the origin, kept across relays.
    public let messageId: String
    public let originId: String
    /// UUID of the origin's current run; a restart starts a new epoch.
    public let epochId: String
    public let sequence: Int
    /// Origin-clock creation time; advisory only (clocks are not synchronised).
    public let timestamp: Double
    public let frameId: String
    public let hopsRemaining: Int
    /// Device IDs of the phones that relayed this copy, oldest first; empty from the origin.
    public let path: [String]
    /// `ageAtHandoff` sums hold times hop by hop; `maxAge` is the message's time to live.
    public let freshness: Freshness
    public let payload: Payload

    public init(messageId: String = UUID().uuidString, originId: String, epochId: String, sequence: Int,
                timestamp: Double, frameId: String, hopsRemaining: Int, path: [String] = [],
                freshness: Freshness, payload: Payload) {
        self.messageId = messageId
        self.originId = originId
        self.epochId = epochId
        self.sequence = sequence
        self.timestamp = timestamp
        self.frameId = frameId
        self.hopsRemaining = hopsRemaining
        self.path = path
        self.freshness = freshness
        self.payload = payload
    }

    public var source: EvidenceSource { payload.record?.source ?? .bluetooth }

    public var provenance: Provenance {
        payload.record?.provenance ?? Provenance(producerId: originId, algorithm: "relay@1", gnssDependent: false)
    }

    /// The copy a relay sends on: one hop fewer, itself appended to the path, its hold time added.
    public func relayed(by relayId: String, heldFor: Double) -> RelayMessage? {
        guard hopsRemaining > 0, relayId != originId, !path.contains(relayId),
              path.count < MeshProtocol.maxPathLength else { return nil }
        return RelayMessage(messageId: messageId, originId: originId, epochId: epochId, sequence: sequence,
                            timestamp: timestamp, frameId: frameId, hopsRemaining: hopsRemaining - 1,
                            path: path + [relayId], freshness: freshness.handedOn(heldFor: heldFor), payload: payload)
    }

    public func validate() throws {
        try validateCommon()
        try require(UUID(uuidString: messageId) != nil, "messageId")
        try require(DashboardContract.isValidId(originId), "originId")
        try require(UUID(uuidString: epochId) != nil, "epochId")
        try require(sequence >= 0 && sequence <= 9_007_199_254_740_991, "sequence")
        try require((0...8).contains(hopsRemaining), "hopsRemaining")
        try require(path.count <= MeshProtocol.maxPathLength && Set(path).count == path.count
                    && path.allSatisfy { DashboardContract.isValidId($0) && $0 != originId }, "path")
        try require(payload.record?.frameId == frameId, "payload.frameId")
        try require(payload.record?.provenance.producerId == originId, "payload.producerId")
        switch payload {
        case .position(let r): try r.validate()
        case .integrity(let r): try r.validate()
        case .prediction(let r):
            try require(r.cloud == nil, "payload.cloud")
            try r.validate()
        case .observations(let list):
            try require(!list.isEmpty && list.count <= GhostCoreContract.maxObservationsPerMessage, "payload.observations")
            for r in list { try r.validate() }
        }
    }

    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= GhostCoreContract.maxRelayBytes else { throw GhostCoreContractError.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> RelayMessage {
        guard data.count <= GhostCoreContract.maxRelayBytes else { throw GhostCoreContractError.tooLarge }
        let message = try JSONDecoder().decode(RelayMessage.self, from: data)
        try message.validate()
        return message
    }
}

/// JSON shape: `{"type": "position", "position": {...}}`, one key per payload type.
extension RelayMessage.Payload: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, position, integrity, prediction, observations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "position": self = .position(try container.decode(PositionEstimate.self, forKey: .position))
        case "integrity": self = .integrity(try container.decode(IntegrityAssessment.self, forKey: .integrity))
        case "prediction": self = .prediction(try container.decode(Prediction.self, forKey: .prediction))
        case "observations": self = .observations(try container.decode([PeerObservation].self, forKey: .observations))
        default: throw GhostCoreContractError.invalid("payload.type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .position(let r):
            try container.encode("position", forKey: .type)
            try container.encode(r, forKey: .position)
        case .integrity(let r):
            try container.encode("integrity", forKey: .type)
            try container.encode(r, forKey: .integrity)
        case .prediction(let r):
            try container.encode("prediction", forKey: .type)
            try container.encode(r, forKey: .prediction)
        case .observations(let list):
            try container.encode("observations", forKey: .type)
            try container.encode(list, forKey: .observations)
        }
    }
}
