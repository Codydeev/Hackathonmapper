import Foundation

/// Ghost Mode: what we can honestly say about each phone between the moments it is observed.
///
/// While observations keep arriving a phone is `live`. When they stop it becomes a `ghost`: its
/// last observation stays as it was, and next to it a prediction that grows with time. After
/// `maxHorizon` it is `lost`: only the last observation is shown. When it is observed again the
/// prediction is checked against the observation (a `GhostRecovery`) and replaced by it.
public final class GhostTracker {
    public struct Config: Equatable {
        public var params: GhostMotionParams = .walking
        /// Seconds an observation counts as current.
        public var freshFor: Double = 5
        /// Seconds after the last observation when the prediction stops.
        public var maxHorizon: Double = 600
        /// Recovery further than this (squared Mahalanobis, 99.9% for 2 degrees of freedom; as a
        /// level for heavy tails) from the prediction restarts the track at the observation
        /// instead of blending the two.
        public var gate: Double = 13.82
        /// `confidence` is the chance the phone is within this many metres of the centre.
        public var confidenceRadius: Double = 25
        /// Recoveries the online calibration looks back over, and how many it needs to act.
        public var calibrationWindow = 20
        public var calibrationMinimum = 8
        /// Observations kept per phone, for provenance.
        public var keepObservations = 16

        public init() {}
    }

    public let config: Config
    /// Process-noise multiplier from online calibration, 1 when predictions hold what they promise.
    public private(set) var inflation: Double = 1
    /// Most recent recoveries, oldest first (at most 100).
    public private(set) var recoveries: [GhostRecovery] = []
    private var tracks: [String: Track] = [:]
    private var levels: [Double] = []

    private struct Track {
        var filter: GhostKalman
        var observations: [GhostObservation]
        var lastHint: Double?
        var last: GhostObservation { observations[observations.count - 1] }
    }

    public init(config: Config = Config()) {
        self.config = config
    }

    public var ids: [String] { tracks.keys.sorted() }

    public func lastObservation(of id: String) -> GhostObservation? { tracks[id]?.last }

    /// The observations behind the current estimate, oldest first.
    public func observations(of id: String) -> [GhostObservation] { tracks[id]?.observations ?? [] }

    /// Folds in a trusted observation. Returns the recovery check if the phone was out of sight.
    /// Observations older than or as old as the newest one already folded in are ignored (relays
    /// deliver late copies); they return nil and change nothing.
    @discardableResult
    public func observe(_ id: String, _ o: GhostObservation) -> GhostRecovery? {
        guard o.x.isFinite, o.z.isFinite, o.t.isFinite, o.sigma.isFinite else { return nil }
        guard var track = tracks[id] else {
            var filter = GhostKalman(first: o, params: config.params)
            filter.inflation = inflation
            tracks[id] = Track(filter: filter, observations: [o])
            return nil
        }
        guard o.t > track.last.t else { return nil }
        let gap = o.t - track.last.t
        var recovery: GhostRecovery?
        let predicted = track.filter.belief(at: o.t)
        let level = track.filter.innovationLevel(for: o)
        let restart = level > -expm1(-0.5 * config.gate)
        if gap > config.freshFor {
            let inside = gap <= config.maxHorizon
            let r95 = inside ? predicted.circleRadius(level: 0.95) : nil
            let error = hypot(o.x - predicted.x, o.z - predicted.z)
            recovery = GhostRecovery(
                id: id, t: o.t, gap: gap, predictedX: predicted.x, predictedZ: predicted.z,
                predictedR95: r95, observedX: o.x, observedZ: o.z, observedSource: o.source, error: error,
                level: inside ? level : nil,
                insideR95: r95.map { error <= $0 },
                action: restart || !inside ? .restarted : .fused)
        }
        if restart || gap > config.maxHorizon {
            track.filter = GhostKalman(first: o, params: config.params)
            track.filter.inflation = inflation
        } else {
            track.filter.update(o)
        }
        track.observations.append(o)
        if track.observations.count > config.keepObservations {
            track.observations.removeFirst(track.observations.count - config.keepObservations)
        }
        tracks[id] = track
        if let recovery {
            record(recovery)
        }
        return recovery
    }

    /// The phone's own motion sensors while it has no position. Hints older than the last
    /// update are ignored.
    public func motion(_ id: String, _ hint: GhostMotionHint) {
        guard var track = tracks[id], hint.t >= track.filter.t else { return }
        track.filter.apply(hint)
        track.lastHint = hint.t
        tracks[id] = track
    }

    public func forget(_ id: String) {
        tracks[id] = nil
    }

    public func reset() {
        tracks = [:]
        recoveries = []
        levels = []
        inflation = 1
    }

    /// What to show for one phone at local time `now`.
    public func estimate(_ id: String, at now: Double) -> GhostEstimate? {
        guard let track = tracks[id] else { return nil }
        let last = track.last
        // A clock that runs behind the observation must not make the age negative.
        let age = max(0, now - last.t)
        let status: GhostStatus = age <= config.freshFor ? .live : (age <= config.maxHorizon ? .ghost : .lost)
        guard status != .lost else {
            return GhostEstimate(id: id, t: now, status: .lost, basis: .extrapolated, lastObserved: last,
                                 age: age, belief: nil, r50: nil, r90: nil, r95: nil, confidence: 0)
        }
        let belief = track.filter.belief(at: max(now, last.t))
        let basis: GhostBasis
        if status == .live {
            basis = .observed
        } else if let hint = track.lastHint, hint > last.t, now - hint <= config.freshFor {
            basis = .deadReckoned
        } else {
            basis = .extrapolated
        }
        return GhostEstimate(
            id: id, t: now, status: status, basis: basis, lastObserved: last, age: age, belief: belief,
            r50: belief.circleRadius(level: 0.5), r90: belief.circleRadius(level: 0.9),
            r95: belief.circleRadius(level: 0.95), confidence: belief.mass(within: config.confidenceRadius))
    }

