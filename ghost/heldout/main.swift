// Fits Ghost Mode's predictors on training walks and scores them, next to the learned movement
// model, on the held-out Hervanta walks. Built and run by ghost/heldout/run.sh; compiled together
// with ios/MeshCore/Sources/MeshCore/Ghost/*.swift (the code the app runs) and the movement
// model's Swift runtime from the movement-model branch.
//
//   eval <data-dir> <ml-export-dir or -> <out-dir>
import Foundation

let args = CommandLine.arguments
let dataDir = URL(fileURLWithPath: args[1])
let mlExport: URL? = args[2] == "-" ? nil : URL(fileURLWithPath: args[2])
let outDir = URL(fileURLWithPath: args[3])

let fitHorizons = [5, 10, 30, 60, 120, 180]
let reportHorizons = [5, 10, 30, 60, 120, 180]
let levels = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.95]
let gpsAccuracy = 4.0

// MARK: Data

struct Case {
    let ox: Double, oy: Double
    /// Noisy history relative to the true position at the cut, every 2 s, oldest first.
    let hist: [(x: Double, y: Double)]
    /// True positions 1...180 s after the cut, same frame.
    let fut: [(x: Double, y: Double)]
}

struct Condition {
    let name: String
    /// What the history positions report as their own sigma (ml/train.py's `acc`).
    let sigma: Double
    let source: GhostObservation.Source
    let train: [Case]
    let test: [Case]
}

func loadCases(_ name: String) -> [Case] {
    let data = try! Data(contentsOf: dataDir.appendingPathComponent("\(name).f64"))
    let width = 426
    return data.withUnsafeBytes { raw -> [Case] in
        func v(_ i: Int) -> Double { raw.loadUnaligned(fromByteOffset: i * 8, as: Double.self) }
        return (0..<(data.count / (width * 8))).map { r in
            let b = r * width
            return Case(ox: v(b), oy: v(b + 1),
                        hist: (0..<31).map { (v(b + 4 + 2 * $0), v(b + 5 + 2 * $0)) },
                        fut: (0..<180).map { (v(b + 66 + 2 * $0), v(b + 67 + 2 * $0)) })
        }
    }
}

let meta = try! JSONSerialization.jsonObject(with: Data(contentsOf: dataDir.appendingPathComponent("meta.json"))) as! [String: Any]
/// Which training area each training window came from, for the hardest-area calibration.
let trainArea = (meta["trainArea"] as! [NSNumber]).map(\.intValue)
let trainAreaNames = meta["trainAreaNames"] as! [String]

let conditions = [
    Condition(name: "gps", sigma: gpsAccuracy, source: .gps, train: loadCases("train-gps"), test: loadCases("test-gps")),
    Condition(name: "mesh", sigma: (15.0 * 15 + gpsAccuracy * gpsAccuracy).squareRoot(), source: .bluetooth,
              train: loadCases("train-mesh"), test: loadCases("test-mesh")),
]
print("train \(conditions[0].train.count) windows (8 areas), test \(conditions[0].test.count) windows (hervanta)")

func observations(_ c: Case, _ cond: Condition) -> [GhostObservation] {
    c.hist.enumerated().map { i, p in
        GhostObservation(t: Double(2 * i - 60), x: p.x, z: p.y, sigma: cond.sigma, source: cond.source)
    }
}

// MARK: Parallel helpers

func parallelMap<T>(_ n: Int, _ body: (Int) -> T) -> [T] {
    var out = [T?](repeating: nil, count: n)
    let chunk = 32
    out.withUnsafeMutableBufferPointer { buf in
        let base = buf.baseAddress!
        DispatchQueue.concurrentPerform(iterations: (n + chunk - 1) / chunk) { c in
            for i in (c * chunk)..<min(n, (c + 1) * chunk) { (base + i).pointee = body(i) }
        }
    }
    return out.map { $0! }
}

// MARK: Gaussian predictors (the ones that ship in MeshCore)

