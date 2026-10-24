// Route filter for iOS: the route model's prediction, sharpened by signals
// that arrive after the Bluetooth link drops: Bluetooth readings of the lost
// phone (GhostCore PeerObservation) and the lost phone's own pedometer and
// compass (GhostCore MotionRecord, synced when it is heard again). A port of
// route-filter.js, checked against its golden cases. Needs RouteModel.swift
// and MovementModel.swift.
//
//   let f = RouteFilter(routes, particles: 400)
//   var s = f.start(history: hist, accuracy: 12)          // when the link drops (t = 0)
//   f.advance(&s, to: 30)                                 // seconds since then
//   f.observeBluetooth(&s, listener: p, listenerAcc: 5, rssi: -78)
//   f.observeSteps(&s, dx: dx, dy: dy, seconds: 10)       // pedometer displacement since the last call
//   let est = f.estimate(s)                                // center, r95, cloud
//
// Not yet used by the app (see ml/README.md).

import Foundation

/// The same 32-bit generator as the JS (mulberry32), so both runtimes can replay identical cases.
public struct Mulberry32 {
    var a: UInt32
    public init(seed: UInt32) { a = seed }
    public mutating func next() -> Double {
        a = a &+ 0x6D2B_79F5
        var t = (a ^ (a >> 15)) &* (1 | a)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}

public final class RouteFilter {
    public typealias Point = MovementModel.Point

    public struct Estimate {
        public let center: Point
        public let r95: Double
        public let share: Double
        public let cloud: [Point]
    }

    public struct State {
        public internal(set) var t = 0.0
        let n: Int
        let l50: [Double], sig: [Double]   // log-normal pace curve for the walker's speed bin
        var d: [Int], at: [Double], z: [Double], walked: [Double], off: [Bool]
        var x: [Double], y: [Double], th: [Double], ax: [Double], ay: [Double], w: [Double]
        var pdr = false
        var bias: [Double] = [], scale: [Double] = []
    }

    // MeshCore BluetoothEstimator.RadioModel.outdoors
    public var radio = (p0: -59.0, n: 2.5, sigma: 5.0, range: 60.0, soft: 8.0)
    static let step = 2.0, paceTau = 120.0, offTurn = 0.35
    static let pdr = (biasDeg: 10.0, scale: 0.08, driftDeg: 0.4, noise: 0.4, onPathM: 6.0, offPath: 0.08)

    let rm: RouteModel
    let count: Int
    var rng: Mulberry32
    let offRate: Double

    public init(_ routes: RouteModel, particles: Int = 400, seed: UInt32 = 1) {
        rm = routes
        count = particles
        rng = Mulberry32(seed: seed)
        offRate = -log(1 - RouteModel.interp(routes.offT, routes.offOn, 600)) / 600
    }

    func rand() -> Double { rng.next() }

    func gauss() -> Double {
        var u = 0.0
        while u == 0 { u = rand() }
        return sqrt(-2 * log(u)) * cos(2 * .pi * rand())
    }

    /// The pace curve for a speed bin: log-normal through the measured 10/50/90% quantiles.
    func paceCurve(_ bin: Int) -> (l50: [Double], sig: [Double]) {
        let row = { (q: String) in self.rm.q[q]![bin].map { log(max($0, 0.5)) } }
        let l10 = row("q10"), l50 = row("q50"), l90 = row("q90")
        return (l50, zip(l10, l90).map { max(0.05, ($1 - $0) / (2 * 1.2816)) })
    }

    /// Distance walked by time t at pace score z.
    func distance(_ s: State, _ z: Double, _ t: Double) -> Double {
        t <= 0 ? 0 : exp(RouteModel.interp(rm.tGrid, s.l50, t) + RouteModel.interp(rm.tGrid, s.sig, t) * z)
    }

