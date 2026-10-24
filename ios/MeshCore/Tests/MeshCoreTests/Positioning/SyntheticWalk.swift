import Foundation
@testable import MeshCore

typealias PZ = Positioning

/// SplitMix64: repeatable synthetic worlds.
struct SimRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }

    mutating func next() -> Double {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }

    mutating func gauss() -> Double {
        let u = max(next(), 1e-12)
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * next())
    }

    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

/// A synthetic walk with every sensor the engine reads, generated from a known true track. The
/// "true" radio deliberately differs from the engine's default model (p0, n, per-phone offsets,
/// correlated shadowing, deep fades, body blocking), so the tests do not grade the model on its
/// own assumptions.
struct SyntheticWalk {
    struct AnchorSpec {
        var id: String
        var position: PZ.Vec2
        var kind: PZ.Anchor.Kind = .gnss
        /// Sigma the anchor reports (5 m GNSS accuracy -> 3.3 m per axis).
        var reportedSigma = 3.3
        /// Its actual position error (GNSS wander), per axis.
        var trueErrorSigma = 2.5
        /// Its radio reads this many dB stronger or weaker than the model.
        var rssiOffset = 0.0
    }

    struct Disturbance {
        var center: PZ.Vec2
        var radius: Double
        var bias: Double
        /// Whether the field-strength check notices it.
        var flagged: Bool
    }

    var seed: UInt64 = 1
    var duration: TimeInterval = 720
    /// GNSS fixes stop after this time (nil: GNSS throughout; 0: never).
    var gnssUntil: TimeInterval? = 120
    var start = PZ.Vec2(x: 0, z: 0)
    var waypoints: [PZ.Vec2] = [PZ.Vec2(x: 80, z: 0), PZ.Vec2(x: 80, z: 60), PZ.Vec2(x: 0, z: 60), PZ.Vec2(x: 0, z: 0)]
    var loop = true
    var pauses: [(start: TimeInterval, duration: TimeInterval)] = [(300, 20), (500, 15)]
    var initialHeading = Double.pi / 2

    var imuRate = 50.0
    var stepFrequency = 1.8
    var strideLength = 0.74
    /// Relative 1-sigma of slow stride changes (speeding up, slowing down) the accelerometer
    /// amplitude does not reveal, with a 20 s time constant.
    var strideVariation = 0.0
    var accelAmplitude = 0.3
    var carryOffset = PZ.degrees(8)
    var gyroBias = PZ.degrees(0.2)
    var gyroNoise = 0.01
    var withMotion = true

    var withCompass = true
    var compassRate = 10.0
    var compassNoise = PZ.degrees(5)
    var compassReportedSigma = PZ.degrees(8)
    var disturbances: [Disturbance] = [Disturbance(center: PZ.Vec2(x: 80, z: 30), radius: 12, bias: PZ.degrees(35), flagged: false)]

    var gnssWhite = 1.5
    var gnssCorrelated = 3.0
    var gnssTau = 30.0
    var gnssReportedAccuracy = 5.0

    var anchors: [AnchorSpec] = []
    var anchorReportLatency = 1.0
    var radioP0 = -58.0
    var radioN = 2.3
    var shadowSigma = 4.5
    var shadowDecorrelation = 5.0
    var fastSigma = 3.0
    var deepFadeProbability = 0.08
    var bodyLoss = 5.0
    var hearRange = 55.0
    var hearSoft = 6.0
    var advertisementRate = 5.0
    var sensitivity = -100.0

    var truthRate = 2.0

    struct Output {
        var records: [PZ.LogRecord]
        var truth: [(t: TimeInterval, p: PZ.Vec2)]
    }

    static func fourCornerAnchors(seed: UInt64) -> [AnchorSpec] {
        var r = SimRandom(seed: seed &+ 99)
        return [("anchor-s", 40.0, -8.0), ("anchor-e", 88.0, 30.0), ("anchor-n", 40.0, 68.0), ("anchor-w", -8.0, 30.0)].map {
            AnchorSpec(id: $0.0, position: PZ.Vec2(x: $0.1, z: $0.2), rssiOffset: 2 * r.gauss())
        }
    }