enum Method {
    /// Stays at the last position; spread^2 = (a sigma)^2 + v^2 h^2 + d h.
    case still(a: Double, v: Double, d: Double)
    case constantVelocity(GhostConstantVelocity)
    case kalman(GhostMotionParams)
    /// Kalman filter plus simulated steps + compass during the gap (own phone only).
    case kalmanInertial(GhostMotionParams)
}

/// Predictions at `horizons` seconds after the last history point.
func predict(_ m: Method, _ c: Case, _ cond: Condition, _ horizons: [Int], seed: UInt64 = 0) -> [GhostBelief] {
    let obs = observations(c, cond)
    let last = obs[obs.count - 1]
    switch m {
    case let .still(a, v, d):
        return horizons.map { h in
            let hh = Double(h)
            return GhostBelief(core: .isotropic(x: last.x, z: last.z, sigma: ((a * last.sigma) * (a * last.sigma) + v * v * hh * hh + d * hh).squareRoot()))
        }
    case let .constantVelocity(cv):
        return horizons.map { GhostBelief(core: cv.predict(track: obs, at: Double($0))!) }
    case let .kalman(params):
        var f = GhostKalman(first: obs[0], params: params)
        for o in obs.dropFirst() { f.update(o) }
        return horizons.map { f.belief(at: Double($0)) }
    case let .kalmanInertial(params):
        var f = GhostKalman(first: obs[0], params: params)
        for o in obs.dropFirst() { f.update(o) }
        var rng = EvalRNG(seed: seed)
        // Per-walk sensor errors: step length off by ~10%, compass off by ~8 degrees.
        let scale = 1 + 0.1 * rng.normal(), bias = 8 * Double.pi / 180 * rng.normal()
        var out: [GhostBelief] = []
        var t = 0
        for h in horizons {
            while t + 2 <= h {
                t += 2
                let a = t >= 3 ? c.fut[t - 3] : (x: 0.0, y: 0.0), b = c.fut[t - 1]
                let vx = (b.x - a.x) / 2, vy = (b.y - a.y) / 2
                let speed = (vx * vx + vy * vy).squareRoot()
                if speed < 0.25 && rng.uniform() < 0.9 {
                    f.apply(GhostMotionHint(t: Double(t), stationary: true))
                } else {
                    let heading = atan2(vx, vy) + bias + 15 * Double.pi / 180 * rng.normal()
                    let s = speed * scale * (1 + 0.1 * rng.normal())
                    let v = GhostVelocity.fromHeading(speed: max(0, s), heading: heading,
                                                      speedSigma: 0.15 + 0.15 * s, headingSigma: 20 * Double.pi / 180)
                    f.apply(GhostMotionHint(t: Double(t), stationary: false, velocity: v))
                }
            }
            out.append(f.belief(at: Double(h)))
        }
        return out
    }
}

func meanNLL(_ m: Method, _ cond: Condition, _ cases: [Case]) -> Double {
    let per = parallelMap(cases.count) { i -> Double in
        let c = cases[i]
        let g = predict(m, c, cond, fitHorizons)
        var s = 0.0
        for (k, h) in fitHorizons.enumerated() { s -= g[k].logDensity(x: c.fut[h - 1].x, z: c.fut[h - 1].y) }
        return s / Double(fitHorizons.count)
    }
    return per.reduce(0, +) / Double(per.count)
}

