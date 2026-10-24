import Foundation

// GNSS integrity: judges, fix by fix, how far a GNSS position can be believed. It looks at the fix
// itself (reported accuracy, age, timestamps, speed and acceleration between fixes, jumps away
// from where we expected to be) and at evidence from outside the receiver: inertial motion (steps
// and compass, or Core Motion), peers heard over Bluetooth, surveyed anchors, and positions
// estimated without this phone's GNSS. Grown from the Luotsi trust engine (gps-katoaa
// js/engine.js): one confident objection is enough to stop believing a fix, and trust comes back
// only slowly.
//
// This is anomaly detection, not spoofing detection. A fix that fails these checks can come from
// multipath, a receiver fault, jamming, a wrong inertial or peer input, or spoofing; phone data
// cannot tell them apart, so an assessment lists possible causes and never confirms spoofing.
// Peers whose positions come from their own GNSS share its errors (one spoofer, one jammer or one
// ionosphere covers them all), so their agreement never verifies a fix: only evidence that does
// not depend on any GNSS receiver can make a fix `trusted`.
//
// All inputs share one clock in seconds (e.g. Date().timeIntervalSince1970) and the floor plane of
// the shared frame (x east, z north, meters). Same inputs, same assessments: nothing is random.

/// One GNSS fix as the app received it.
public struct GNSSFix: Equatable {
    /// When the receiver computed the fix (CLLocation.timestamp), seconds.
    public let time: TimeInterval
    public let position: FloorPoint
    /// Reported horizontal accuracy, meters: a ~68 % radius (CLLocation.horizontalAccuracy).
    /// Negative means the fix has no valid position.
    public let accuracy: Double
    /// Reported ground speed (Doppler), m/s; nil or negative when the receiver gave none.
    public let speed: Double?
    /// Course over ground, degrees clockwise from north; nil or negative when unknown.
    public let course: Double?
    /// Reported 1-sigma speed accuracy, m/s.
    public let speedAccuracy: Double?

    public init(time: TimeInterval, position: FloorPoint, accuracy: Double,
                speed: Double? = nil, course: Double? = nil, speedAccuracy: Double? = nil) {
        self.time = time
        self.position = position
        self.accuracy = accuracy
        self.speed = speed
        self.course = course
        self.speedAccuracy = speedAccuracy
    }

    /// 1-sigma error per axis. A 68 % radius of a circular normal error is 1.515 sigma.
    public var sigma: Double { accuracy / 1.515 }

    /// Reported velocity (east, north), m/s. A receiver that is barely moving often reports no
    /// course; below 0.5 m/s that counts as standing still.
    public var velocity: (x: Double, z: Double)? {
        guard let speed, speed >= 0, speed.isFinite else { return nil }
        guard let course, course >= 0, course.isFinite else { return speed < 0.5 ? (0, 0) : nil }
        let radians = course * Double.pi / 180
        return (speed * sin(radians), speed * cos(radians))
    }

    var isValid: Bool {
        time.isFinite && position.x.isFinite && position.z.isFinite && accuracy.isFinite && accuracy >= 0
    }
}

/// Displacement measured without GNSS (pedestrian dead reckoning or Core Motion) between `start`
/// and `end`, in the shared frame.
public struct InertialDisplacement: Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let dx: Double
    public let dz: Double
    /// 1-sigma random error of this increment per axis, meters. Heading and step-length bias,
    /// which do not average out, are allowed for by `GNSSIntegrityEngine.Options`.
    public let sigma: Double
    /// The phone was at rest (no steps, low acceleration variance) for the whole interval.
    public let stationary: Bool

    public init(start: TimeInterval, end: TimeInterval, dx: Double, dz: Double, sigma: Double, stationary: Bool = false) {
        self.start = start
        self.end = end
        self.dx = dx
        self.dz = dz
        self.sigma = sigma
        self.stationary = stationary
    }
}

/// Whether a piece of evidence is independent of GNSS.
public enum EvidenceOrigin: String, Codable, CaseIterable {
    /// A surveyed or hand-placed point (fixed beacon, landmark the user confirmed), or a position
    /// derived only from ranging to such points.
    case surveyed
    /// Comes, directly or through Bluetooth estimates, from some phone's GNSS. Shares GNSS
    /// common-mode errors, so it can object to a fix but never verify one.
    case gnssDerived
}

/// A peer heard directly over Bluetooth. Being heard bounds how far apart the two phones can be;
/// it says nothing about direction, so it can only catch a fix that is too far from the peer.
public struct PeerProximity: Equatable {
    public let time: TimeInterval
    public let peerId: String
    /// Where the peer is, by its own report.
    public let peerPosition: FloorPoint
    /// 1-sigma per axis of the peer's position, meters.
    public let peerSigma: Double
    public let origin: EvidenceOrigin
    /// Largest plausible distance to the peer given that it was heard, meters.
    public let maxRange: Double

    public init(time: TimeInterval, peerId: String, peerPosition: FloorPoint, peerSigma: Double,
                origin: EvidenceOrigin, maxRange: Double) {
        self.time = time
        self.peerId = peerId
        self.peerPosition = peerPosition
        self.peerSigma = peerSigma
        self.origin = origin
        self.maxRange = maxRange
    }

    /// Upper bound on the distance to a phone heard at `rssi`: where the signal would arrive
    /// `margin` standard deviations weaker than it did, capped where reception has all but faded.
    /// RSSI is too noisy for a range, but generous enough for a bound.
    public static func maxRange(rssi: Double, radio: RadioModel = .outdoors, margin: Double = 2.5) -> Double {
        min(radio.distance(forRSSI: rssi - margin * radio.sigma), radio.range + 4 * radio.soft)
    }
}

/// This phone's position estimated without its own GNSS (the positioning engine, a landmark the
/// user confirmed).
public struct PositionEvidence: Equatable {
    public let time: TimeInterval
    public let position: FloorPoint
    /// 1-sigma per axis, meters.
    public let sigma: Double
    public let origin: EvidenceOrigin
    /// What it was computed from (anchor and peer IDs), for the evidence trail.
    public let sources: [String]

    public init(time: TimeInterval, position: FloorPoint, sigma: Double, origin: EvidenceOrigin, sources: [String] = []) {
        self.time = time
        self.position = position
        self.sigma = sigma
        self.origin = origin
        self.sources = sources
    }
}

public enum GNSSIntegrityStatus: String, Codable, CaseIterable {
    /// No anomaly, and at least one check independent of GNSS agrees.
    case trusted
    /// No anomaly, but poor reported accuracy or an aging fix.
    case degraded
    /// Anomaly evidence: use only with inflated uncertainty, prefer other sources.
    case suspect
    /// Strong anomaly: do not use as a position or as an anchor for others.
    case rejected
    /// No fix, an invalid one, or one too old to use.
    case unavailable
    /// Self-consistent, but nothing independent of GNSS confirms it: a slow or common-mode error
    /// would go unnoticed.
    case insufficientEvidence

    public var isAnomaly: Bool { self == .suspect || self == .rejected }
    public var usableAsPosition: Bool { self == .trusted || self == .insufficientEvidence || self == .degraded }
}

public enum GNSSReasonCode: String, Codable, CaseIterable {
    case noFix, staleFix, invalidFix, timestampInconsistent
    case degradedAccuracy, accuracyInconsistent
    case impossibleSpeed, impossibleAcceleration, positionJump
    case inertialDisagreement, slowDrift
    case peerDisagreement, independentEvidenceDisagreement, peerEvidenceNotIndependent
    case insufficientEvidence, continuityLost, recovering
}

public enum GNSSCheck: String, Codable, CaseIterable {
    case freshness, accuracy, timing, speed, acceleration, jump, inertial
    case peerProximity, anchorProximity, positionEvidence

