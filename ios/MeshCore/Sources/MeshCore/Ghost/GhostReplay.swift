import Foundation

/// A scripted Ghost Mode run: observations and motion hints at given times, the true paths, and
/// what must hold along the way. The scenarios in ghost/fixtures/ are the regression tests and
/// can also drive a demo with no phones moving.
public struct GhostScenario: Codable {
    public struct Event: Codable {
        /// Local time the event reaches the tracker.
        public let t: Double
        public let id: String
        public let observe: Observation?
        public let motion: Motion?
    }

    public struct Observation: Codable {
        public let x: Double
        public let z: Double
        public let sigma: Double
        public let source: GhostObservation.Source
        /// When the position was true relative to `t` (negative for a late relay); default 0.
        public let age: Double?
        public let vx: Double?
        public let vz: Double?
        public let velocitySigma: Double?
    }

    public struct Motion: Codable {
        public let stationary: Bool
        public let speed: Double?
        /// Radians clockwise from north.
        public let heading: Double?
        public let speedSigma: Double?
        public let headingSigma: Double?
    }

    /// Requirements at time `t` for phone `id`; absent fields are not checked.
    public struct Check: Codable {
        public let t: Double
        public let id: String
        public let status: GhostStatus?
        public let basis: GhostBasis?
        public let lastObservedT: Double?
        /// The true position (from `truth`) lies inside the 95% circle.
        public let truthInsideR95: Bool?
        public let r95Min: Double?
        public let r95Max: Double?
        public let confidenceMax: Double?
        /// A recovery happened at exactly `t` with this action / landing inside the 95% circle.
        public let recovery: GhostRecovery.Action?
        public let recoveryInsideR95: Bool?
        public let note: String?
    }

    public let name: String
    public let description: String
    public let freshFor: Double?
    public let maxHorizon: Double?
    public let events: [Event]
    /// True paths, [t, x, z] rows sorted by t, linearly interpolated.
    public let truth: [String: [[Double]]]?
    public let checks: [Check]
    /// Run until this time (default: the last event or check).
    public let end: Double?
}

public struct GhostReplayResult {
    public struct Sample: Equatable {
        public let t: Double
        public let id: String
        public let status: GhostStatus
        public let age: Double
        public let error: Double?
        public let r95: Double?
    }

    public let name: String
    public let failures: [String]
    /// One sample per phone with a true path, every second.
    public let samples: [Sample]
    public let recoveries: [GhostRecovery]

    /// Over the seconds a phone was a ghost with a known true position.
    public var ghostSeconds: Int { ghostSamples.count }
    public var ghostCoverageR95: Double? {
        ghostSamples.isEmpty ? nil : Double(ghostSamples.filter { $0.error! <= $0.r95! }.count) / Double(ghostSamples.count)
    }
    public var ghostMedianError: Double? {
        let e = ghostSamples.map { $0.error! }.sorted()
        return e.isEmpty ? nil : e[e.count / 2]
    }
    private var ghostSamples: [Sample] { samples.filter { $0.status == .ghost && $0.error != nil && $0.r95 != nil } }
}

public enum GhostReplay {
    public static func load(_ data: Data) throws -> GhostScenario {
        try JSONDecoder().decode(GhostScenario.self, from: data)
    }