/// Nelder-Mead on unconstrained parameters.
func minimize(_ f: ([Double]) -> Double, _ start: [Double], step: Double = 0.4, iterations: Int = 160) -> ([Double], Double) {
    let n = start.count
    var simplex = [start] + (0..<n).map { i -> [Double] in var p = start; p[i] += step; return p }
    var values = simplex.map(f)
    for _ in 0..<iterations {
        let order = values.indices.sorted { values[$0] < values[$1] }
        simplex = order.map { simplex[$0] }
        values = order.map { values[$0] }
        let centroid = (0..<n).map { j in simplex.dropLast().map { $0[j] }.reduce(0, +) / Double(n) }
        func toward(_ t: Double) -> [Double] { (0..<n).map { centroid[$0] + t * (simplex[n][$0] - centroid[$0]) } }
        let r = toward(-1), fr = f(r)
        if fr < values[0] {
            let e = toward(-2), fe = f(e)
            (simplex[n], values[n]) = fe < fr ? (e, fe) : (r, fr)
        } else if fr < values[n - 1] {
            (simplex[n], values[n]) = (r, fr)
        } else {
            let k = toward(fr < values[n] ? -0.5 : 0.5), fk = f(k)
            if fk < min(fr, values[n]) {
                (simplex[n], values[n]) = (k, fk)
            } else {
                for i in 1...n {
                    simplex[i] = (0..<n).map { simplex[0][$0] + 0.5 * (simplex[i][$0] - simplex[0][$0]) }
                    values[i] = f(simplex[i])
                }
            }
        }
        if values.max()! - values.min()! < 1e-5 { break }
    }
    let best = values.indices.min { values[$0] < values[$1] }!
    return (simplex[best], values[best])
}

// MARK: Fitting (training areas only)

var fitted: [String: [String: Any]] = [:]
var trainNLL: [String: Double] = [:]
func sources(_ p: [Double]) -> (Double, Double) { (exp(p[0]), exp(p[1])) }

var stillParams: [String: Method] = [:]
var cvParams: [String: Method] = [:]
for cond in conditions {
    let (p, v) = minimize({ q in meanNLL(.still(a: exp(q[0]), v: exp(q[1]), d: exp(q[2])), cond, cond.train) },
                          [0, log(0.3), 0])
    stillParams[cond.name] = .still(a: exp(p[0]), v: exp(p[1]), d: exp(p[2]))
    fitted["still/\(cond.name)"] = ["startScale": exp(p[0]), "velocitySigma": exp(p[1]), "diffusion": exp(p[2]), "trainNLL": v]
    trainNLL["still/\(cond.name)"] = v
    var best: (Method, Double, [String: Any])?
    for window in [4.0, 10, 20, 30] {
        let make = { (q: [Double]) in
            GhostConstantVelocity(window: window, startScale: exp(q[0]), velocitySigma: exp(q[1]), diffusion: exp(q[2]))
        }
        let (p, v) = minimize({ meanNLL(.constantVelocity(make($0)), cond, cond.train) }, [0, log(0.4), 0])
        if best == nil || v < best!.1 {
            let cv = make(p)
            best = (.constantVelocity(cv), v, ["window": window, "startScale": cv.startScale,
                                               "velocitySigma": cv.velocitySigma, "diffusion": cv.diffusion, "trainNLL": v])
        }
    }
    cvParams[cond.name] = best!.0
    fitted["constant-velocity/\(cond.name)"] = best!.2
    trainNLL["constant-velocity/\(cond.name)"] = best!.1
    print("fitted still + constant velocity for \(cond.name)")
}

