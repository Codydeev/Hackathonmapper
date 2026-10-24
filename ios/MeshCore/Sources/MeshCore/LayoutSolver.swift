import Foundation

// Joint layout of the phones of one connected component on the floor plane (x east, z north).
// The particle filter samples each neighbour's cloud on its own, so it cannot say "±10 m together,
// but exactly 3.4 m apart". This solver can: Levenberg-Marquardt over 2 unknowns per phone, every
// term weighted by its own sigma, robust (Huber) terms for measurements that can be biased.
//
//   UWB range          (d - D) / (0.15 m + 0.02 D)            Huber: body blocking reads long
//   RSSI range         (rssi - expected(d)) / radio.sigma      Huber, log-distance
//   Bearing            angle(a -> b) - measured, / its error   Huber: compass errors
//   Position prior     (p - prior) / sigma                     GPS, manual, UWB fix, previous solution
//
// N is ~20 phones at most, so the normal equations are solved densely with Cholesky.

/// An angle in radians wrapped to (-pi, pi].
func wrappedAngle(_ a: Double) -> Double { atan2(sin(a), cos(a)) }

public enum LayoutSolver {
    /// Huber threshold in sigmas: quadratic inside, linear outside.
    public static let huberK = 1.345
    /// Information added to every unknown when solving and when inverting: a 100 m prior that
    /// keeps an unconstrained direction (a ring) finite without pulling the solution anywhere.
    public static let regularization = 1e-4

    /// 1-sigma error of a UWB distance.
    public static func uwbSigma(distance: Double) -> Double { 0.15 + 0.02 * max(0, distance) }

    /// A phone is near `point` with an error of `sigma` m on each axis.
    public struct Prior: Equatable {
        public let id: String
        public let point: FloorPoint
        public let sigma: Double

        public init(id: String, point: FloorPoint, sigma: Double) {
            self.id = id
            self.point = point
            self.sigma = sigma
        }
    }

    /// A UWB distance between `a` and `b`.
    public struct Range: Equatable {
        public let a: String
        public let b: String
        public let distance: Double

        public init(a: String, b: String, distance: Double) {
            self.a = a
            self.b = b
            self.distance = distance
        }
    }

    /// An RSSI reading between `a` and `b`, compared in log-distance through the radio model.
    public struct Signal: Equatable {
        public let a: String
        public let b: String
        public let rssi: Double

        public init(a: String, b: String, rssi: Double) {
            self.a = a
            self.b = b
            self.rssi = rssi
        }
    }

    /// A UWB bearing measured from `from` toward `to`.
    public struct Bearing: Equatable {
        public let from: String
        public let to: String
        public let bearing: LinkBearing

        public init(from: String, to: String, bearing: LinkBearing) {
            self.from = from
            self.to = to
            self.bearing = bearing
        }
    }

    public struct Problem {
        /// Every unknown phone with its starting point (the previous solution, or a seed).
        public var start: [String: FloorPoint]
        public var priors: [Prior]
        public var ranges: [Range]
        public var signals: [Signal]
        public var bearings: [Bearing]
        public var radio: RadioModel

        public init(start: [String: FloorPoint], priors: [Prior] = [], ranges: [Range] = [],
                    signals: [Signal] = [], bearings: [Bearing] = [], radio: RadioModel = .outdoors) {
            self.start = start
            self.priors = priors
            self.ranges = ranges
            self.signals = signals
            self.bearings = bearings
            self.radio = radio
        }
    }

    public struct Solution {
        public let points: [String: FloorPoint]
        public let iterations: Int
        /// Final cost (half the sum of the squared, Huber-limited normalized residuals).
        public let cost: Double
        private let index: [String: Int]
        /// Inverse of the information matrix, row-major, 2 rows per phone (x, z).
        private let covariance: [Double]

        init(points: [String: FloorPoint], iterations: Int, cost: Double, index: [String: Int], covariance: [Double]) {
            self.points = points
            self.iterations = iterations
            self.cost = cost
            self.index = index
            self.covariance = covariance
        }

        private func block(_ i: Int, _ j: Int) -> (xx: Double, xz: Double, zx: Double, zz: Double) {
            let m = 2 * index.count
            return (covariance[2 * i * m + 2 * j], covariance[2 * i * m + 2 * j + 1],
                    covariance[(2 * i + 1) * m + 2 * j], covariance[(2 * i + 1) * m + 2 * j + 1])
        }

        /// The larger 1-sigma semi-axis of the error ellipse of a 2x2 covariance.
        private static func largerAxis(_ xx: Double, _ xz: Double, _ zz: Double) -> Double {
            let mean = (xx + zz) / 2
            let spread = (((xx - zz) / 2) * ((xx - zz) / 2) + xz * xz).squareRoot()
            return max(0, mean + spread).squareRoot()
        }

        /// Larger 1-sigma axis of the phone's position error.
        public func sigma(_ id: String) -> Double? {
            guard let i = index[id] else { return nil }
            let c = block(i, i)
            return Self.largerAxis(c.xx, (c.xz + c.zx) / 2, c.zz)
        }

