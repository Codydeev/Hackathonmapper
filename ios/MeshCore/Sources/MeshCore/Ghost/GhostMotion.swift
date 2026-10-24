import Foundation

/// A trusted position of one phone at one moment, in the shared floor frame (x east, z north,
/// metres). Only measurements go in here: never feed a Ghost Mode prediction back as an
/// observation, or the prediction would end up confirming itself.
public struct GhostObservation: Equatable, Codable {
    public enum Source: String, Codable {
        case gps, bluetooth, uwb, manual
    }

    /// When the position was true, in seconds on THIS phone's clock. For a relayed report use
    /// local receipt time minus its age at handoff; never subtract two phones' clocks.
    public let t: Double
    public let x: Double
    public let z: Double
    /// Standard deviation of the position along each axis, metres (about the 68% radius).
    public let sigma: Double
    public let source: Source
    /// Velocity measured with the position (GPS Doppler speed and course), if any.
    public let velocity: GhostVelocity?
    /// Where the position came from, carried into the provenance of predictions made from it.
    public let provenance: Provenance?
    /// The source said its belief is a ring or several spots: the position is not a good single guess.
    public let ambiguous: Bool

    public init(t: Double, x: Double, z: Double, sigma: Double, source: Source, velocity: GhostVelocity? = nil,
                provenance: Provenance? = nil, ambiguous: Bool = false) {
        self.t = t
        self.x = x
        self.z = z
        self.sigma = sigma
        self.source = source
        self.velocity = velocity
        self.provenance = provenance
        self.ambiguous = ambiguous
    }
}

/// Velocity in m/s along x (east) and z (north), with its standard deviation per axis.
public struct GhostVelocity: Equatable, Codable {
    public let vx: Double
    public let vz: Double
    public let sigma: Double

    public init(vx: Double, vz: Double, sigma: Double) {
        self.vx = vx
        self.vz = vz
        self.sigma = sigma
    }

    /// From a speed and a compass heading (radians clockwise from north), e.g. CLLocation's
    /// `speed` and `course`. The spread is split along and across the direction of travel and
    /// returned as the larger of the two, so it never claims more than it knows.
    public static func fromHeading(speed: Double, heading: Double, speedSigma: Double, headingSigma: Double) -> GhostVelocity {
        let across = speed * headingSigma
        return GhostVelocity(vx: speed * sin(heading), vz: speed * cos(heading), sigma: max(speedSigma, across))
    }
}

/// What the phone's own motion sensors say, while its position is unknown. Only the phone that
/// carries the sensors has these; a lost peer's sensors cannot reach anyone.
public struct GhostMotionHint: Equatable, Codable {
    public let t: Double
    /// Accelerometer says the phone is at rest (no steps, little variance).
    public let stationary: Bool
    /// Walking velocity from steps (CMPedometer pace) and heading (compass), if both are known.
    public let velocity: GhostVelocity?

    public init(t: Double, stationary: Bool, velocity: GhostVelocity? = nil) {
        self.t = t
        self.stationary = stationary
        self.velocity = velocity
    }
}

/// How Ghost Mode models walking. Fitted on training walks by `ghost/heldout` (never on the
/// held-out Hervanta walks it is scored on); see ghost/README.md for the numbers.
public struct GhostMotionParams: Equatable, Codable {
    public enum Kind: String, Codable {
        /// Velocity random walk (white acceleration): the textbook constant-velocity filter.
        case constantVelocity
        /// Velocity that is forgotten over `persistence` seconds (Ornstein–Uhlenbeck): people
        /// turn and stop, so long gaps grow like a random walk instead of quadratically.
        case meanReverting
    }