    func generate() -> Output {
        var rng = SimRandom(seed: seed)
        var records: [PZ.LogRecord] = [.header(selfId: "phone-b", frameId: "hervanta-v1", note: "synthetic seed \(seed)")]
        var truth: [(TimeInterval, PZ.Vec2)] = []

        var pos = start
        var theta = initialHeading
        var target = 0
        var phase = 0.0
        var walkedTotal = 0.0
        let dt = 1 / imuRate
        var prevDevice = theta - carryOffset
        var nextCompass = 0.0
        var nextGNSS = 0.0
        var nextTruth = 0.0
        var nextReport = 0.0
        var gnssError = PZ.Vec2(x: gnssCorrelated * rng.gauss(), z: gnssCorrelated * rng.gauss())
        var anchorErrors = anchors.map { a in PZ.Vec2(x: a.trueErrorSigma * rng.gauss(), z: a.trueErrorSigma * rng.gauss()) }
        var shadow = anchors.map { _ in shadowSigma * rng.gauss() }
        var shadowWalked = anchors.map { _ in 0.0 }
        var nextAdvert = anchors.indices.map { Double($0) / (advertisementRate * Double(max(1, anchors.count))) }
        var done = false
        var strideFactor = 1.0

        var t = 0.0
        while t <= duration {
            let paused = pauses.contains { t >= $0.start && t < $0.start + $0.duration }
            var speed = 0.0
            if !paused && !done {
                let goal = waypoints[target]
                let to = goal - pos
                if to.length < 1.5 {
                    if target + 1 < waypoints.count { target += 1 } else if loop { target = 0 } else { done = true }
                }
                let desired = atan2(to.x, to.z)
                let turn = PZ.wrap(desired - theta)
                let maxTurn = PZ.degrees(120) * dt
                theta = PZ.wrap(theta + max(-maxTurn, min(maxTurn, turn)))
                if strideVariation > 0 {
                    let a = exp(-dt / 20)
                    strideFactor = 1 + a * (strideFactor - 1) + (1 - a * a).squareRoot() * strideVariation * rng.gauss()
                }
                speed = done ? 0 : stepFrequency * strideLength * max(0.5, strideFactor)
            }
            let moved = speed * dt
            pos = pos + PZ.Vec2.heading(theta) * moved
            walkedTotal += moved
            if speed > 0 { phase += 2 * .pi * stepFrequency * dt }

            let device = theta - carryOffset + PZ.degrees(2) * sin(phase / 2)
            let rate = PZ.wrap(device - prevDevice) / dt
            prevDevice = device

            if withMotion {
                let pitch = PZ.degrees(3) * sin(phase)
                let up = PZ.Vec3(0, sin(pitch), cos(pitch))
                let accelNoise = speed > 0 ? 0.02 : 0.003
                let vertical = speed > 0 ? accelAmplitude * sin(phase) : 0
                let accel = up.scaled(vertical) + PZ.Vec3(accelNoise * rng.gauss(), accelNoise * rng.gauss(), accelNoise * rng.gauss())
                let gyroNoiseNow = speed > 0 ? gyroNoise : gyroNoise / 4
                let omega = up.scaled(-(rate + gyroBias))
                    + PZ.Vec3(gyroNoiseNow * rng.gauss(), gyroNoiseNow * rng.gauss(), gyroNoiseNow * rng.gauss())
                records.append(.motion(sample: PZ.MotionSample(t: t, gravity: up.scaled(-1), userAcceleration: accel, rotationRate: omega)))
            }

            if withCompass && t >= nextCompass {
                nextCompass += 1 / compassRate
                var heading = device + compassNoise * rng.gauss()
                var disturbed = false
                for d in disturbances where pos.distance(to: d.center) < d.radius {
                    heading += d.bias
                    disturbed = disturbed || d.flagged
                }
                records.append(.compass(sample: PZ.CompassSample(t: t, heading: PZ.wrap(heading), sigma: compassReportedSigma, disturbed: disturbed)))
            }

            if t >= nextGNSS {
                nextGNSS += 1
                let a = exp(-1 / gnssTau)
                let b = (1 - a * a).squareRoot() * gnssCorrelated
                gnssError = PZ.Vec2(x: a * gnssError.x + b * rng.gauss(), z: a * gnssError.z + b * rng.gauss())
                for i in anchorErrors.indices {
                    let s = anchors[i].trueErrorSigma
                    anchorErrors[i] = PZ.Vec2(x: a * anchorErrors[i].x + (1 - a * a).squareRoot() * s * rng.gauss(),
                                              z: a * anchorErrors[i].z + (1 - a * a).squareRoot() * s * rng.gauss())
                }
                if gnssUntil.map({ t < $0 }) ?? true {
                    let measured = pos + gnssError + PZ.Vec2(x: gnssWhite * rng.gauss(), z: gnssWhite * rng.gauss())
                    let course = speed > 0.5 ? PZ.wrap(theta + PZ.degrees(4) * rng.gauss()) : nil
                    records.append(.gnss(fix: PZ.GNSSFix(t: t, position: measured, horizontalAccuracy: gnssReportedAccuracy,
                                                         course: course, courseSigma: course == nil ? nil : PZ.degrees(8),
                                                         speed: speed, trusted: true)))
                }
            }

            if t >= nextReport {
                nextReport += 1
                for (i, a) in anchors.enumerated() {
                    let reported = a.kind == .gnss ? a.position + anchorErrors[i] : a.position
                    records.append(.anchor(anchor: PZ.Anchor(id: a.id, position: reported, sigma: a.reportedSigma, kind: a.kind,
                                                             measuredAt: t - anchorReportLatency, timeSigma: 0.5,
                                                             speedBound: a.kind == .surveyed ? 0 : 1.5, gnssDependent: a.kind == .gnss)))
                }
            }

            for i in anchors.indices where t >= nextAdvert[i] {
                nextAdvert[i] += 1 / advertisementRate
                let a = anchors[i]
                let d = pos.distance(to: a.position)
                let hear = 1 / (1 + exp((d - hearRange) / hearSoft))
                guard rng.next() < hear else { continue }
                let rho = exp(-(walkedTotal - shadowWalked[i]) / shadowDecorrelation)
                shadow[i] = rho * shadow[i] + (1 - rho * rho).squareRoot() * shadowSigma * rng.gauss()
                shadowWalked[i] = walkedTotal
                var rssi = radioP0 + a.rssiOffset - 10 * radioN * log10(max(0.5, d)) + shadow[i] + fastSigma * rng.gauss()
                if rng.next() < deepFadeProbability { rssi -= rng.uniform(5, 20) }
                let bearing = atan2(a.position.x - pos.x, a.position.z - pos.z)
                if abs(PZ.wrap(bearing - theta)) > PZ.degrees(110) { rssi -= bodyLoss }
                rssi = rssi.rounded()
                guard rssi >= sensitivity else { continue }
                records.append(.rssi(sample: PZ.RSSISample(peerId: a.id, rssi: rssi, t: t, channel: .advertisement)))
            }

            if t >= nextTruth {
                nextTruth += 1 / truthRate
                truth.append((t, pos))
                records.append(.truth(position: pos, t: t))
            }
            t += dt
        }
        return Output(records: records, truth: truth)
    }
}