        /// Larger 1-sigma axis of the error of the vector between two phones: small when their
        /// relative placement is known, however unsure both are on the map.
        public func relativeSigma(_ a: String, _ b: String) -> Double? {
            guard let i = index[a], let j = index[b] else { return nil }
            let ii = block(i, i), jj = block(j, j), ij = block(i, j), ji = block(j, i)
            let xx = ii.xx + jj.xx - ij.xx - ji.xx
            let zz = ii.zz + jj.zz - ij.zz - ji.zz
            let xz = (ii.xz + jj.xz - ij.xz - ji.xz + ii.zx + jj.zx - ij.zx - ji.zx) / 2
            return Self.largerAxis(xx, xz, zz)
        }
    }

    public static func solve(_ problem: Problem, maxIterations: Int = 30) -> Solution {
        let ids = problem.start.keys.sorted()
        var index: [String: Int] = [:]
        for (i, id) in ids.enumerated() { index[id] = i }
        let m = 2 * ids.count
        var x = Array(repeating: 0.0, count: m)
        for (i, id) in ids.enumerated() {
            x[2 * i] = problem.start[id]!.x
            x[2 * i + 1] = problem.start[id]!.z
        }
        guard m > 0 else { return Solution(points: [:], iterations: 0, cost: 0, index: [:], covariance: []) }

        var current = normalEquations(problem, x, index)
        var lambda = 1e-3
        var iterations = 0
        while iterations < maxIterations {
            iterations += 1
            var a = current.h
            for i in 0..<m * m { a[i] += current.stretch[i] }
            for i in 0..<m { a[i * m + i] += lambda * max(a[i * m + i], 1e-6) + regularization }
            guard let delta = choleskySolve(a, current.g.map { -$0 }, m) else {
                lambda *= 10
                if lambda > 1e10 { break }
                continue
            }
            let step = delta.map { abs($0) }.max() ?? 0
            let candidate = zip(x, delta).map { $0 + $1 }
            let next = normalEquations(problem, candidate, index)
            if next.cost < current.cost {
                x = candidate
                current = next
                lambda = max(lambda * 0.3, 1e-9)
                if step < 1e-4 { break }
            } else {
                lambda *= 10
                if lambda > 1e10 || step < 1e-7 { break }
            }
        }

        var information = current.h
        for i in 0..<m { information[i * m + i] += regularization }
        var covariance: [Double]
        if let inverse = invert(information, m) {
            covariance = inverse
        } else {
            covariance = Array(repeating: 0.0, count: m * m)
            for i in 0..<m { covariance[i * m + i] = 1 / regularization }
        }
        var points: [String: FloorPoint] = [:]
        for (i, id) in ids.enumerated() { points[id] = FloorPoint(x: x[2 * i], z: x[2 * i + 1]) }
        return Solution(points: points, iterations: iterations, cost: current.cost, index: index, covariance: covariance)
    }

    // MARK: Normal equations

    /// JᵀWJ, JᵀWr and the cost at one point, with the Huber weights of that point (IRLS).
    private struct Normal {
        let m: Int
        var h: [Double]
        var g: [Double]
        /// Second-order term of stretched ranges, for the steps only. A pair pulled apart by its
        /// priors resists turning, which Gauss-Newton alone misses: it then crawls for many iterations.
        var stretch: [Double]
        var cost = 0.0

        init(m: Int) {
            self.m = m
            h = Array(repeating: 0, count: m * m)
            g = Array(repeating: 0, count: m)
            stretch = Array(repeating: 0, count: m * m)
        }

        /// One normalized residual `r` and its nonzero Jacobian entries (unknown, derivative).
        mutating func add(_ r: Double, robust: Bool, _ entries: [(Int, Double)]) {
            guard r.isFinite else { return }
            let w: Double
            let k = LayoutSolver.huberK
            if robust && abs(r) > k {
                w = k / abs(r)
                cost += k * abs(r) - 0.5 * k * k
            } else {
                w = 1
                cost += 0.5 * r * r
            }
            for (i, ji) in entries {
                g[i] += w * ji * r
                for (j, jj) in entries { h[i * m + j] += w * ji * jj }
            }
        }

        /// rho'(r) times the Hessian of r = (d - D) / s for a range that is too long (r > 0):
        /// (I - uuᵀ) / (s d) on both phones, with the opposite sign across them.
        mutating func addStretch(_ r: Double, sigma s: Double, d: Double, ux: Double, uz: Double, _ i: Int, _ j: Int) {
            guard r > 0, d > 1e-9, r.isFinite else { return }
            let c = min(r, LayoutSolver.huberK) / (s * d)
            let t = [1 - ux * ux, -ux * uz, -ux * uz, 1 - uz * uz]
            for (p, q, sign) in [(i, i, 1.0), (j, j, 1.0), (i, j, -1.0), (j, i, -1.0)] {
                for a in 0..<2 {
                    for b in 0..<2 { stretch[(2 * p + a) * m + 2 * q + b] += sign * c * t[2 * a + b] }
                }
            }
        }
    }