    public var kind: Kind
    /// Per-axis standard deviation of walking velocity, m/s (mean-reverting), or the
    /// acceleration noise density, m/s^1.5 (constant velocity).
    public var motionNoise: Double
    /// Seconds over which a velocity is forgotten (mean-reverting only).
    public var persistence: Double
    /// Multipliers on the sigma a source reports: sources tend to over- or understate it.
    public var gpsSigmaScale: Double
    public var radioSigmaScale: Double
    /// Floor on any observation's sigma, metres.
    public var minSigma: Double
    /// Multiplier on the sigma of an `ambiguous` observation, on top of its source's scale.
    public var ambiguousSigmaScale: Double = 1
    /// Predictions are never sharper than the last position as the filter trusts it (reported
    /// sigma times the source's scale, when that is larger) instead of as the source reported it.
    public var floorAtTrustedSigma = false
    /// Prior per-axis velocity spread when a track starts, m/s.
    public var initialSpeedSigma: Double
    /// Dead reckoning drifts with distance walked, not with time: step length and compass errors
    /// persist. Per-axis spread added per metre walked on motion sensors since the last position.
    public var deadReckoningDrift: Double = 0.15
    /// Variance multipliers by seconds since the last position, so the 95% circle holds 95% of
    /// training walks (split conformal), one table per kind of source; interpolated in log time.
    /// Empty means 1. Not applied while motion sensors carry the estimate (the drift covers that).
    public var gpsCalibration: [HorizonScale] = []
    public var radioCalibration: [HorizonScale] = []

    public struct HorizonScale: Equatable, Codable {
        public let horizon: Double
        public let variance: Double

        public init(horizon: Double, variance: Double) {
            self.horizon = horizon
            self.variance = variance
        }
    }

    func calibration(for source: GhostObservation.Source, horizon h: Double) -> Double {
        let table = source == .gps ? gpsCalibration : radioCalibration
        guard let first = table.first, let last = table.last else { return 1 }
        if h <= first.horizon { return 1 + (first.variance - 1) * max(0, h) / first.horizon }
        if h >= last.horizon { return last.variance }
        let i = table.firstIndex { $0.horizon >= h }!
        let a = table[i - 1], b = table[i]
        let f = log(h / a.horizon) / log(b.horizon / a.horizon)
        return a.variance + f * (b.variance - a.variance)
    }

    public init(kind: Kind, motionNoise: Double, persistence: Double, gpsSigmaScale: Double,
                radioSigmaScale: Double, minSigma: Double = 1, initialSpeedSigma: Double) {
        self.kind = kind
        self.motionNoise = motionNoise
        self.persistence = persistence
        self.gpsSigmaScale = gpsSigmaScale
        self.radioSigmaScale = radioSigmaScale
        self.minSigma = minSigma
        self.initialSpeedSigma = initialSpeedSigma
    }

    /// Fitted by `ghost/heldout/run.sh` on walks from the eight training areas, never on the
    /// held-out Hervanta walks (ghost/results/params.json). The calibration tables are each
    /// horizon's multiplier for the hardest training area.
    public static let walking: GhostMotionParams = {
        var p = GhostMotionParams(kind: .meanReverting, motionNoise: 0.749, persistence: 78.9, gpsSigmaScale: 0.228,
                                  radioSigmaScale: 1.221, initialSpeedSigma: 0.749)
        p.gpsCalibration = [.init(horizon: 5, variance: 0.709), .init(horizon: 10, variance: 2.292),
                            .init(horizon: 30, variance: 2.213), .init(horizon: 60, variance: 1.214),
                            .init(horizon: 120, variance: 0.934), .init(horizon: 180, variance: 0.948)]
        p.radioCalibration = [.init(horizon: 5, variance: 0.834), .init(horizon: 10, variance: 0.984),
                              .init(horizon: 30, variance: 1.798), .init(horizon: 60, variance: 1.231),
                              .init(horizon: 120, variance: 1.061), .init(horizon: 180, variance: 1.034)]
        p.floorAtTrustedSigma = true
        p.ambiguousSigmaScale = 2
        return p
    }()

    func sigma(for o: GhostObservation) -> Double {
        let scale = (o.source == .gps ? gpsSigmaScale : radioSigmaScale) * (o.ambiguous ? ambiguousSigmaScale : 1)
        return max(minSigma, o.sigma * scale)
    }