    /// Quality checks say how good a fix is; the others look for anomalies.
    public var isQuality: Bool { self == .freshness || self == .accuracy }
}

/// What could explain an anomaly. Spoofing is only ever one candidate among others.
public enum GNSSPossibleCause: String, Codable, CaseIterable {
    case signalObstruction, multipath, interference, receiverFault, clockOrDelivery
    case inertialSensorError, peerOrAnchorError, spoofing
}

/// One check's result.
public struct GNSSEvidence: Equatable, Codable {
    public let check: GNSSCheck
    /// 1 = consistent, 0 = full objection.
    public let score: Double
    public let observed: Double
    /// The observed value at which this check makes a fix suspect.
    public let threshold: Double
    public let unit: String
    /// The evidence does not depend on any GNSS receiver.
    public let independent: Bool
    public let detail: String
    /// Set when the score makes the fix suspect.
    public let reason: GNSSReasonCode?
}

public struct GNSSIntegrityUncertainty: Equatable {
    /// Share of the check families that had data to run, 0...1.
    public let coverage: Double
    /// Checks independent of GNSS that ran.
    public let independentChecks: Int
    /// The trust score could be this low if the independent checks that could not run had
    /// objected: 0 with none, half the score with only relative (inertial) or only absolute
    /// (anchor, position) evidence, the score itself with both. A coverage heuristic.
    public let trustLower: Double
    public let trustUpper: Double
    /// Smallest position offset the active independent checks would flag now, meters, in the
    /// worst direction. Absolute evidence (anchors, independent positions) bounds the whole offset;
    /// inertial motion only an offset built up within its longest window. nil: unbounded, a slow
    /// or common-mode error of any size could go unnoticed.
    public let minimumDetectableOffset: Double?
    /// Drift slower than this (m/s) stays inside the inertial check's tolerance however long it
    /// runs; only absolute evidence can catch it. nil without inertial motion.
    public let minimumDetectableDriftRate: Double?
    /// 1-sigma per axis the positioning engine should give this fix if it uses it; grows with
    /// the fix's age. nil when the fix must not be used.
    public let recommendedSigma: Double?
}

public struct GNSSIntegrityAssessment: Equatable {
    public let time: TimeInterval
    /// The fix that was judged; on a tick without a new fix, the latest one.
    public let fix: GNSSFix?
    public let status: GNSSIntegrityStatus
    /// 0...1.
    public let trustScore: Double
    public let reasons: [GNSSReasonCode]
    public let evidence: [GNSSEvidence]
    public let uncertainty: GNSSIntegrityUncertainty
    public let possibleCauses: [GNSSPossibleCause]
    /// One line for the UI, at most 160 characters, e.g. "GPS jumped 412 m in 1.0 s; not proof of
    /// an attack".
    public let summary: String
    /// The longer story: what was seen and what could have caused it.
    public let explanation: String

    public var isAnomaly: Bool { status.isAnomaly }
    public var usableAsPosition: Bool { status.usableAsPosition }
    /// Always false: phone data can show that a fix is anomalous, never that it was spoofed.
    public var spoofingConfirmed: Bool { false }
}

public final class GNSSIntegrityEngine {
    public struct Options: Equatable {
        /// Fastest plausible ground speed, m/s.
        public var maxSpeed = 7.0
        /// Largest plausible acceleration, m/s².
        public var maxAcceleration = 4.0
        /// Reported accuracy (68 % radius, m): full marks up to `goodAccuracy`, 0.4 at
        /// `poorAccuracy`, unusable beyond `unusableAccuracy`.
        public var goodAccuracy = 15.0
        public var poorAccuracy = 50.0
        public var unusableAccuracy = 100.0
        /// Fix age, s: full marks up to `freshAge`, unusable beyond `maxAge`.
        public var freshAge = 2.0
        public var maxAge = 30.0
        /// Normalised residuals (sigmas) where a check starts to doubt and where it fully objects.
        public var doubtSigma = 3.5
        public var rejectSigma = 7.0
        /// Inertial consistency windows, s. Long windows catch slow drift; the longest one bounds
        /// how old an offset can be and still be caught.
        public var inertialWindows: [TimeInterval] = [5, 15, 30, 60, 120, 300]
        /// Inertial heading bias allowed, degrees, and step-length (scale) bias, fraction.
        public var inertialHeadingBias = 10.0
        public var inertialScaleBias = 0.08
        /// Error floor of any inertial displacement, m.
        public var inertialFloor = 1.5
        /// Motion data may lag a fix by this much and still count, s; longer gaps break coverage.
        public var motionLatency = 1.0
        public var maxMotionGap = 3.0
        /// How fast our own position reference loosens with no motion data, 1-sigma m/s.
        public var unaidedGrowth = 0.5
        /// A fix is `trusted` only if the independent checks would catch an offset this large,
        /// meters (built up within the longest inertial window, or absolute).
        public var alertLimit = 50.0
        /// Reference looser than this (1-sigma m) when GNSS is taken back after a rejection
        /// cannot tell the real position from a new offset: continuity is lost.
        public var tightReference = 20.0
        /// Trust regained per second after an anomaly.
        public var recoveryRate = 0.1
        /// Peer and position evidence older than this (s) relative to the fix is ignored.
        public var evidenceMaxAge = 3.0
        /// How fast an aging fix goes out of date, m/s, for `recommendedSigma`.
        public var staleSpeed = 1.5
        /// Fixes kept for the accuracy-consistency check.
        public var consistencyFixes = 20
        /// Seconds of history kept.
        public var history: TimeInterval = 330

        public init() {}

        /// On foot (the default).
        public static let pedestrian = Options()

        /// In a vehicle.
        public static var vehicle: Options {
            var options = Options()
            options.maxSpeed = 70
            options.maxAcceleration = 8
            options.unaidedGrowth = 15
            options.staleSpeed = 25
            options.alertLimit = 100
            return options
        }
    }

    /// A check scoring below this makes a fix suspect; trust below `rejectBelow` rejects it, as
    /// does any single anomaly check at or below `hardReject`.
    public static let suspectBelow = 0.75
    public static let rejectBelow = 0.4
    public static let hardReject = 0.2
    /// Trust an anomaly has to climb back above before it clears.
    public static let clearAbove = 0.85

    public let options: Options
    public private(set) var latest: GNSSIntegrityAssessment?
    /// The latest fix that was usable as a position, with its assessment: what the positioning
    /// engine should treat as "last trusted GNSS".
    public private(set) var lastUsable: GNSSIntegrityAssessment?

    private struct TrackPoint {
        let time: TimeInterval
        let x: Double
        let z: Double
        let variance: Double
    }

    /// Where we expect this phone to be, independent of the newest fix: the last accepted fix
    /// carried forward by inertial motion (or loosened by `unaidedGrowth` without it).
    private struct Reference {
        var time: TimeInterval
        var x: Double
        var z: Double
        /// Random part, per axis.
        var variance: Double
        /// Inertial displacement since the last accepted fix; its bias does not average out.
        var deadReckonedX = 0.0
        var deadReckonedZ = 0.0
    }

    private struct CheckOutcome {
        let evidence: GNSSEvidence
        let reason: GNSSReasonCode?
        /// Offset this check would flag right now (independent checks only).
        let detectable: Double?
        /// Slowest drift this check would ever flag, m/s (inertial only).
        var driftRate: Double? = nil
        /// Absolute position evidence (anchor, position estimate) rather than relative motion.
        let absolute: Bool
    }