/// Hold-last-fix baseline (what the app showed before): the last trusted fix, with a circle growing
/// at walking pace.
enum HoldLastBaseline {
    static func run(_ records: [PZ.LogRecord], every: TimeInterval = 1, end: TimeInterval) -> [PZ.ReplayEpoch] {
        let fixes = records.compactMap { r -> PZ.GNSSFix? in if case .gnss(let f) = r, f.trusted { return f } else { return nil } }
        let truth = records.compactMap { r -> (t: TimeInterval, p: PZ.Vec2)? in if case .truth(let p, let t) = r { return (t, p) } else { return nil } }
        var epochs: [PZ.ReplayEpoch] = []
        var t = 1.0
        while t <= end {
            if let fix = fixes.last(where: { $0.t <= t }) {
                let age = t - fix.t
                let r95 = PositionUncertainty.r95(fromRadius68: fix.horizontalAccuracy) + 1.4 * age
                let e = PZ.Estimate(method: age <= 3 ? .gnss : .deadReckoning, frameId: "hervanta-v1", t: t, position: fix.position,
                                    regionCenter: fix.position, covariance: .isotropic(sigma: r95 / PZ.Stats.r95PerSigma), r95: r95,
                                    candidates: [], heading: nil, headingSigma: nil, lastAbsoluteAt: fix.t, lastTrustedGNSS: fix,
                                    anchorIds: [], gnssDependent: true, provenance: [], flags: [])
                epochs.append(PZ.Replay.score(e, truth: PZ.Replay.interpolate(truth, at: t)))
            }
            t += every
        }
        return epochs
    }
}