    /// The spread a prediction from `o` may never go below.
    func floorSigma(for o: GhostObservation) -> Double {
        floorAtTrustedSigma ? max(o.sigma, sigma(for: o)) : o.sigma
    }
}

/// Kalman filter over [x, z, vx, vz]. Feed it observations in time order, ask it where the phone
/// probably is at any later time.
public struct GhostKalman: Equatable {
    public private(set) var params: GhostMotionParams
    /// Time of the state below.
    public private(set) var t: Double
    /// State [x, z, vx, vz] and its covariance, row major 4 x 4.
    private(set) var s: [Double]
    private(set) var p: [Double]
    /// Multiplier on the process noise; the tracker raises it when recoveries land outside the
    /// predicted area more often than promised.
    public var inflation: Double = 1
    /// Metres walked on motion sensors alone since the last position (see `deadReckoningDrift`).
    public private(set) var deadReckoned: Double = 0
    /// The last position folded in: when, from what, and its reported sigma.
    public private(set) var observedAt: Double
    public private(set) var observedSource: GhostObservation.Source
    private var observedSigma: Double
    /// Motion sensors have spoken since the last position.
    private var hinted = false

    public init(first o: GhostObservation, params: GhostMotionParams) {
        self.params = params
        t = o.t
        observedAt = o.t
        observedSource = o.source
        observedSigma = params.floorSigma(for: o)
        let r = params.sigma(for: o)
        let v0 = params.initialSpeedSigma * params.initialSpeedSigma
        s = [o.x, o.z, 0, 0]
        p = [r * r, 0, 0, 0,
             0, r * r, 0, 0,
             0, 0, v0, 0,
             0, 0, 0, v0]
        if let v = o.velocity { updateVelocity(v) }
    }

    /// Position belief at `time` (never before the last update).
    public func position(at time: Double) -> GhostGaussian {
        var copy = self
        copy.advance(to: time)
        return copy.positionNow
    }

    public var positionNow: GhostGaussian {
        let drift = params.deadReckoningDrift * deadReckoned
        return GhostGaussian(x: s[0], z: s[1], xx: p[0] + drift * drift, xz: p[1], zz: p[5] + drift * drift)
    }

    public var velocityNow: (vx: Double, vz: Double) { (s[2], s[3]) }

    /// What to show for `time`: the filter's belief, calibrated for the time since the last
    /// position, and never sharper than that position was.
    public func belief(at time: Double) -> GhostBelief {
        let core = position(at: time)
        let m = hinted ? 1 : params.calibration(for: observedSource, horizon: max(0, time - observedAt))
        // Floor first so the calibration scales exactly what it was fitted on, then again so a
        // multiplier below 1 cannot undercut the observation.
        let floor = observedSigma * observedSigma
        return GhostBelief(core: GhostGaussian(x: core.x, z: core.z, xx: max(max(core.xx, floor) * m, floor),
                                               xz: core.xz * m, zz: max(max(core.zz, floor) * m, floor)))
    }

    /// Mass of the smallest predicted ellipse that reaches the observation, allowing for its own
    /// error: near 0 where expected, near 1 far out; uniform when the filter is calibrated.
    public func innovationLevel(for o: GhostObservation) -> Double {
        var g = belief(at: o.t).core
        let r = params.sigma(for: o)
        g.xx += r * r
        g.zz += r * r
        return g.level(x: o.x, z: o.z)
    }

    /// Belief about where the next observation will land: the position belief plus that
    /// observation's own error.
    public func innovation(for o: GhostObservation) -> GhostGaussian {
        var g = position(at: o.t)
        let r = params.sigma(for: o)
        g.xx += r * r
        g.zz += r * r
        return g
    }