/// Kalman motion parameters are about people, so one set serves both conditions; only the
/// trust in each source's reported sigma differs.
/// Mean-reverting: [noise, gps scale, radio scale, persistence]; a new track starts with the
/// process's own stationary speed spread. Constant velocity: [noise, gps, radio, initial speed].
func kalmanParams(_ kind: GhostMotionParams.Kind, _ q: [Double]) -> GhostMotionParams {
    var p = GhostMotionParams(kind: kind, motionNoise: exp(q[0]), persistence: kind == .meanReverting ? exp(q[3]) : .infinity,
                              gpsSigmaScale: exp(q[1]), radioSigmaScale: exp(q[2]),
                              initialSpeedSigma: kind == .meanReverting ? exp(q[0]) : exp(q[3]))
    p.floorAtTrustedSigma = GhostMotionParams.walking.floorAtTrustedSigma
    return p
}
func jointNLL(_ p: GhostMotionParams) -> Double {
    conditions.map { meanNLL(.kalman(p), $0, $0.train) }.reduce(0, +) / Double(conditions.count)
}
var kalman: [String: GhostMotionParams] = [:]
let kalmanStarts: [(String, GhostMotionParams.Kind, [Double])] = [
    ("kalman-cv", .constantVelocity, [log(0.3), 0, 0, 0]),
    ("kalman-ou", .meanReverting, [log(0.8), 0, 0, log(60.0)]),
]
for (name, kind, start) in kalmanStarts {
    let (p, v) = minimize({ jointNLL(kalmanParams(kind, $0)) }, start, iterations: 220)
    let params = kalmanParams(kind, p)
    kalman[name] = params
    fitted[name] = ["kind": kind.rawValue, "motionNoise": params.motionNoise, "persistence": params.persistence.isFinite ? params.persistence : -1,
                    "gpsSigmaScale": params.gpsSigmaScale, "radioSigmaScale": params.radioSigmaScale,
                    "initialSpeedSigma": params.initialSpeedSigma, "trainNLL": v]
    for cond in conditions { trainNLL["\(name)/\(cond.name)"] = meanNLL(.kalman(params), cond, cond.train) }
    print("fitted \(name): \(fitted[name]!)")
}

/// Split-conformal r95 against an unseen area: per horizon, the variance multiplier that makes the
/// 95% circle hold 95% of the walks in the HARDEST of the eight training areas; one table per
/// source kind. Held-out Hervanta is never used.
func conformal(_ params: GhostMotionParams, _ cond: Condition) -> [GhostMotionParams.HorizonScale] {
    let ratios = parallelMap(cond.train.count) { i -> [Double] in
        let c = cond.train[i]
        let b = predict(.kalman(params), c, cond, fitHorizons)
        return fitHorizons.enumerated().map { k, h in
            hypot(b[k].x - c.fut[h - 1].x, b[k].z - c.fut[h - 1].y) / b[k].circleRadius(level: 0.95)
        }
    }
    return fitHorizons.enumerated().map { k, h in
        let q = trainAreaNames.indices.compactMap { a -> Double? in
            let r = ratios.indices.filter { trainArea[$0] == a }.map { ratios[$0][k] }
            return r.count >= 50 ? quantile(r, 0.95) : nil
        }.max()!
        return GhostMotionParams.HorizonScale(horizon: Double(h), variance: (q * q * 1000).rounded() / 1000)
    }
}
do {
    var shipped = kalman["kalman-ou"]!
    shipped.gpsCalibration = conformal(shipped, conditions[0])
    shipped.radioCalibration = conformal(shipped, conditions[1])
    kalman["kalman-ou (calibrated)"] = shipped
    fitted["kalman-ou (calibrated)"] = [
        "gpsCalibration": shipped.gpsCalibration.map { ["horizon": $0.horizon, "variance": $0.variance] },
        "radioCalibration": shipped.radioCalibration.map { ["horizon": $0.horizon, "variance": $0.variance] }]
    func table(_ t: [GhostMotionParams.HorizonScale]) -> String {
        "[" + t.map { ".init(horizon: \(Int($0.horizon)), variance: \($0.variance))" }.joined(separator: ", ") + "]"
    }
    print("""
    Swift defaults (GhostMotionParams.walking):
        motionNoise: \(shipped.motionNoise), persistence: \(shipped.persistence), gpsSigmaScale: \(shipped.gpsSigmaScale),
        radioSigmaScale: \(shipped.radioSigmaScale), initialSpeedSigma: \(shipped.initialSpeedSigma)
        gpsCalibration = \(table(shipped.gpsCalibration))
        radioCalibration = \(table(shipped.radioCalibration))
    """)
}

// MARK: Scoring

struct Scored {
    var err: Double, logp: Double, level: Double, r95: Double, area90: Double
}