    /// Distance between phones i and j and the unit vector from j to i.
    private static func separation(_ x: [Double], _ i: Int, _ j: Int) -> (d: Double, ux: Double, uz: Double) {
        let dx = x[2 * i] - x[2 * j]
        let dz = x[2 * i + 1] - x[2 * j + 1]
        let d = hypot(dx, dz)
        // Two phones on the same spot: any direction will do to push them apart.
        guard d > 1e-9 else { return (0, 0, 1) }
        return (d, dx / d, dz / d)
    }

    private static func normalEquations(_ p: Problem, _ x: [Double], _ index: [String: Int]) -> Normal {
        var n = Normal(m: x.count)
        for prior in p.priors {
            guard let i = index[prior.id] else { continue }
            let s = max(prior.sigma, 1e-3)
            n.add((x[2 * i] - prior.point.x) / s, robust: false, [(2 * i, 1 / s)])
            n.add((x[2 * i + 1] - prior.point.z) / s, robust: false, [(2 * i + 1, 1 / s)])
        }
        for range in p.ranges {
            guard let i = index[range.a], let j = index[range.b], i != j else { continue }
            let (d, ux, uz) = separation(x, i, j)
            let s = uwbSigma(distance: range.distance)
            let r = (d - range.distance) / s
            n.add(r, robust: true, [(2 * i, ux / s), (2 * i + 1, uz / s), (2 * j, -ux / s), (2 * j + 1, -uz / s)])
            n.addStretch(r, sigma: s, d: d, ux: ux, uz: uz, i, j)
        }
        for signal in p.signals {
            guard let i = index[signal.a], let j = index[signal.b], i != j else { continue }
            let (d, ux, uz) = separation(x, i, j)
            let s = p.radio.sigma
            let r = (signal.rssi - p.radio.expectedRSSI(atDistance: d)) / s
            // expectedRSSI is flat below 0.5 m.
            let slope = d > 0.5 ? 10 * p.radio.n / (d * log(10)) / s : 0
            n.add(r, robust: true,
                  [(2 * i, slope * ux), (2 * i + 1, slope * uz), (2 * j, -slope * ux), (2 * j + 1, -slope * uz)])
        }
        for bearing in p.bearings {
            guard let i = index[bearing.from], let j = index[bearing.to], i != j else { continue }
            let dx = x[2 * j] - x[2 * i]
            let dz = x[2 * j + 1] - x[2 * i + 1]
            let q = dx * dx + dz * dz
            guard q > 1e-6 else { continue }
            let e = max(1, bearing.bearing.errorDegrees) * Double.pi / 180
            // Bearing 0 = +z (north), 90 = +x (east): angle = atan2(dx, dz).
            let r = wrappedAngle(atan2(dx, dz) - bearing.bearing.degrees * Double.pi / 180) / e
            let jx = dz / q / e
            let jz = -dx / q / e
            n.add(r, robust: true, [(2 * j, jx), (2 * j + 1, jz), (2 * i, -jx), (2 * i + 1, -jz)])
        }
        return n
    }

    // MARK: Dense linear algebra (row-major, m x m)

    /// Lower-triangular L with A = L Lᵀ, or nil when A is not positive definite.
    static func cholesky(_ a: [Double], _ m: Int) -> [Double]? {
        var l = Array(repeating: 0.0, count: m * m)
        for i in 0..<m {
            for j in 0...i {
                var s = a[i * m + j]
                for k in 0..<j { s -= l[i * m + k] * l[j * m + k] }
                if i == j {
                    guard s > 0, s.isFinite else { return nil }
                    l[i * m + i] = s.squareRoot()
                } else {
                    l[i * m + j] = s / l[j * m + j]
                }
            }
        }
        return l
    }

    /// Solves L Lᵀ x = b.
    static func solve(lower l: [Double], _ b: [Double], _ m: Int) -> [Double] {
        var y = b
        for i in 0..<m {
            var s = y[i]
            for k in 0..<i { s -= l[i * m + k] * y[k] }
            y[i] = s / l[i * m + i]
        }
        for i in stride(from: m - 1, through: 0, by: -1) {
            var s = y[i]
            for k in (i + 1)..<m { s -= l[k * m + i] * y[k] }
            y[i] = s / l[i * m + i]
        }
        return y
    }

    static func choleskySolve(_ a: [Double], _ b: [Double], _ m: Int) -> [Double]? {
        guard let l = cholesky(a, m) else { return nil }
        let x = solve(lower: l, b, m)
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    static func invert(_ a: [Double], _ m: Int) -> [Double]? {
        guard let l = cholesky(a, m) else { return nil }
        var inverse = Array(repeating: 0.0, count: m * m)
        var e = Array(repeating: 0.0, count: m)
        for c in 0..<m {
            e[c] = 1
            let column = solve(lower: l, e, m)
            e[c] = 0
            for r in 0..<m { inverse[r * m + c] = column[r] }
        }
        return inverse
    }
}