    private var lastFix: GNSSFix?
    private var previousFix: GNSSFix?
    private var accepted: [GNSSFix] = []
    private var reference: Reference?
    private var track: [TrackPoint] = []
    private var trackStart: TimeInterval?
    private var peers: [String: PeerProximity] = [:]
    private var positionEvidence: [EvidenceOrigin: PositionEvidence] = [:]
    private var normalizedSquares: [Double] = []
    private var lastOutcomes: [CheckOutcome] = []
    private var lastAnomalyRaw = 1.0
    private var anomalyTrust = 1.0
    private var lastAssessedAt: TimeInterval?
    private var continuityLost = false

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: Inputs

    public func addMotion(_ motion: InertialDisplacement) {
        guard motion.end > motion.start, motion.dx.isFinite, motion.dz.isFinite,
              motion.sigma.isFinite, motion.sigma >= 0 else { return }
        if let last = track.last {
            if motion.start < last.time - 0.05 { return }
            if motion.start - last.time > options.maxMotionGap {
                trackStart = motion.start
                track.append(TrackPoint(time: motion.start, x: last.x, z: last.z, variance: last.variance))
            }
        } else {
            trackStart = motion.start
            track.append(TrackPoint(time: motion.start, x: 0, z: 0, variance: 0))
        }
        let last = track[track.count - 1]
        track.append(TrackPoint(time: motion.end, x: last.x + motion.dx, z: last.z + motion.dz,
                                variance: last.variance + motion.sigma * motion.sigma))
        let horizon = motion.end - options.history
        if let index = track.firstIndex(where: { $0.time >= horizon }), index > 1 {
            track.removeFirst(index - 1)
            trackStart = max(trackStart ?? track[0].time, track[0].time)
        }
    }

    public func addPeer(_ peer: PeerProximity) {
        guard peer.peerPosition.x.isFinite, peer.peerPosition.z.isFinite, peer.maxRange.isFinite,
              peer.maxRange > 0, peer.peerSigma.isFinite, peer.peerSigma >= 0 else { return }
        if let known = peers[peer.peerId], known.time > peer.time { return }
        peers[peer.peerId] = peer
    }

    public func addPositionEvidence(_ evidence: PositionEvidence) {
        guard evidence.position.x.isFinite, evidence.position.z.isFinite,
              evidence.sigma.isFinite, evidence.sigma > 0 else { return }
        if let known = positionEvidence[evidence.origin], known.time > evidence.time { return }
        positionEvidence[evidence.origin] = evidence
    }

    public func reset() {
        latest = nil
        lastUsable = nil
        lastFix = nil
        previousFix = nil
        accepted = []
        reference = nil
        track = []
        trackStart = nil
        peers = [:]
        positionEvidence = [:]
        normalizedSquares = []
        lastOutcomes = []
        lastAnomalyRaw = 1
        anomalyTrust = 1
        lastAssessedAt = nil
        continuityLost = false
    }

    // MARK: Assessment

    /// Judges a new fix. `now` is when the app received it (defaults to the fix time); a fix that
    /// arrives late is judged stale.
    @discardableResult
    public func assess(_ fix: GNSSFix, at now: TimeInterval? = nil) -> GNSSIntegrityAssessment {
        let now = now ?? fix.time
        guard fix.isValid else { return assess(at: now, invalidFix: true) }
        if let lastFix, fix.time == lastFix.time, fix.position == lastFix.position {
            return assess(at: now)
        }

        var outcomes: [CheckOutcome] = [freshnessCheck(age: now - fix.time, fix: fix), accuracyCheck(fix)]
        var regressed = false
        if let timing = timingCheck(fix, now: now) {
            outcomes.append(timing)
            regressed = lastFix.map { fix.time < $0.time } ?? false
        }
        if !regressed {
            if let check = speedCheck(fix) { outcomes.append(check) }
            if let check = accelerationCheck(fix) { outcomes.append(check) }
            propagateReference(to: fix.time)
            if let check = jumpCheck(fix) { outcomes.append(check) }
            if let check = inertialCheck(fix) { outcomes.append(check) }
        }
        outcomes += proximityChecks(fix)
        outcomes += positionEvidenceChecks(fix)

        let anomalyRaw = outcomes.filter { !$0.evidence.check.isQuality }.map(\.evidence.score).min() ?? 1
        smoothTrust(raw: anomalyRaw, now: now)

        // Take the fix into our reference only if nothing objects to it. A rejected fix leaves
        // the reference running on inertial motion, so a persistent offset stays visible. Taking
        // GNSS back when the reference has grown loose (after an anomaly or an outage, the classic
        // jam-then-spoof opening) cannot tell the real position from a new offset.
        let consistent = !regressed && anomalyRaw >= Self.suspectBelow && fix.accuracy <= options.unusableAccuracy
        if consistent {
            if let reference, referenceVariance(reference).squareRoot() > options.tightReference {
                continuityLost = true
            }
            accept(fix)
        }
        if continuityLost, outcomes.contains(where: { $0.absolute && $0.evidence.independent && $0.evidence.score >= 0.9 }) {
            continuityLost = false
        }
        if !regressed {
            previousFix = lastFix
            lastFix = fix
        }
        lastOutcomes = outcomes
        lastAnomalyRaw = anomalyRaw
        return publish(fuse(now: now, fix: fix, outcomes: outcomes, anomalyRaw: anomalyRaw, forceReject: regressed))
    }

    /// Re-judges the latest fix at `now` without a new one: fixes that stop coming go stale.
    @discardableResult
    public func assess(at now: TimeInterval) -> GNSSIntegrityAssessment {
        assess(at: now, invalidFix: false)
    }

    private func assess(at now: TimeInterval, invalidFix: Bool) -> GNSSIntegrityAssessment {
        guard let lastFix else {
            return publish(unavailable(now: now, reason: invalidFix ? .invalidFix : .noFix, fix: nil,
                                       detail: invalidFix ? "GPS fix has no valid position" : "No GPS fix yet"))
        }
        var outcomes = lastOutcomes.filter { $0.evidence.check != .freshness }
        outcomes.insert(freshnessCheck(age: now - lastFix.time, fix: lastFix), at: 0)
        smoothTrust(raw: lastAnomalyRaw, now: now)
        return publish(fuse(now: now, fix: lastFix, outcomes: outcomes, anomalyRaw: lastAnomalyRaw, forceReject: false))
    }

    private func publish(_ assessment: GNSSIntegrityAssessment) -> GNSSIntegrityAssessment {
        latest = assessment
        if assessment.usableAsPosition { lastUsable = assessment }
        return assessment
    }

    private func smoothTrust(raw: Double, now: TimeInterval) {
        let dt = lastAssessedAt.map { max(0, now - $0) } ?? 0
        lastAssessedAt = max(lastAssessedAt ?? now, now)
        // Trust drops at once and climbs back at `recoveryRate`.
        anomalyTrust = min(raw, anomalyTrust + options.recoveryRate * dt)
    }

    private func accept(_ fix: GNSSFix) {
        let r = fix.sigma * fix.sigma
        if var reference {
            let variance = referenceVariance(reference)
            let gain = variance / (variance + r)
            reference.x += gain * (fix.position.x - reference.x)
            reference.z += gain * (fix.position.z - reference.z)
            reference.variance = max((1 - gain) * variance, 1)
            reference.time = fix.time
            reference.deadReckonedX = 0
            reference.deadReckonedZ = 0
            self.reference = reference
        } else {
            reference = Reference(time: fix.time, x: fix.position.x, z: fix.position.z, variance: max(r, 1))
        }
        accepted.append(fix)
        let horizon = fix.time - options.history
        if let index = accepted.firstIndex(where: { $0.time >= horizon }), index > 0 { accepted.removeFirst(index) }
    }

    // MARK: Fusion