    public func estimates(at now: Double) -> [GhostEstimate] {
        ids.compactMap { estimate($0, at: now) }
    }

    /// How recoveries compared with the predicted areas so far.
    public var calibration: GhostCalibration {
        let n = Double(levels.count)
        return GhostCalibration(
            count: levels.count,
            coverage50: levels.isEmpty ? nil : Double(levels.filter { $0 <= 0.5 }.count) / n,
            coverage90: levels.isEmpty ? nil : Double(levels.filter { $0 <= 0.9 }.count) / n,
            inflation: inflation)
    }

    /// Keeps the last recoveries and widens (or, slowly, narrows) future predictions when the
    /// 90% area held the phone clearly less (or more) often than 90% of the time.
    private func record(_ recovery: GhostRecovery) {
        recoveries.append(recovery)
        if recoveries.count > 100 { recoveries.removeFirst() }
        guard let level = recovery.level else { return }
        levels.append(level)
        if levels.count > config.calibrationWindow { levels.removeFirst() }
        guard levels.count >= config.calibrationMinimum, let c = calibration.coverage90 else { return }
        if c < 0.8 {
            inflation = min(4, inflation * 1.25)
        } else if c > 0.97 {
            inflation = max(1, inflation / 1.1)
        } else {
            return
        }
        for id in tracks.keys { tracks[id]?.filter.inflation = inflation }
    }
}

public enum GhostStatus: String, Codable {
    /// Observed within `freshFor`: the position shown is a measurement.
    case live
    /// Not observed lately: last observation plus a prediction, never a live position.
    case ghost
    /// Gone longer than `maxHorizon`: only the last observation.
    case lost
}

public enum GhostBasis: String, Codable {
    case observed
    /// Motion model only: nothing new is known about this phone since `lastObserved`.
    case extrapolated
    /// The phone's own steps and compass carried the estimate forward.
    case deadReckoned
}

public struct GhostEstimate: Equatable {
    public let id: String
    /// The local time this estimate is for.
    public let t: Double
    public let status: GhostStatus
    public let basis: GhostBasis
    /// Always shown as it was measured, with its own time and source.
    public let lastObserved: GhostObservation
    /// Seconds since `lastObserved`.
    public let age: Double
    /// Where the phone probably is now; nil when lost.
    public let belief: GhostBelief?
    /// Radii of circles around the belief's centre holding 50, 90 and 95% of it, metres.
    public let r50: Double?
    public let r90: Double?
    public let r95: Double?
    /// Chance the phone is within `Config.confidenceRadius` of the centre.
    public let confidence: Double

    public var isPrediction: Bool { status != .live }

    /// One line for people, e.g. "Predicted: last seen 1 min 12 s ago (Bluetooth), 95% within 64 m".
    public var summary: String {
        let seen = "last seen \(Self.duration(age)) ago (\(lastObserved.source.label))"
        switch status {
        case .live:
            return "Observed (\(lastObserved.source.label))"
        case .ghost:
            let how = basis == .deadReckoned ? "Dead reckoning" : "Predicted"
            return "\(how): \(seen), 95% within \(Int((r95 ?? 0).rounded())) m"
        case .lost:
            return "Lost: \(seen)"
        }
    }

    static func duration(_ s: Double) -> String {
        let s = Int(s.rounded())
        return s < 60 ? "\(s) s" : (s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s")
    }
}

/// A prediction checked against the observation that ended a gap.
public struct GhostRecovery: Equatable, Codable {
    public enum Action: String, Codable {
        /// The observation was where the prediction allowed: blended in.
        case fused
        /// Too far from the prediction (or the gap was too long): the track starts again there.
        case restarted
    }

    public let id: String
    public let t: Double
    /// Seconds without observations.
    public let gap: Double
    public let predictedX: Double
    public let predictedZ: Double
    public let predictedR95: Double?
    public let observedX: Double
    public let observedZ: Double
    public let observedSource: GhostObservation.Source
    /// Metres from the predicted centre to the observation.
    public let error: Double
    /// Mass of the smallest predicted ellipse reaching the observation, allowing for the
    /// observation's own error; uniform on 0...1 when predictions are calibrated. Nil after
    /// `maxHorizon`, when there was no prediction.
    public let level: Double?
    /// The observation fell inside the 95% circle shown on the map.
    public let insideR95: Bool?
    public let action: Action
}

public struct GhostCalibration: Equatable {
    public let count: Int
    /// Share of recoveries inside the predicted 50% / 90% areas.
    public let coverage50: Double?
    public let coverage90: Double?
    public let inflation: Double
}

extension GhostObservation.Source {
    var label: String {
        switch self {
        case .gps: return "GPS"
        case .bluetooth: return "Bluetooth"
        case .uwb: return "UWB"
        case .manual: return "set by hand"
        }
    }
}