    public static func run(_ s: GhostScenario, params: GhostMotionParams = .walking) -> GhostReplayResult {
        var config = GhostTracker.Config()
        config.params = params
        if let v = s.freshFor { config.freshFor = v }
        if let v = s.maxHorizon { config.maxHorizon = v }
        let tracker = GhostTracker(config: config)
        let events = s.events.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
        let end = s.end ?? max(events.last?.t ?? 0, s.checks.map(\.t).max() ?? 0)
        var failures: [String] = []
        var samples: [GhostReplayResult.Sample] = []
        var recoveries: [GhostRecovery] = []
        var next = 0
        var checks = s.checks.sorted { $0.t < $1.t }[...]

        func step(to now: Double) {
            while next < events.count && events[next].t <= now {
                let e = events[next]
                next += 1
                if let o = e.observe {
                    let velocity = o.vx.flatMap { vx in o.vz.map { GhostVelocity(vx: vx, vz: $0, sigma: o.velocitySigma ?? 0.5) } }
                    let obs = GhostObservation(t: e.t + (o.age ?? 0), x: o.x, z: o.z, sigma: o.sigma, source: o.source,
                                               velocity: velocity)
                    if let r = tracker.observe(e.id, obs) { recoveries.append(r) }
                }
                if let m = e.motion {
                    var velocity: GhostVelocity?
                    if let speed = m.speed, let heading = m.heading {
                        velocity = .fromHeading(speed: speed, heading: heading, speedSigma: m.speedSigma ?? 0.2,
                                                headingSigma: m.headingSigma ?? 0.35)
                    }
                    tracker.motion(e.id, GhostMotionHint(t: e.t, stationary: m.stationary, velocity: velocity))
                }
            }
        }

        var now = 0.0
        while now <= end + 1e-9 {
            step(to: now)
            while let c = checks.first, c.t <= now + 1e-9 {
                checks.removeFirst()
                failures += check(c, tracker: tracker, recoveries: recoveries, truth: s.truth)
            }
            for id in (s.truth ?? [:]).keys.sorted() {
                guard let e = tracker.estimate(id, at: now), let p = position(s.truth?[id], at: now) else { continue }
                let error = e.belief.map { hypot($0.x - p.x, $0.z - p.z) }
                samples.append(.init(t: now, id: id, status: e.status, age: e.age, error: error, r95: e.r95))
            }
            now += 1
        }
        for c in checks { failures.append("check at t=\(c.t) for \(c.id) never ran (after end \(end))") }
        return GhostReplayResult(name: s.name, failures: failures.map { "\(s.name): \($0)" }, samples: samples,
                                 recoveries: recoveries)
    }

    static func check(_ c: GhostScenario.Check, tracker: GhostTracker, recoveries: [GhostRecovery],
                      truth: [String: [[Double]]]?) -> [String] {
        var out: [String] = []
        let at = "t=\(c.t) \(c.id)\(c.note.map { " (\($0))" } ?? "")"
        if c.recovery != nil || c.recoveryInsideR95 != nil {
            if let r = recoveries.last(where: { $0.id == c.id && abs($0.t - c.t) < 1e-6 }) {
                if let want = c.recovery, r.action != want { out.append("\(at): recovery \(r.action), want \(want)") }
                if let want = c.recoveryInsideR95, r.insideR95 != want {
                    out.append("\(at): recovery insideR95 \(String(describing: r.insideR95)), want \(want)")
                }
            } else {
                out.append("\(at): no recovery")
            }
        }
        guard let e = tracker.estimate(c.id, at: c.t) else {
            return out + (c.status != nil ? ["\(at): no estimate"] : [])
        }
        if let s = c.status, e.status != s { out.append("\(at): status \(e.status), want \(s)") }
        if let b = c.basis, e.basis != b { out.append("\(at): basis \(e.basis), want \(b)") }
        if let t = c.lastObservedT, abs(e.lastObserved.t - t) > 1e-6 { out.append("\(at): lastObserved.t \(e.lastObserved.t), want \(t)") }
        if let lo = c.r95Min, (e.r95 ?? 0) < lo { out.append("\(at): r95 \(e.r95 ?? 0) < \(lo)") }
        if let hi = c.r95Max, (e.r95 ?? .infinity) > hi { out.append("\(at): r95 \(e.r95 ?? .infinity) > \(hi)") }
        if let hi = c.confidenceMax, e.confidence > hi { out.append("\(at): confidence \(e.confidence) > \(hi)") }
        if let want = c.truthInsideR95 {
            if let p = position(truth?[c.id], at: c.t), let b = e.belief, let r = e.r95 {
                let d = hypot(b.x - p.x, b.z - p.z)
                if (d <= r) != want { out.append("\(at): truth \(Int(d)) m from centre, r95 \(Int(r)) m, want inside=\(want)") }
            } else {
                out.append("\(at): no truth or no belief to compare")
            }
        }
        return out
    }

    static func position(_ path: [[Double]]?, at t: Double) -> (x: Double, z: Double)? {
        guard let path, let first = path.first, let last = path.last, t >= first[0], t <= last[0] else { return nil }
        var i = 0
        while i + 1 < path.count && path[i + 1][0] < t { i += 1 }
        let a = path[i], b = path[min(i + 1, path.count - 1)]
        let f = b[0] > a[0] ? (t - a[0]) / (b[0] - a[0]) : 0
        return (a[1] + f * (b[1] - a[1]), a[2] + f * (b[2] - a[2]))
    }
}