    private func fuse(now: TimeInterval, fix: GNSSFix?, outcomes: [CheckOutcome], anomalyRaw: Double,
                      forceReject: Bool) -> GNSSIntegrityAssessment {
        guard let fix else { return unavailable(now: now, reason: .noFix, fix: nil, detail: "No GPS fix yet") }
        let age = now - fix.time
        if age > options.maxAge {
            return unavailable(now: now, reason: .staleFix, fix: fix,
                               detail: "Last GPS fix is \(Self.seconds(age)) old")
        }
        if fix.accuracy > options.unusableAccuracy {
            return unavailable(now: now, reason: .degradedAccuracy, fix: fix,
                               detail: "GPS accuracy \(Self.meters(fix.accuracy)): too coarse to use")
        }

        let quality = outcomes.filter { $0.evidence.check.isQuality }.map(\.evidence.score).min() ?? 1
        let anomalyOutcomes = outcomes.filter { !$0.evidence.check.isQuality }
        let independent = outcomes.filter { $0.evidence.independent }
        let detectable = independent.compactMap(\.detectable).min()
        let independentAgree = independent.contains { $0.evidence.score >= Self.suspectBelow }
        let bounded = (detectable ?? .infinity) <= options.alertLimit
        let dependentAgree = outcomes.contains {
            !$0.evidence.independent && [.peerProximity, .positionEvidence].contains($0.evidence.check)
                && $0.evidence.score >= Self.suspectBelow
        }

        let status: GNSSIntegrityStatus
        if forceReject || anomalyTrust < Self.rejectBelow || anomalyRaw <= Self.hardReject {
            status = .rejected
        } else if anomalyTrust < Self.suspectBelow || (latest?.status.isAnomaly == true && anomalyTrust < Self.clearAbove) {
            // Hysteresis: an anomaly clears only well above the line, so a borderline fix does not flap.
            status = .suspect
        } else if quality < Self.suspectBelow {
            status = .degraded
        } else if continuityLost || !independentAgree || !bounded {
            status = .insufficientEvidence
        } else {
            status = .trusted
        }

        var reasons: [GNSSReasonCode] = []
        func add(_ reason: GNSSReasonCode?) {
            if let reason, !reasons.contains(reason) { reasons.append(reason) }
        }
        for outcome in outcomes.sorted(by: { $0.evidence.score < $1.evidence.score })
        where outcome.evidence.score < Self.suspectBelow {
            add(outcome.reason)
        }
        if status.isAnomaly, !anomalyOutcomes.contains(where: { $0.evidence.score < Self.suspectBelow }) {
            add(.recovering)
        }
        if status == .insufficientEvidence {
            add(continuityLost ? .continuityLost : .insufficientEvidence)
            if dependentAgree && !independentAgree { add(.peerEvidenceNotIndependent) }
        }

        let trust = min(anomalyTrust, quality)
        let relative = independent.contains { !$0.absolute }
        let absolute = independent.contains { $0.absolute }
        let lower = (relative && absolute) ? trust : (relative || absolute) ? trust / 2 : 0
        let factor: Double? = switch status {
        case .trusted: 1
        case .insufficientEvidence: 1.5
        case .degraded: 2
        case .suspect: 4
        case .rejected, .unavailable: nil
        }
        let recommended = factor.map { $0 * fix.sigma + max(0, age) * options.staleSpeed }

        let causes = Self.causes(for: reasons)
        let evidence = outcomes.map(\.evidence)
        let text = Self.summary(status: status, outcomes: outcomes, causes: causes, dependentAgree: dependentAgree,
                                continuityLost: continuityLost, unboundedBy: bounded ? nil : detectable)
        return GNSSIntegrityAssessment(
            time: now, fix: fix, status: status, trustScore: trust, reasons: reasons, evidence: evidence,
            uncertainty: GNSSIntegrityUncertainty(
                coverage: Double(Set(evidence.map(\.check)).count) / Double(GNSSCheck.allCases.count),
                independentChecks: independent.count, trustLower: lower, trustUpper: trust,
                minimumDetectableOffset: detectable,
                minimumDetectableDriftRate: independent.compactMap(\.driftRate).min(), recommendedSigma: recommended),
            possibleCauses: causes, summary: text.summary, explanation: text.explanation)
    }

    private func unavailable(now: TimeInterval, reason: GNSSReasonCode, fix: GNSSFix?, detail: String) -> GNSSIntegrityAssessment {
        let causes = Self.causes(for: [reason])
        return GNSSIntegrityAssessment(
            time: now, fix: fix, status: .unavailable, trustScore: 0, reasons: [reason], evidence: [],
            uncertainty: GNSSIntegrityUncertainty(coverage: 0, independentChecks: 0, trustLower: 0, trustUpper: 0,
                                                  minimumDetectableOffset: nil, minimumDetectableDriftRate: nil,
                                                  recommendedSigma: nil),
            possibleCauses: causes, summary: Self.clipped(detail),
            explanation: "\(detail). Possible causes: \(Self.describe(causes)).")
    }

    static func causes(for reasons: [GNSSReasonCode]) -> [GNSSPossibleCause] {
        var causes: [GNSSPossibleCause] = []
        for reason in reasons {
            let candidates: [GNSSPossibleCause] = switch reason {
            case .noFix, .staleFix: [.signalObstruction, .interference, .receiverFault, .clockOrDelivery]
            case .invalidFix, .degradedAccuracy: [.signalObstruction, .multipath, .interference]
            case .accuracyInconsistent: [.multipath, .receiverFault, .spoofing]
            case .timestampInconsistent: [.clockOrDelivery, .receiverFault, .spoofing]
            case .impossibleSpeed, .impossibleAcceleration, .positionJump: [.multipath, .receiverFault, .spoofing]
            case .inertialDisagreement, .slowDrift: [.multipath, .inertialSensorError, .spoofing]
            case .peerDisagreement, .independentEvidenceDisagreement: [.multipath, .peerOrAnchorError, .spoofing]
            case .peerEvidenceNotIndependent, .insufficientEvidence, .continuityLost, .recovering: []
            }
            for cause in candidates where !causes.contains(cause) { causes.append(cause) }
        }
        return causes
    }

    /// The UI line (GPS wording, no attack wording beyond "not proof of an attack") and the longer
    /// explanation with the possible causes.
    private static func summary(status: GNSSIntegrityStatus, outcomes: [CheckOutcome], causes: [GNSSPossibleCause],
                                dependentAgree: Bool, continuityLost: Bool,
                                unboundedBy: Double?) -> (summary: String, explanation: String) {
        let worst = outcomes.min { $0.evidence.score < $1.evidence.score }
        let objection = worst.flatMap { $0.evidence.score < suspectBelow ? $0.evidence.detail : nil }
        let agreeing = outcomes.filter { $0.evidence.independent && $0.evidence.score >= suspectBelow }
        let summary: String
        var explanation: String
        switch status {
        case .trusted:
            let with = agreeing.map { outcome -> String in
                switch outcome.evidence.check {
                case .inertial: "steps and compass"
                case .anchorProximity: "a surveyed beacon"
                default: "an independent position"
                }
            }
            summary = "GPS agrees with \(with.first ?? "independent evidence")"
            explanation = "No check objects, and evidence that does not depend on GNSS agrees: "
                + agreeing.map(\.evidence.detail).joined(separator: "; ") + "."
        case .insufficientEvidence:
            if continuityLost {
                summary = "GPS consistent again after an anomaly; not re-verified yet"
                explanation = "GNSS is consistent again after an anomaly or outage, but our own reference had grown too loose to tell a real return from a new offset. A surveyed beacon or an independent position fix would re-verify it."
            } else if let unboundedBy {
                summary = "GPS agrees with steps, but a slow drift up to \(meters(unboundedBy)) could pass unseen"
                explanation = "Independent checks agree, but with the heading and step-length bias allowed they would miss an offset of up to \(meters(unboundedBy)) built up slowly."
            } else {
                summary = dependentAgree ? "GPS unchecked: peers agree, but they use GPS too"
                    : "GPS unchecked: nothing independent of GPS to compare with"
                explanation = "GNSS is self-consistent, but nothing independent of GNSS confirms it, so a slow or shared (common-mode) error would go unnoticed."
                    + (dependentAgree ? " Peers agree, but their positions come from GNSS too, so their agreement is not verification." : "")
            }
        case .degraded:
            summary = objection ?? "GPS quality is low"
            explanation = "Usable with a wider uncertainty: \(objection ?? "quality is low")."
        case .suspect, .rejected:
            if let objection {
                summary = "\(objection); not proof of an attack"
                explanation = "Anomaly: " + outcomes.filter { $0.evidence.score < suspectBelow }.map(\.evidence.detail)
                    .joined(separator: "; ") + ". This shows inconsistent GNSS, not its cause: \(describe(causes)) could each produce it."
            } else {
                summary = "GPS consistent again; trust recovering"
                explanation = "The checks pass again, but trust climbs back only slowly after an anomaly."
            }
        case .unavailable:
            summary = "No usable GPS fix"
            explanation = summary + "."
        }
        return (clipped(summary), explanation)
    }