struct Row: Codable {
    let method: String, history: String, h: Int, n: Int
    let err50: Double, err90: Double, nll: Double
    let cover50: Double, cover90: Double, cover95: Double
    /// Truth inside the 95% circle around the centre: what the map draws as r95.
    let coverR95: Double
    /// Mean |coverage - level| over 10 levels from 10% to 95%.
    let calibrationError: Double
    let r95Median: Double
    /// Area (ha) every method needs to catch exactly 90% of these walks (ml/train.py's metric).
    let area90Exact: Double
    /// Mean area (ha) of the method's own 90% region.
    let area90Nominal: Double
}

func quantile(_ v: [Double], _ q: Double) -> Double {
    let s = v.sorted()
    let x = q * Double(s.count - 1)
    let i = Int(x), f = x - Double(i)
    return i + 1 < s.count ? s[i] * (1 - f) + s[i + 1] * f : s[i]
}

func summarize(_ name: String, _ cond: String, _ h: Int, _ s: [Scored], areaExact: Double) -> Row {
    let n = Double(s.count)
    func cover(_ a: Double) -> Double { Double(s.filter { $0.level <= a }.count) / n }
    return Row(method: name, history: cond, h: h, n: s.count,
               err50: quantile(s.map(\.err), 0.5), err90: quantile(s.map(\.err), 0.9),
               nll: -s.map(\.logp).reduce(0, +) / n,
               cover50: cover(0.5), cover90: cover(0.9), cover95: cover(0.95),
               coverR95: Double(s.filter { $0.err <= $0.r95 }.count) / n,
               calibrationError: levels.map { abs(cover($0) - $0) }.reduce(0, +) / Double(levels.count),
               r95Median: quantile(s.map(\.r95), 0.5),
               area90Exact: areaExact / 1e4, area90Nominal: s.map(\.area90).reduce(0, +) / n / 1e4)
}

var rows: [Row] = []

/// Area of {log p >= thr}: an ellipse of the core shape, since the density falls with d^2.
func areaAbove(_ b: GhostBelief, _ thr: Double) -> Double {
    func lp(_ d2: Double) -> Double {
        let r = b.core.principal
        return b.logDensity(x: b.x + (d2 * r.major).squareRoot() * cos(r.angle), z: b.z + (d2 * r.major).squareRoot() * sin(r.angle))
    }
    guard lp(0) > thr else { return 0 }
    var lo = 0.0, hi = 1.0
    while lp(hi) > thr { hi *= 2 }
    for _ in 0..<60 where hi - lo > 1e-9 * hi {
        let mid = (lo + hi) / 2
        if lp(mid) > thr { lo = mid } else { hi = mid }
    }
    return Double.pi * hi * b.core.determinant.squareRoot()
}

func scoreGaussian(_ name: String, _ cond: Condition, _ m: (Case, Int) -> [GhostBelief]) {
    let per = parallelMap(cond.test.count) { i -> [(Scored, GhostBelief)] in
        let c = cond.test[i]
        let g = m(c, i)
        return reportHorizons.enumerated().map { k, h in
            let t = c.fut[h - 1], b = g[k]
            return (Scored(err: hypot(b.x - t.x, b.z - t.y), logp: b.logDensity(x: t.x, z: t.y),
                           level: b.level(x: t.x, z: t.y), r95: b.circleRadius(level: 0.95),
                           area90: b.area(level: 0.9)), b)
        }
    }
    for (k, h) in reportHorizons.enumerated() {
        let s = per.map { $0[k] }
        let thr = quantile(s.map(\.0.logp), 0.1)
        let area = s.map { areaAbove($0.1, thr) }.reduce(0, +) / Double(s.count)
        rows.append(summarize(name, cond.name, h, s.map(\.0), areaExact: area))
    }
}