    /// Moves the state forward; times in the past are ignored (the filter never runs backwards).
    public mutating func advance(to time: Double) {
        let dt = time - t
        guard dt > 0 else { return }
        let (a, b, qpp, qpv, qvv) = transition(dt)
        let q = inflation
        // State: position gains b * velocity, velocity decays by a.
        s = [s[0] + b * s[2], s[1] + b * s[3], a * s[2], a * s[3]]
        // P = F P F' + Q, F = [[I, bI], [0, aI]].
        var f = [Double](repeating: 0, count: 16)
        f[0] = 1; f[5] = 1; f[2] = b; f[7] = b; f[10] = a; f[15] = a
        p = Self.mul(Self.mul(f, p), Self.transpose(f))
        p[0] += q * qpp; p[5] += q * qpp
        p[2] += q * qpv; p[8] += q * qpv; p[7] += q * qpv; p[13] += q * qpv
        p[10] += q * qvv; p[15] += q * qvv
        t = time
    }

    /// Advances to the observation and folds it in. Returns the squared Mahalanobis distance of
    /// the observation from where the filter expected it (chi-square with 2 degrees of freedom
    /// when the filter is right).
    @discardableResult
    public mutating func update(_ o: GhostObservation) -> Double {
        advance(to: o.t)
        let r = params.sigma(for: o)
        // The drift is not in P, so it joins the position spread for this update only.
        let drift = params.deadReckoningDrift * deadReckoned
        p[0] += drift * drift
        p[5] += drift * drift
        deadReckoned = 0
        hinted = false
        observedAt = o.t
        observedSource = o.source
        observedSigma = params.floorSigma(for: o)
        let d2 = updatePosition(x: o.x, z: o.z, r2: r * r)
        if let v = o.velocity { updateVelocity(v) }
        return d2
    }

    /// Folds in a velocity measurement (GPS Doppler or steps + compass) at the current time.
    public mutating func updateVelocity(_ v: GhostVelocity) {
        let r2 = max(v.sigma, 0.05) * max(v.sigma, 0.05)
        update(rows: [2, 3], values: [v.vx, v.vz], r2: r2)
    }

    /// Motion sensors at time `hint.t`: at rest pins the velocity to zero, steps + heading give it.
    public mutating func apply(_ hint: GhostMotionHint) {
        let walked = hint.stationary ? 0 : hint.velocity.map { hypot($0.vx, $0.vz) * max(0, hint.t - t) } ?? 0
        deadReckoned += walked
        hinted = true
        advance(to: hint.t)
        if hint.stationary {
            update(rows: [2, 3], values: [0, 0], r2: 0.15 * 0.15)
        } else if let v = hint.velocity {
            updateVelocity(v)
        }
    }

    @discardableResult
    private mutating func updatePosition(x: Double, z: Double, r2: Double) -> Double {
        update(rows: [0, 1], values: [x, z], r2: r2)
    }

    /// Standard update for a measurement of two state entries with isotropic noise `r2`.
    @discardableResult
    private mutating func update(rows: [Int], values: [Double], r2: Double) -> Double {
        let i = rows[0], j = rows[1]
        let y0 = values[0] - s[i], y1 = values[1] - s[j]
        let s00 = p[i * 4 + i] + r2, s01 = p[i * 4 + j], s11 = p[j * 4 + j] + r2
        let det = max(s00 * s11 - s01 * s01, 1e-12)
        let inv00 = s11 / det, inv01 = -s01 / det, inv11 = s00 / det
        let d2 = y0 * (inv00 * y0 + inv01 * y1) + y1 * (inv01 * y0 + inv11 * y1)
        // K = P H' S^-1, a 4 x 2 matrix.
        var k = [Double](repeating: 0, count: 8)
        for r in 0..<4 {
            let pi = p[r * 4 + i], pj = p[r * 4 + j]
            k[r * 2] = pi * inv00 + pj * inv01
            k[r * 2 + 1] = pi * inv01 + pj * inv11
        }
        for r in 0..<4 { s[r] += k[r * 2] * y0 + k[r * 2 + 1] * y1 }
        // Joseph form keeps P symmetric and positive: (I - KH) P (I - KH)' + K R K'.
        var ikh = [Double](repeating: 0, count: 16)
        for r in 0..<4 {
            ikh[r * 4 + r] = 1
            ikh[r * 4 + i] -= k[r * 2]
            ikh[r * 4 + j] -= k[r * 2 + 1]
        }
        var np = Self.mul(Self.mul(ikh, p), Self.transpose(ikh))
        for r in 0..<4 {
            for c in 0..<4 { np[r * 4 + c] += r2 * (k[r * 2] * k[c * 2] + k[r * 2 + 1] * k[c * 2 + 1]) }
        }
        p = np
        return d2
    }