    private static func describe(_ causes: [GNSSPossibleCause]) -> String {
        causes.isEmpty ? "unknown" : causes.map(\.rawValue).joined(separator: ", ")
    }

    /// The contract's text limit, in UTF-16 units.
    static func clipped(_ text: String, limit: Int = 160) -> String {
        guard text.utf16.count > limit else { return text }
        var result = ""
        for character in text {
            guard result.utf16.count + character.utf16.count <= limit - 1 else { break }
            result.append(character)
        }
        return result + "…"
    }

    // MARK: Checks

    private func score(sigmas n: Double) -> Double {
        Self.clamp01(1 - (n - options.doubtSigma) / (options.rejectSigma - options.doubtSigma))
    }

    /// Normalised residual at which a check's score falls to `suspectBelow`.
    private var suspectSigmas: Double {
        options.doubtSigma + (1 - Self.suspectBelow) * (options.rejectSigma - options.doubtSigma)
    }

    private func evidence(_ check: GNSSCheck, _ score: Double, observed: Double, threshold: Double, unit: String,
                          independent: Bool = false, detail: String, reason: GNSSReasonCode?,
                          detectable: Double? = nil, absolute: Bool = false) -> CheckOutcome {
        let reason = score < Self.suspectBelow ? reason : nil
        return CheckOutcome(evidence: GNSSEvidence(check: check, score: score, observed: observed, threshold: threshold,
                                                   unit: unit, independent: independent, detail: detail, reason: reason),
                            reason: reason, detectable: detectable, absolute: absolute)
    }

    private func freshnessCheck(age: TimeInterval, fix: GNSSFix) -> CheckOutcome {
        let fade = options.freshAge + 6
        let score = Self.ramp(age, [(options.freshAge, 1), (fade, 0.6), (options.maxAge, 0.3)])
        let threshold = options.freshAge + (fade - options.freshAge) * 0.25 / 0.4
        return evidence(.freshness, score, observed: max(0, age), threshold: threshold, unit: "s",
                        detail: "GPS fix \(Self.seconds(max(0, age))) old", reason: .staleFix)
    }

    private func accuracyCheck(_ fix: GNSSFix) -> CheckOutcome {
        let reported = Self.ramp(fix.accuracy, [(options.goodAccuracy, 1), (options.poorAccuracy, 0.4),
                                                (options.unusableAccuracy, 0.1)])
        let threshold = options.goodAccuracy + (options.poorAccuracy - options.goodAccuracy) * 0.25 / 0.6
        // Reported accuracy that the fixes themselves keep exceeding is not credible. Accepted
        // fixes against our reference should average 2 for squared per-axis normalised offsets.
        let meanSquare = normalizedSquares.count >= options.consistencyFixes / 2
            ? normalizedSquares.reduce(0, +) / Double(normalizedSquares.count) : nil
        let consistency = meanSquare.map { Self.ramp($0, [(8, 1), (18, 0.6), (50, 0.3)]) } ?? 1
        if consistency < reported, let meanSquare {
            return evidence(.accuracy, consistency, observed: (meanSquare / 2).squareRoot(), threshold: 2.5, unit: "x",
                            detail: "GPS scatters \(String(format: "%.1f", (meanSquare / 2).squareRoot()))x its stated \(Self.meters(fix.accuracy)) accuracy",
                            reason: .accuracyInconsistent)
        }
        return evidence(.accuracy, reported, observed: fix.accuracy, threshold: threshold, unit: "m",
                        detail: "GPS accuracy \(Self.meters(fix.accuracy))", reason: .degradedAccuracy)
    }

    private func timingCheck(_ fix: GNSSFix, now: TimeInterval) -> CheckOutcome? {
        if let lastFix, fix.time < lastFix.time {
            return evidence(.timing, 0, observed: lastFix.time - fix.time, threshold: 0, unit: "s",
                            detail: "GPS time went back \(Self.seconds(lastFix.time - fix.time))",
                            reason: .timestampInconsistent)
        }
        if fix.time > now + 2 {
            return evidence(.timing, 0.3, observed: fix.time - now, threshold: 2, unit: "s",
                            detail: "GPS time is \(Self.seconds(fix.time - now)) in the future",
                            reason: .timestampInconsistent)
        }
        return nil
    }

    private func speedCheck(_ fix: GNSSFix) -> CheckOutcome? {
        var excess = 0.0
        var detail = ""
        if let previous = lastFix, fix.time > previous.time, fix.time - previous.time <= 30 {
            let dt = fix.time - previous.time
            let distance = Self.distance(fix.position, previous.position)
            // Only the part of the move that position noise cannot explain counts.
            let noise = options.doubtSigma * (fix.sigma * fix.sigma + previous.sigma * previous.sigma).squareRoot()
            excess = max(0, distance - noise) / dt
            detail = "GPS moved \(Self.meters(distance)) in \(Self.seconds(dt))"
        }
        if let speed = fix.speed, speed.isFinite, speed >= 0 {
            let reported = max(0, speed - options.doubtSigma * (fix.speedAccuracy ?? 0.5))
            if reported > excess {
                excess = reported
                detail = "GPS reports \(Self.speed(speed))"
            }
        }
        guard !detail.isEmpty else { return nil }
        let score = excess <= options.maxSpeed ? 1 : Self.clamp01(1 - (excess - options.maxSpeed) / options.maxSpeed)
        return evidence(.speed, score, observed: excess, threshold: options.maxSpeed * (2 - Self.suspectBelow), unit: "m/s",
                        detail: detail,
                        reason: .impossibleSpeed)
    }