    public func start(history hist: [Point], accuracy: Double) -> State {
        let n = hist.count, last = hist[n - 1], first = hist[0]
        let v = hypot(last.x - first.x, last.y - first.y) / (Double(n - 1) * 2)
        let loc = rm.locate(hist, accuracy)
        let total = loc.starts.reduce(0) { $0 + $1.p }
        let N = count, pace = paceCurve(rm.speedBin(v))
        var s = State(n: N, l50: pace.l50, sig: pace.sig, d: .init(repeating: -1, count: N), at: .init(repeating: 0, count: N),
                      z: .init(repeating: 0, count: N), walked: .init(repeating: 0, count: N), off: .init(repeating: false, count: N),
                      x: .init(repeating: 0, count: N), y: .init(repeating: 0, count: N), th: .init(repeating: 0, count: N),
                      ax: .init(repeating: 0, count: N), ay: .init(repeating: 0, count: N), w: .init(repeating: 1 / Double(N), count: N))
        let offShare = loc.offNow || loc.starts.isEmpty ? (loc.starts.isEmpty ? 1 : 0.6) : 0
        for i in 0..<N {
            s.z[i] = gauss()
            if rand() < offShare {
                s.off[i] = true; s.d[i] = -1
                s.x[i] = last.x + 3 * gauss(); s.y[i] = last.y + 3 * gauss()
                s.th[i] = loc.moved ? loc.th + 0.3 * gauss() : 2 * .pi * rand()
            } else {
                var u = rand() * total, k = 0
                while k < loc.starts.count - 1 && u > loc.starts[k].p { u -= loc.starts[k].p; k += 1 }
                s.d[i] = loc.starts[k].d; s.at[i] = loc.starts[k].s
                let p = rm.at(s.d[i], s.at[i])
                s.x[i] = p.x; s.y[i] = p.y
            }
            s.ax[i] = s.x[i]; s.ay[i] = s.y[i]
        }
        return s
    }

    func move(_ s: inout State, _ i: Int, _ dist: Double) {
        if s.off[i] {
            s.th[i] += Self.offTurn * gauss()
            s.x[i] += dist * cos(s.th[i]); s.y[i] += dist * sin(s.th[i])
            return
        }
        var d = s.d[i], at = s.at[i], dist = dist
        var guardCount = 0
        while dist > 0 && guardCount < 50 {
            guardCount += 1
            let rem = rm.len[d >> 1] - at
            if dist < rem { at += dist; dist = 0; break }
            dist -= rem
            let o0 = rm.turnOff[d], o1 = rm.turnOff[d + 1]
            if o0 == o1 { at = rm.len[d >> 1]; break }
            var u = rand(), k = o0
            while k < o1 - 1 && u > rm.turnP[k] { u -= rm.turnP[k]; k += 1 }
            d = rm.turnTo[k]; at = 0
        }
        s.d[i] = d; s.at[i] = at
        let p = rm.at(d, at)
        s.x[i] = p.x; s.y[i] = p.y
    }

    /// Propagate to t seconds since the link dropped. Once the lost phone's steps are known, the steps move the particles.
    public func advance(_ s: inout State, to t: Double) {
        if s.pdr { s.t = max(s.t, t); return }
        let rho = exp(-Self.step / Self.paceTau), k = (1 - rho * rho).squareRoot()
        while s.t < t - 1e-9 {
            let t1 = min(t, s.t + Self.step), dt = t1 - s.t
            for i in 0..<s.n {
                s.z[i] = rho * s.z[i] + k * gauss()
                let target = distance(s, s.z[i], t1), step = target - s.walked[i]
                if !s.off[i] && rand() < offRate * dt { s.off[i] = true; s.th[i] = 2 * .pi * rand() }
                if step > 0 { move(&s, i, step); s.walked[i] = target }
            }
            s.t = t1
        }
    }

    func normalize(_ s: inout State) {
        let sum = s.w.reduce(0, +)
        guard sum > 0 else { s.w = .init(repeating: 1 / Double(s.n), count: s.n); return }
        var ess = 0.0
        for i in 0..<s.n { s.w[i] /= sum; ess += s.w[i] * s.w[i] }
        if 1 / ess < Double(s.n) / 2 { resample(&s) }
    }

    /// Systematic resampling; copies keep their pace with a little jitter.
    func resample(_ s: inout State) {
        let old = s
        var c = s.w[0], j = 0
        let u0 = rand() / Double(s.n)
        for i in 0..<s.n {
            let u = u0 + Double(i) / Double(s.n)
            while u > c && j < s.n - 1 { j += 1; c += old.w[j] }
            s.d[i] = old.d[j]; s.at[i] = old.at[j]; s.z[i] = old.z[j]; s.walked[i] = old.walked[j]; s.off[i] = old.off[j]
            s.x[i] = old.x[j]; s.y[i] = old.y[j]; s.th[i] = old.th[j]; s.ax[i] = old.ax[j]; s.ay[i] = old.ay[j]
            if s.pdr { s.bias[i] = old.bias[j]; s.scale[i] = old.scale[j] }
            s.z[i] += 0.1 * gauss()
            if s.pdr { s.bias[i] += 0.01 * gauss(); s.scale[i] += 0.005 * gauss() }
        }
        s.w = .init(repeating: 1 / Double(s.n), count: s.n)
    }