    /// Per-axis transition over `dt`: position += b * v, v *= a, and the process noise block
    /// [[qpp, qpv], [qpv, qvv]] for one axis.
    private func transition(_ dt: Double) -> (Double, Double, Double, Double, Double) {
        switch params.kind {
        case .constantVelocity:
            let q = params.motionNoise * params.motionNoise
            return (1, dt, q * dt * dt * dt / 3, q * dt * dt / 2, q * dt)
        case .meanReverting:
            let tau = params.persistence, s2 = params.motionNoise * params.motionNoise
            let u = dt / tau
            let oneMinusA = -expm1(-u)
            // Integrated Ornstein-Uhlenbeck: var of the travelled distance is
            // s2 tau^2 (2u - 3 + 4e^-u - e^-2u); its series avoids cancellation for small u.
            let core = u < 1e-2 ? u * u * u * (2.0 / 3 - u / 2 + 7 * u * u / 30)
                                : 2 * u - 3 + 4 * exp(-u) - exp(-2 * u)
            return (1 - oneMinusA, tau * oneMinusA, s2 * tau * tau * core,
                    s2 * tau * oneMinusA * oneMinusA, s2 * -expm1(-2 * u))
        }
    }

    private static func mul(_ a: [Double], _ b: [Double]) -> [Double] {
        var c = [Double](repeating: 0, count: 16)
        for r in 0..<4 {
            for k in 0..<4 {
                let v = a[r * 4 + k]
                if v == 0 { continue }
                for col in 0..<4 { c[r * 4 + col] += v * b[k * 4 + col] }
            }
        }
        return c
    }

    private static func transpose(_ a: [Double]) -> [Double] {
        var c = a
        for r in 0..<4 { for col in 0..<4 { c[col * 4 + r] = a[r * 4 + col] } }
        return c
    }
}

/// The plain baseline: keep going at the velocity of the last `window` seconds, with a spread
/// that grows from the last fix's error, a velocity error times the gap, and a random-walk term.
public struct GhostConstantVelocity: Equatable, Codable {
    /// Seconds of track the velocity is averaged over.
    public var window: Double
    /// Multiplier on the last observation's sigma for the starting spread.
    public var startScale: Double
    /// Velocity error per axis, m/s: spread grows by this times the gap.
    public var velocitySigma: Double
    /// Random-walk diffusion, m²/s: spread² also grows by this times the gap.
    public var diffusion: Double

    public init(window: Double, startScale: Double, velocitySigma: Double, diffusion: Double) {
        self.window = window
        self.startScale = startScale
        self.velocitySigma = velocitySigma
        self.diffusion = diffusion
    }

    /// Fitted by `ghost/heldout/run.sh` on mesh-quality history from the training areas
    /// (ghost/results/params.json).
    public static let walking = GhostConstantVelocity(window: 30, startScale: 1.13, velocitySigma: 0.86, diffusion: 0.8)

    /// `track` is oldest first. Returns nil for an empty track.
    public func predict(track: [GhostObservation], at time: Double) -> GhostGaussian? {
        guard let last = track.last else { return nil }
        var vx = 0.0, vz = 0.0
        if let ref = track.last(where: { last.t - $0.t >= window - 1e-6 }) ?? (track.count > 1 ? track.first : nil),
           last.t - ref.t > 0 {
            vx = (last.x - ref.x) / (last.t - ref.t)
            vz = (last.z - ref.z) / (last.t - ref.t)
        }
        let h = max(0, time - last.t)
        let s0 = startScale * last.sigma
        let var2 = s0 * s0 + velocitySigma * velocitySigma * h * h + diffusion * h
        return .isotropic(x: last.x + vx * h, z: last.z + vz * h, sigma: var2.squareRoot())
    }
}