    private func accelerationCheck(_ fix: GNSSFix) -> CheckOutcome? {
        guard let previous = lastFix, fix.time > previous.time, fix.time - previous.time <= 5 else { return nil }
        let dt = fix.time - previous.time
        let dv: Double
        let noise: Double
        if let v2 = fix.velocity, let v1 = previous.velocity {
            dv = hypot(v2.x - v1.x, v2.z - v1.z)
            noise = 2.squareRoot() * max(fix.speedAccuracy ?? 1, previous.speedAccuracy ?? 1, 0.3)
        } else if let first = previousFix, previous.time > first.time, previous.time - first.time <= 5 {
            let dt1 = previous.time - first.time
            let v1x = (previous.position.x - first.position.x) / dt1, v1z = (previous.position.z - first.position.z) / dt1
            let v2x = (fix.position.x - previous.position.x) / dt, v2z = (fix.position.z - previous.position.z) / dt
            dv = hypot(v2x - v1x, v2z - v1z)
            // v2 - v1 = p2/dt - p1 (1/dt + 1/dt1) + p0/dt1, with independent errors per fix.
            let a = fix.sigma / dt, b = previous.sigma * (1 / dt + 1 / dt1), c = first.sigma / dt1
            noise = (a * a + b * b + c * c).squareRoot()
        } else {
            return nil
        }
        let excess = max(0, dv - options.doubtSigma * noise) / dt
        let score = excess <= options.maxAcceleration ? 1 : Self.clamp01(1 - (excess - options.maxAcceleration) / options.maxAcceleration)
        return evidence(.acceleration, score, observed: excess, threshold: options.maxAcceleration * (2 - Self.suspectBelow),
                        unit: "m/s²", detail: "GPS velocity changed \(Self.speed(dv)) in \(Self.seconds(dt))",
                        reason: .impossibleAcceleration)
    }

    private func referenceVariance(_ reference: Reference) -> Double {
        let bias = Self.biasFraction(options)
        let deadReckoned = hypot(reference.deadReckonedX, reference.deadReckonedZ)
        return reference.variance + (bias * deadReckoned) * (bias * deadReckoned)
    }

    private func propagateReference(to time: TimeInterval) {
        guard var reference, time > reference.time else { return }
        if let from = trackPoint(at: reference.time), let to = trackPoint(at: time) {
            let dx = to.x - from.x, dz = to.z - from.z
            reference.x += dx
            reference.z += dz
            reference.deadReckonedX += dx
            reference.deadReckonedZ += dz
            reference.variance += max(0, to.variance - from.variance)
        } else {
            let sigma = reference.variance.squareRoot() + options.unaidedGrowth * (time - reference.time)
            reference.variance = sigma * sigma
        }
        reference.time = time
        self.reference = reference
    }

    /// Compares the fix with the last accepted one carried forward by inertial motion, allowing
    /// the dead-reckoned leg its heading and step-length bias. While fixes keep being rejected the
    /// leg keeps growing, so an offset that grows faster than the bias stays rejected.
    private func jumpCheck(_ fix: GNSSFix) -> CheckOutcome? {
        guard let reference else { return nil }
        let sigma = (reference.variance + fix.sigma * fix.sigma).squareRoot()
        let offset = hypot(fix.position.x - reference.x, fix.position.z - reference.z)
        let residual = Self.distanceOutsideBias(
            gx: fix.position.x - (reference.x - reference.deadReckonedX),
            gz: fix.position.z - (reference.z - reference.deadReckonedZ),
            ix: reference.deadReckonedX, iz: reference.deadReckonedZ,
            maxAngle: options.inertialHeadingBias * Double.pi / 180, maxScale: options.inertialScaleBias)
        let n = residual / sigma
        // Feeds the accuracy-consistency check, but only from fixes we would take.
        if n < options.doubtSigma {
            let normalised = offset / (max(fix.sigma, 0.5))
            normalizedSquares.append(min(normalised * normalised, 200))
            if normalizedSquares.count > options.consistencyFixes { normalizedSquares.removeFirst() }
        }
        let leg = hypot(reference.deadReckonedX, reference.deadReckonedZ)
        return evidence(.jump, score(sigmas: n), observed: residual, threshold: suspectSigmas * sigma, unit: "m",
                        detail: "GPS \(Self.meters(offset)) from where \(leg < 0.5 ? "the last good fix" : "steps") put us",
                        reason: .positionJump)
    }

    private func inertialCheck(_ fix: GNSSFix) -> CheckOutcome? {
        guard let trackStart, let current = trackPoint(at: fix.time) else { return nil }
        let angle = options.inertialHeadingBias * Double.pi / 180
        var worst: (n: Double, residual: Double, sigma: Double, window: TimeInterval, gnss: Double, inertial: Double)?
        // A slow drift is caught by the longest window or not at all, so that one sets the bound.
        var longest: (window: TimeInterval, reach: Double)?
        for window in options.inertialWindows {
            let start = fix.time - window
            guard start >= trackStart - 0.5, let base = acceptedFix(near: start, tolerance: max(1.5, 0.05 * window)),
                  base.time >= trackStart - 0.5, let then = trackPoint(at: base.time) else { continue }
            let gx = fix.position.x - base.position.x, gz = fix.position.z - base.position.z
            let ix = current.x - then.x, iz = current.z - then.z
            let residual = Self.distanceOutsideBias(gx: gx, gz: gz, ix: ix, iz: iz, maxAngle: angle, maxScale: options.inertialScaleBias)
            let sigma = (fix.sigma * fix.sigma + base.sigma * base.sigma + max(0, current.variance - then.variance)
                         + options.inertialFloor * options.inertialFloor).squareRoot()
            let n = residual / sigma
            if worst == nil || n > worst!.n {
                worst = (n, residual, sigma, window, hypot(gx, gz), hypot(ix, iz))
            }
            let reach = suspectSigmas * sigma + hypot(ix, iz) * max(sin(angle), options.inertialScaleBias)
            if window >= (longest?.window ?? 0) { longest = (window, reach) }
        }
        guard let worst, let longest else { return nil }
        let score = score(sigmas: worst.n)
        // Caught only by the long windows: a slow drift rather than a jump.
        let reason: GNSSReasonCode = worst.window >= 60 && score < Self.suspectBelow ? .slowDrift : .inertialDisagreement
        let detail = worst.inertial < 0.5
            ? "Phone still, but GPS moved \(Self.meters(worst.gnss)) in \(Self.seconds(worst.window))"
            : "GPS moved \(Self.meters(worst.gnss)), steps say \(Self.meters(worst.inertial)) in \(Self.seconds(worst.window))"
        var outcome = evidence(.inertial, score, observed: worst.residual, threshold: suspectSigmas * worst.sigma, unit: "m",
                               independent: true, detail: detail, reason: reason, detectable: longest.reach)
        outcome.driftRate = longest.reach / longest.window
        return outcome
    }

    private func proximityChecks(_ fix: GNSSFix) -> [CheckOutcome] {
        let recent = peers.values.filter { abs($0.time - fix.time) <= options.evidenceMaxAge }.sorted { $0.peerId < $1.peerId }
        var outcomes: [CheckOutcome] = []
        for origin in EvidenceOrigin.allCases {
            let group = recent.filter { $0.origin == origin }
            guard !group.isEmpty else { continue }
            let scored = group.map { peer -> (score: Double, distance: Double, allowed: Double, slack: Double, id: String) in
                let distance = Self.distance(fix.position, peer.peerPosition)
                let allowed = peer.maxRange + options.doubtSigma * (fix.sigma * fix.sigma + peer.peerSigma * peer.peerSigma).squareRoot()
                let slack = max(20, 0.5 * peer.maxRange)
                let score = distance <= allowed ? 1 : Self.clamp01(1 - (distance - allowed) / slack)
                return (score, distance, allowed, slack, peer.peerId)
            }.sorted { $0.score < $1.score }
            // With three or more, one faulty peer cannot condemn the fix: the median decides.
            let pick = scored.count >= 3 ? scored[scored.count / 2] : scored[0]
            let objecting = scored.filter { $0.score < Self.suspectBelow }.count
            let independent = origin == .surveyed
            let who = independent ? "beacon" : "peer"
            let detail = objecting == 0
                ? "GPS within Bluetooth range of \(scored.count) \(who)\(scored.count == 1 ? "" : "s")"
                : "GPS \(Self.meters(pick.distance)) from \(who) \(pick.id), in Bluetooth range"
            outcomes.append(evidence(independent ? .anchorProximity : .peerProximity, pick.score, observed: pick.distance,
                                     threshold: pick.allowed + (1 - Self.suspectBelow) * pick.slack, unit: "m",
                                     independent: independent, detail: detail,
                                     reason: independent ? .independentEvidenceDisagreement : .peerDisagreement,
                                     detectable: independent ? pick.allowed : nil, absolute: true))
        }
        return outcomes
    }