for cond in conditions {
    scoreGaussian("still", cond) { c, _ in predict(stillParams[cond.name]!, c, cond, reportHorizons) }
    scoreGaussian("constant-velocity", cond) { c, _ in predict(cvParams[cond.name]!, c, cond, reportHorizons) }
    for name in ["kalman-cv", "kalman-ou", "kalman-ou (calibrated)"] {
        scoreGaussian(name, cond) { c, _ in predict(.kalman(kalman[name]!), c, cond, reportHorizons) }
    }
    scoreGaussian("kalman-ou (calibrated) + inertial (simulated)", cond) { c, i in
        predict(.kalmanInertial(kalman["kalman-ou (calibrated)"]!), c, cond, reportHorizons, seed: UInt64(i) &+ 77)
    }
    print("scored Ghost predictors on \(cond.name)")
}

// MARK: The learned movement model, through its own Swift runtime

func mixLogDensity(_ p: MovementModel.Prediction, _ x: Double, _ y: Double) -> Double {
    var terms: [Double] = []
    for k in p.weights.indices {
        let c = p.covs[k]
        let det = c.xx * c.yy - c.xy * c.xy
        let dx = x - p.means[k].x, dy = y - p.means[k].y
        let q = (c.yy * dx * dx - 2 * c.xy * dx * dy + c.xx * dy * dy) / det
        terms.append(log(p.weights[k]) - q / 2 - log(2 * Double.pi) - 0.5 * log(det))
    }
    let m = terms.max()!
    return m + log(terms.map { exp($0 - m) }.reduce(0, +))
}

if let mlExport {
    let v1 = try? MovementModel(json: Data(contentsOf: mlExport.appendingPathComponent("movement-model.json")))
    let v2 = try? MovementModel(json: Data(contentsOf: mlExport.appendingPathComponent("movement-model-v2.json")))
    let map = try? MovementModel.MapLayer(png: Data(contentsOf: mlExport.appendingPathComponent("maps/hervanta.png")),
                                          meta: Data(contentsOf: mlExport.appendingPathComponent("maps/hervanta.json")))
    var learned: [(String, MovementModel, MovementModel.MapLayer?)] = []
    if let v1 { learned.append(("movement-model v1", v1, nil)) }
    if let v2 { learned.append(("movement-model v2, no map", v2, nil)) }
    if let v2, let map { learned.append(("movement-model v2 + map", v2, map)) }
    let samples = 1000
    for cond in conditions {
        for (name, model, layer) in learned {
            func predictions(_ c: Case) -> [MovementModel.Prediction] {
                let hist = c.hist.map { MovementModel.Point(c.ox + $0.x, c.oy + $0.y) }
                let prep = model.prepare(history: hist, accuracy: cond.sigma, map: layer)
                return reportHorizons.map { model.predict(prepared: prep, horizon: Double($0)) }
            }
            // Pass 1: density at the truth sets the exact-90% threshold per horizon.
            let first = parallelMap(cond.test.count) { i -> [Double] in
                let c = cond.test[i]
                let p = predictions(c)
                return reportHorizons.enumerated().map { k, h in
                    mixLogDensity(p[k], c.ox + c.fut[h - 1].x, c.oy + c.fut[h - 1].y)
                }
            }
            let thresholds = reportHorizons.indices.map { k in quantile(first.map { $0[k] }, 0.1) }
            // Pass 2: Monte Carlo for levels, the 95% circle and areas.
            let per = parallelMap(cond.test.count) { i -> [(Scored, Double)] in
                let c = cond.test[i]
                let p = predictions(c)
                var rng = EvalRNG(seed: UInt64(i) &* 31 &+ 5)
                return reportHorizons.enumerated().map { k, h in
                    let pred = p[k]
                    let tx = c.ox + c.fut[h - 1].x, ty = c.oy + c.fut[h - 1].y
                    var mx = 0.0, my = 0.0
                    for (w, m) in zip(pred.weights, pred.means) { mx += w * m.x; my += w * m.y }
                    let pts = pred.sample(samples, using: &rng)
                    let lps = pts.map { mixLogDensity(pred, $0.x, $0.y) }
                    let lt = first[i][k]
                    let level = Double(lps.filter { $0 > lt }.count) / Double(samples)
                    let r95 = quantile(pts.map { hypot($0.x - mx, $0.y - my) }, 0.95)
                    let t90 = quantile(lps, 0.1)
                    func area(_ t: Double) -> Double { lps.map { $0 >= t ? exp(-$0) : 0 }.reduce(0, +) / Double(samples) }
                    return (Scored(err: hypot(mx - tx, my - ty), logp: lt, level: level, r95: r95,
                                   area90: area(t90)), area(thresholds[k]))
                }
            }
            for (k, h) in reportHorizons.enumerated() {
                let s = per.map { $0[k] }
                rows.append(summarize(name, cond.name, h, s.map(\.0), areaExact: s.map(\.1).reduce(0, +) / Double(s.count)))
            }
            print("scored \(name) on \(cond.name)")
        }
    }
}