    func hearProb(_ d: Double) -> Double { 1 / (1 + exp((d - radio.range) / radio.soft)) }

    /// A phone at `listener` (± listenerAcc m) heard the lost phone at `rssi` dBm.
    public func observeBluetooth(_ s: inout State, listener: Point, listenerAcc: Double = 5, rssi: Double, sigmaDb: Double? = nil) {
        let sigma = sigmaDb ?? radio.sigma
        for i in 0..<s.n {
            let d = max(0.5, hypot(s.x[i] - listener.x, s.y[i] - listener.y))
            let expected = radio.p0 - 10 * radio.n * log10(d)
            let sens = 10 * radio.n / (M_LN10 * max(d, 1))
            let v = sigma * sigma + pow(sens * listenerAcc, 2)
            s.w[i] *= exp(-pow(rssi - expected, 2) / (2 * v)) / v.squareRoot() * hearProb(d)
        }
        normalize(&s)
    }

    /// The lost phone's own pedometer and compass: displacement summed over the last `seconds`.
    public func observeSteps(_ s: inout State, dx: Double, dy: Double, seconds: Double = 10) {
        let P = Self.pdr
        if !s.pdr {
            s.pdr = true
            s.bias = (0..<s.n).map { _ in P.biasDeg * .pi / 180 * gauss() }
            s.scale = (0..<s.n).map { _ in 1 + P.scale * gauss() }
        }
        let drift = P.driftDeg * .pi / 180 * seconds.squareRoot()
        for i in 0..<s.n {
            s.bias[i] += drift * gauss()
            let c = cos(s.bias[i]), sn = sin(s.bias[i]), k = s.scale[i]
            s.x[i] += k * (c * dx - sn * dy) + P.noise * gauss()
            s.y[i] += k * (sn * dx + c * dy) + P.noise * gauss()
            let d = min(rm.nearestDist(Point(s.x[i], s.y[i]), 3 * P.onPathM), 3 * P.onPathM)
            s.w[i] *= exp(-(d * d) / (2 * P.onPathM * P.onPathM)) + P.offPath
        }
        normalize(&s)
    }

    /// Best single position: the heaviest 25 m neighbourhood, its weighted centre, and the radius holding 95% of the weight.
    public func estimate(_ s: State, cloudSize: Int = 80) -> Estimate {
        let cell = 12.0
        struct Key: Hashable { let a: Int, b: Int }
        var order: [Key] = [], cells: [Key: Double] = [:]
        for i in 0..<s.n {
            let key = Key(a: Int(floor(s.x[i] / cell)), b: Int(floor(s.y[i] / cell)))
            if cells[key] == nil { order.append(key) }
            cells[key, default: 0] += s.w[i]
        }
        var best = Point(0, 0), bestW = -1.0
        for key in order {
            var w = 0.0
            for da in -1...1 { for db in -1...1 { w += cells[Key(a: key.a + da, b: key.b + db)] ?? 0 } }
            if w > bestW { bestW = w; best = Point((Double(key.a) + 0.5) * cell, (Double(key.b) + 0.5) * cell) }
        }
        var cx = 0.0, cy = 0.0, cw = 0.0
        for i in 0..<s.n where hypot(s.x[i] - best.x, s.y[i] - best.y) <= 25 {
            cx += s.w[i] * s.x[i]; cy += s.w[i] * s.y[i]; cw += s.w[i]
        }
        let center = cw > 0 ? Point(cx / cw, cy / cw) : best
        var dist = [Double](repeating: 0, count: s.n)
        for i in 0..<s.n { dist[i] = hypot(s.x[i] - center.x, s.y[i] - center.y) }
        let order2: [Int] = (0..<s.n).sorted { (a: Int, b: Int) -> Bool in dist[a] != dist[b] ? dist[a] < dist[b] : a < b }
        var acc = 0.0, r95 = order2.last.map { dist[$0] } ?? 0
        for i in order2 { acc += s.w[i]; if acc >= 0.95 { r95 = dist[i]; break } }
        var cloud: [Point] = []
        for k in 0..<cloudSize {
            var u = (Double(k) + 0.5) / Double(cloudSize), i = 0
            while i < s.n - 1 && u > s.w[i] { u -= s.w[i]; i += 1 }
            cloud.append(Point(s.x[i], s.y[i]))
        }
        return Estimate(center: center, r95: r95, share: cw, cloud: cloud)
    }
}