    private func positionEvidenceChecks(_ fix: GNSSFix) -> [CheckOutcome] {
        EvidenceOrigin.allCases.compactMap { origin in
            guard let estimate = positionEvidence[origin], abs(estimate.time - fix.time) <= options.evidenceMaxAge else { return nil }
            let sigma = (fix.sigma * fix.sigma + estimate.sigma * estimate.sigma).squareRoot()
            let offset = Self.distance(fix.position, estimate.position)
            let independent = origin == .surveyed
            return evidence(.positionEvidence, score(sigmas: offset / sigma), observed: offset, threshold: suspectSigmas * sigma,
                            unit: "m", independent: independent,
                            detail: "GPS \(Self.meters(offset)) from the \(independent ? "independent" : "peer-based") position estimate",
                            reason: independent ? .independentEvidenceDisagreement : .peerDisagreement,
                            detectable: independent ? suspectSigmas * sigma : nil, absolute: true)
        }
    }

    // MARK: History

    private func acceptedFix(near time: TimeInterval, tolerance: TimeInterval) -> GNSSFix? {
        var best: GNSSFix?
        for fix in accepted.reversed() {
            if fix.time < time - tolerance { break }
            if abs(fix.time - time) <= tolerance, best.map({ abs(fix.time - time) < abs($0.time - time) }) ?? true {
                best = fix
            }
        }
        return best
    }

    /// Cumulative inertial displacement at `time`, interpolated; nil outside unbroken coverage.
    private func trackPoint(at time: TimeInterval) -> TrackPoint? {
        guard let trackStart, let last = track.last, time >= trackStart - 0.5,
              time <= last.time + options.motionLatency else { return nil }
        if time >= last.time { return last }
        if time <= track[0].time { return track[0] }
        var low = 0, high = track.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if track[mid].time <= time { low = mid } else { high = mid }
        }
        let a = track[low], b = track[high]
        let f = b.time > a.time ? (time - a.time) / (b.time - a.time) : 0
        return TrackPoint(time: time, x: a.x + f * (b.x - a.x), z: a.z + f * (b.z - a.z),
                          variance: a.variance + f * (b.variance - a.variance))
    }

    // MARK: Helpers

    static func biasFraction(_ options: Options) -> Double {
        hypot(sin(options.inertialHeadingBias * Double.pi / 180), options.inertialScaleBias)
    }

    /// Distance from the GNSS displacement `g` to the set of vectors s·R(θ)·i with |θ| ≤ maxAngle
    /// and |s − 1| ≤ maxScale: what is left of it once the inertial displacement `i` is allowed its
    /// heading and step-length bias.
    static func distanceOutsideBias(gx: Double, gz: Double, ix: Double, iz: Double, maxAngle: Double, maxScale: Double) -> Double {
        let length = hypot(ix, iz), g = hypot(gx, gz)
        let inner = (1 - maxScale) * length, outer = (1 + maxScale) * length
        if length < 1e-9 { return g }
        if g < 1e-9 { return inner }
        var delta = atan2(gx, gz) - atan2(ix, iz)
        delta = abs(atan2(sin(delta), cos(delta)))
        if delta <= maxAngle { return max(0, inner - g, g - outer) }
        let beyond = delta - maxAngle
        let along = min(outer, max(inner, g * cos(beyond)))
        return max(0, g * g + along * along - 2 * g * along * cos(beyond)).squareRoot()
    }

    static func ramp(_ x: Double, _ points: [(Double, Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 1 }
        if x <= first.0 { return first.1 }
        for (a, b) in zip(points, points.dropFirst()) where x <= b.0 {
            return a.1 + (b.1 - a.1) * (x - a.0) / (b.0 - a.0)
        }
        return last.1
    }

    static func clamp01(_ value: Double) -> Double { max(0, min(1, value)) }

    static func distance(_ a: FloorPoint, _ b: FloorPoint) -> Double { hypot(a.x - b.x, a.z - b.z) }

    static func meters(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.1f km", value / 1000) : "\(Int(value.rounded())) m"
    }

    static func seconds(_ value: Double) -> String {
        value >= 120 ? "\(Int((value / 60).rounded())) min" : value < 10 ? String(format: "%.1f s", value) : "\(Int(value.rounded())) s"
    }

    static func speed(_ value: Double) -> String { "\(Int((value * 3.6).rounded())) km/h" }
}

// MARK: - GhostCore contract

/// GNSSIntegrityEngine behind the GhostCore contract (ARCHITECTURE.md): raw fixes, motion and
/// peer records come in as contract types, `IntegrityAssessment`s go out. Per pipeline step,
/// ingest motion, peers and this phone's own estimate first, then assess.
public final class GNSSIntegrityMonitor {
    public static let algorithm = "gnss-integrity@1"
    /// An assessment stays usable this long once handed on, seconds.
    public static let maxAge = 5.0

    public let subjectId: String
    public let frameId: String
    public let radio: RadioModel
    public let engine: GNSSIntegrityEngine
    public private(set) var latest: IntegrityAssessment?
    /// The engine's own assessment behind `latest`, with what the contract record leaves out
    /// (possible causes, explanation, recommended sigma).
    public private(set) var latestDetail: GNSSIntegrityAssessment?

    private var pendingFixes: [PositionEstimate] = []
    private var judgedFix: PositionEstimate?
    private var lastSimulatedInput: Double?

    public init(subjectId: String, frameId: String = GeoFrame.defaultFrameId,
                options: GNSSIntegrityEngine.Options = .pedestrian, radio: RadioModel = .outdoors) {
        self.subjectId = subjectId
        self.frameId = frameId
        self.radio = radio
        engine = GNSSIntegrityEngine(options: options)
    }

    /// 95 % radius to draw around this phone's GNSS position when it is shown (trusted, or
    /// "GPS (unchecked)"); nil when it must not be shown as a position.
    public var displayR95: Double? {
        latestDetail?.uncertainty.recommendedSigma.map(PositionUncertainty.r95(fromSigma:))
    }

    // MARK: Inputs

    /// Queues a raw fix (method gnss, this phone); it is judged at the next assess.
    public func ingest(fix: PositionEstimate) {
        guard fix.subjectId == subjectId, fix.frameId == frameId, fix.kind == .measured, fix.method == .gnss,
              fix.position != nil else { return }
        if pendingFixes.count == 16 { pendingFixes.removeFirst() }
        pendingFixes.append(fix)
    }

    public func ingest(motion: MotionObservation) {
        guard motion.subjectId == subjectId, motion.frameId == frameId,
              let displacement = motion.displacement ?? (motion.stationary ? FloorVector(x: 0, z: 0) : nil) else { return }
        let sigma = motion.uncertainty.displacementR95.map { $0 / PositionUncertainty.sigmaTo95 }
            ?? 0.1 + 0.05 * displacement.length
        engine.addMotion(InertialDisplacement(start: motion.timestamp - motion.interval, end: motion.timestamp,
                                              dx: displacement.x, dz: displacement.z, sigma: max(sigma, 0.02),
                                              stationary: motion.stationary))
        noteSimulated(motion.provenance, at: motion.timestamp)
    }