// MARK: Verdict, decided by this rule before looking at the test numbers

/// The learned model replaces the Kalman predictor for a history type only if, on held-out
/// Hervanta at 10, 30, 60 and 120 s, it wins at 3 of the 4 horizons on each of: median error,
/// exact-90% area, and calibration (|r95 coverage - 0.95| no worse than the Kalman one + 0.02).
func verdict(learned: String, baseline: String, history: String) -> [String: Any] {
    let hs = [10, 30, 60, 120]
    func row(_ m: String, _ h: Int) -> Row? { rows.first { $0.method == m && $0.history == history && $0.h == h } }
    guard hs.allSatisfy({ row(learned, $0) != nil && row(baseline, $0) != nil }) else { return ["available": false] }
    let err = hs.filter { row(learned, $0)!.err50 < row(baseline, $0)!.err50 }.count
    let area = hs.filter { row(learned, $0)!.area90Exact < row(baseline, $0)!.area90Exact }.count
    let cal = hs.filter { abs(row(learned, $0)!.coverR95 - 0.95) <= abs(row(baseline, $0)!.coverR95 - 0.95) + 0.02 }.count
    return ["learned": learned, "baseline": baseline, "history": history, "winsError": err, "winsArea": area,
            "calibrationOK": cal, "retainLearned": err >= 3 && area >= 3 && cal >= 3]
}
var verdicts: [[String: Any]] = []
for cond in conditions {
    for learned in ["movement-model v1", "movement-model v2, no map", "movement-model v2 + map"] {
        verdicts.append(verdict(learned: learned, baseline: "kalman-ou (calibrated)", history: cond.name))
    }
}

// MARK: Output

try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try! enc.encode(rows).write(to: outDir.appendingPathComponent("heldout-metrics.json"))
let extra: [String: Any] = ["fitted": fitted, "trainNLL": trainNLL, "verdicts": verdicts,
                            "testArea": "hervanta", "testWindows": conditions[0].test.count,
                            "trainWindows": conditions[0].train.count]
try! JSONSerialization.data(withJSONObject: extra, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("params.json"))

func f(_ v: Double, _ d: Int = 1) -> String { String(format: "%.\(d)f", v) }
var md = "| history | method | h (s) | err50 m | err90 m | r95 cover | 90% cover | calib err | median r95 m | exact-90% area ha | NLL |\n"
md += "|---|---|---|---|---|---|---|---|---|---|---|\n"
for r in rows {
    md += "| \(r.history) | \(r.method) | \(r.h) | \(f(r.err50)) | \(f(r.err90)) | \(f(r.coverR95, 3)) | \(f(r.cover90, 3)) | "
    md += "\(f(r.calibrationError, 3)) | \(f(r.r95Median)) | \(f(r.area90Exact, 2)) | \(f(r.nll, 2)) |\n"
}
try! md.write(to: outDir.appendingPathComponent("heldout-table.md"), atomically: true, encoding: .utf8)
print(md)
for v in verdicts { print(v) }

// MARK: RNG

struct EvalRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { (Double(next() >> 11) + 0.5) / Double(1 << 53) }
    mutating func normal() -> Double { (-2 * log(uniform())).squareRoot() * cos(2 * Double.pi * uniform()) }
}