    /// A peer this phone hears directly, with that peer's latest position: being heard bounds how
    /// far apart the two can be. Skipped when the peer's own GNSS is suspect or rejected, when its
    /// position came from this phone (circular), or when it is only a prediction.
    public func ingest(peer observation: PeerObservation, peerPosition: PositionEstimate,
                       peerStatus: IntegrityAssessment.Status? = nil) {
        guard observation.observerId == subjectId, let peerId = observation.peerId, peerPosition.subjectId == peerId,
              observation.frameId == frameId, peerPosition.frameId == frameId, observation.linkState != .lost,
              let position = peerPosition.position, [.measured, .estimated, .declared].contains(peerPosition.kind),
              !peerPosition.provenance.contains(device: subjectId),
              let rssi = observation.smoothedRSSI ?? Self.median(observation.rawRSSI) else { return }
        if let peerStatus, peerStatus == .suspect || peerStatus == .rejected { return }
        engine.addPeer(PeerProximity(
            time: observation.timestamp, peerId: peerId, peerPosition: FloorPoint(x: position.x, z: position.z),
            peerSigma: peerPosition.uncertainty.r95 / PositionUncertainty.sigmaTo95,
            origin: peerPosition.provenance.gnssDependent ? .gnssDerived : .surveyed,
            maxRange: PeerProximity.maxRange(rssi: rssi, radio: radio)))
        noteSimulated(observation.provenance, at: observation.timestamp)
        noteSimulated(peerPosition.provenance, at: observation.timestamp)
    }

    /// This phone placed without its own GNSS (Bluetooth estimate, UWB, a declared landmark).
    /// gnssDependent false makes it independent evidence; a ring, or one computed from this
    /// phone's own GNSS, is skipped.
    public func ingest(ownEstimate estimate: PositionEstimate) {
        guard estimate.subjectId == subjectId, estimate.frameId == frameId, estimate.method != .gnss,
              [.measured, .estimated, .declared].contains(estimate.kind), let position = estimate.position,
              !estimate.uncertainty.ambiguous,
              !estimate.provenance.inputs.contains(where: { $0.source == .gnss && $0.id == subjectId && $0.used })
        else { return }
        engine.addPositionEvidence(PositionEvidence(
            time: estimate.timestamp, position: FloorPoint(x: position.x, z: position.z),
            sigma: max(estimate.uncertainty.r95 / PositionUncertainty.sigmaTo95, 0.5),
            origin: estimate.provenance.gnssDependent ? .gnssDerived : .surveyed,
            sources: Array(estimate.provenance.contributors.prefix(4))))
        noteSimulated(estimate.provenance, at: estimate.timestamp)
    }

    // MARK: Assessment

    /// Judges a new raw fix (and any queued before it).
    @discardableResult
    public func assess(fix: PositionEstimate, now: Double) -> IntegrityAssessment {
        ingest(fix: fix)
        return assess(now: now)
    }

    /// Judges queued fixes, or re-judges the latest one when none arrived (fixes go stale).
    @discardableResult
    public func assess(now: Double) -> IntegrityAssessment {
        var result: (native: GNSSIntegrityAssessment, fix: PositionEstimate)?
        for fix in pendingFixes {
            guard let position = fix.position else { continue }
            noteSimulated(fix.provenance, at: fix.timestamp)
            let speed = fix.velocity?.length
            var course = fix.velocity.map { atan2($0.x, $0.z) * 180 / Double.pi }
            if let value = course, value < 0 { course = value + 360 }
            if let speed, speed < 0.3 { course = -1 }
            let native = engine.assess(GNSSFix(
                time: fix.timestamp, position: FloorPoint(x: position.x, z: position.z),
                accuracy: fix.uncertainty.r95 * PositionUncertainty.sigmaTo68 / PositionUncertainty.sigmaTo95,
                speed: speed, course: course), at: now)
            if fix.timestamp >= judgedFix?.timestamp ?? -Double.infinity { judgedFix = fix }
            result = (native, fix)
        }
        pendingFixes = []
        if let result { return record(result.native, evaluated: result.fix, now: now) }
        return record(engine.assess(at: now), evaluated: judgedFix, now: now)
    }

    // MARK: GhostIntegrityEngine (the pipeline's protocol)

    /// `evidence`: estimates of this phone made without its GNSS, judged as by `ingest(ownEstimate:)`.
    public func assess(subjectId: String, evidence: [PositionEstimate], now: Double) -> IntegrityAssessment {
        guard subjectId == self.subjectId else {
            return IntegrityAssessment(subjectId: subjectId, timestamp: now, frameId: frameId, status: .unavailable,
                                       trustScore: 0, uncertainty: .init(lower: 0, upper: 0), reasons: [.noFix],
                                       summary: "No GPS fix", freshness: Freshness(maxAge: Self.maxAge),
                                       provenance: Provenance(producerId: subjectId, algorithm: Self.algorithm,
                                                              gnssDependent: true))
        }
        evidence.forEach { ingest(ownEstimate: $0) }
        return assess(now: now)
    }

    private func record(_ native: GNSSIntegrityAssessment, evaluated: PositionEstimate?, now: Double) -> IntegrityAssessment {
        let status = IntegrityAssessment.Status(rawValue: native.status.rawValue) ?? .unavailable
        let fix = status == .unavailable ? nil : evaluated
        let checks = Set(native.evidence.map(\.check))
        var inputs: [ProvenanceInput] = []
        if let evaluated {
            inputs.append(ProvenanceInput(source: .gnss, id: subjectId, age: max(0, now - evaluated.timestamp),
                                          used: fix != nil))
        }
        if checks.contains(.inertial) { inputs.append(ProvenanceInput(source: .inertial, id: subjectId)) }
        if checks.contains(.peerProximity) || checks.contains(.anchorProximity) { inputs.append(ProvenanceInput(source: .bluetooth)) }
        if checks.contains(.positionEvidence) { inputs.append(ProvenanceInput(source: .fusion)) }
        let simulated = (evaluated?.provenance.simulated ?? false)
            || lastSimulatedInput.map { now - $0 <= engine.options.history } ?? false
        let trust = GNSSIntegrityEngine.clamp01(native.trustScore)
        let assessment = IntegrityAssessment(
            subjectId: subjectId, timestamp: now, frameId: frameId, status: status, trustScore: trust,
            uncertainty: .init(lower: min(trust, max(0, native.uncertainty.trustLower)), upper: trust),
            reasons: native.reasons.compactMap { IntegrityAssessment.Reason(rawValue: $0.rawValue) },
            evidence: native.evidence.prefix(GhostCoreContract.maxEvidence).map { item in
                IntegrityAssessment.Evidence(
                    check: item.check.rawValue, observed: item.observed.isFinite ? item.observed : nil,
                    threshold: item.threshold.isFinite ? item.threshold : nil, unit: item.unit,
                    score: GNSSIntegrityEngine.clamp01(item.score), independent: item.independent,
                    reason: item.reason.flatMap { IntegrityAssessment.Reason(rawValue: $0.rawValue) })
            },
            evaluatedFix: fix,
            minimumDetectableOffsetMeters: native.uncertainty.minimumDetectableOffset.flatMap {
                $0 <= GhostCoreContract.maxRadius ? $0 : nil
            },
            summary: native.summary, source: .fusion, freshness: Freshness(maxAge: Self.maxAge),
            provenance: Provenance(producerId: subjectId, algorithm: Self.algorithm, inputs: inputs,
                                   gnssDependent: true, simulated: simulated))
        latest = assessment
        latestDetail = native
        return assessment
    }

    private func noteSimulated(_ provenance: Provenance, at time: Double) {
        if provenance.simulated { lastSimulatedInput = max(lastSimulatedInput ?? time, time) }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
