import Foundation

/// GhostCore positioning engine. Everything lives under this namespace so it cannot collide with the
/// shared contract types (`PositionEstimate`, `PeerObservation`, ...) or the Bluetooth estimator while
/// those are still moving; adapters map these types onto the contract.
///
/// Conventions used throughout:
/// - Frame: the floor plane of a `GeoFrame` (x east, z north, metres). Height is not estimated.
/// - Heading: radians clockwise from north (+z) towards east (+x), the compass convention, so a unit
///   step along heading h moves (sin h, cos h).
/// - Time: local monotonic seconds (`ProcessInfo.systemUptime`, the base Core Motion uses). Wall-clock
///   dates are converted once on entry; timestamps from other phones are never compared directly.
public enum Positioning {}

extension Positioning {
    /// A point or displacement on the floor plane: x east, z north, metres.
    public struct Vec2: Equatable, Codable {
        public var x: Double
        public var z: Double

        public init(x: Double, z: Double) {
            self.x = x
            self.z = z
        }

        public static let zero = Vec2(x: 0, z: 0)

        public var length: Double { hypot(x, z) }
        public func distance(to other: Vec2) -> Double { hypot(x - other.x, z - other.z) }

        public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x + b.x, z: a.z + b.z) }
        public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, z: a.z - b.z) }
        public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(x: a.x * s, z: a.z * s) }

        /// Unit vector along a heading.
        public static func heading(_ h: Double) -> Vec2 { Vec2(x: sin(h), z: cos(h)) }
    }

    /// A device-frame vector (Core Motion axes: x right, y up the screen, z out of the screen).
    public struct Vec3: Equatable, Codable {
        public var x: Double
        public var y: Double
        public var z: Double

        public init(_ x: Double, _ y: Double, _ z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }

        public var length: Double { (x * x + y * y + z * z).squareRoot() }
        public func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }
        public func cross(_ o: Vec3) -> Vec3 { Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x) }
        public func scaled(_ s: Double) -> Vec3 { Vec3(x * s, y * s, z * s) }
        public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
        public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
        public var normalized: Vec3? {
            let l = length
            return l.isFinite && l > 1e-9 ? scaled(1 / l) : nil
        }
    }

    /// Symmetric 2x2 covariance of a floor-plane position, m².
    public struct Covariance2: Equatable, Codable {
        public var xx: Double
        public var xz: Double
        public var zz: Double

        public init(xx: Double, xz: Double, zz: Double) {
            self.xx = xx
            self.xz = xz
            self.zz = zz
        }

        public static func isotropic(sigma: Double) -> Covariance2 { Covariance2(xx: sigma * sigma, xz: 0, zz: sigma * sigma) }

        /// Eigenvalues, largest first.
        public var eigenvalues: (major: Double, minor: Double) {
            let mean = (xx + zz) / 2
            let root = (((xx - zz) / 2) * ((xx - zz) / 2) + xz * xz).squareRoot()
            return (mean + root, max(0, mean - root))
        }

        /// Radius of a circle around the mean that holds at least 95 % of a Gaussian with this
        /// covariance (exact for a circular one, conservative for an elongated one).
        public var r95: Double { (Stats.chi2_2dof_95 * eigenvalues.major).squareRoot() }

        /// Squared Mahalanobis distance of `d` (nil if singular).
        public func mahalanobis2(_ d: Vec2) -> Double? {
            let det = xx * zz - xz * xz
            guard det > 1e-12 else { return nil }
            return (zz * d.x * d.x - 2 * xz * d.x * d.z + xx * d.z * d.z) / det
        }
    }

    enum Stats {
        /// Chi-square quantiles used for gates and radii.
        static let chi2_1dof_95 = 3.841
        static let chi2_1dof_997 = 8.807
        static let chi2_2dof_95 = 5.991
        static let chi2_2dof_999 = 13.816
        /// Per-axis sigma of a circular Gaussian whose 68 % radius is 1 (Core Location's accuracy).
        static let radius68ToSigma = 1 / 1.5096
        static let r95PerSigma = chi2_2dof_95.squareRoot()

        static func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let s = values.sorted()
            let m = s.count / 2
            return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
        }

        /// 1.4826 × median absolute deviation: the standard deviation for Gaussian data, robust to outliers.
        static func robustSpread(_ values: [Double], around center: Double) -> Double {
            (median(values.map { abs($0 - center) }) ?? 0) * 1.4826
        }

        static func percentile(_ values: [Double], _ p: Double) -> Double? {
            guard !values.isEmpty else { return nil }
            let s = values.sorted()
            let rank = min(Double(s.count - 1), max(0, p * Double(s.count - 1)))
            let lo = Int(rank.rounded(.down))
            let hi = min(s.count - 1, lo + 1)
            return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
        }
    }

    /// Wraps an angle to (-π, π].
    public static func wrap(_ a: Double) -> Double {
        var r = a.truncatingRemainder(dividingBy: 2 * .pi)
        if r <= -.pi { r += 2 * .pi }
        if r > .pi { r -= 2 * .pi }
        return r
    }

    public static func degrees(_ d: Double) -> Double { d * .pi / 180 }
}

extension Positioning {
    /// Small dense row-major matrix for the filter. Sizes stay below ~20, so clarity beats BLAS.
    struct Matrix: Equatable {
        let rows: Int
        let cols: Int
        var a: [Double]

        init(rows: Int, cols: Int, repeating value: Double = 0) {
            self.rows = rows
            self.cols = cols
            a = Array(repeating: value, count: rows * cols)
        }

        static func identity(_ n: Int) -> Matrix {
            var m = Matrix(rows: n, cols: n)
            for i in 0..<n { m[i, i] = 1 }
            return m
        }

        subscript(i: Int, j: Int) -> Double {
            get { a[i * cols + j] }
            set { a[i * cols + j] = newValue }
        }

        var transposed: Matrix {
            var t = Matrix(rows: cols, cols: rows)
            for i in 0..<rows { for j in 0..<cols { t[j, i] = self[i, j] } }
            return t
        }

        static func * (l: Matrix, r: Matrix) -> Matrix {
            precondition(l.cols == r.rows)
            var m = Matrix(rows: l.rows, cols: r.cols)
            for i in 0..<l.rows {
                for k in 0..<l.cols {
                    let v = l[i, k]
                    if v == 0 { continue }
                    for j in 0..<r.cols { m.a[i * r.cols + j] += v * r.a[k * r.cols + j] }
                }
            }
            return m
        }

        static func + (l: Matrix, r: Matrix) -> Matrix {
            var m = l
            for i in 0..<m.a.count { m.a[i] += r.a[i] }
            return m
        }

        static func - (l: Matrix, r: Matrix) -> Matrix {
            var m = l
            for i in 0..<m.a.count { m.a[i] -= r.a[i] }
            return m
        }

        func scaled(_ s: Double) -> Matrix {
            var m = self
            for i in 0..<m.a.count { m.a[i] *= s }
            return m
        }

        /// Gauss-Jordan inverse with partial pivoting; nil if (numerically) singular.
        func inverted() -> Matrix? {
            precondition(rows == cols)
            let n = rows
            var m = self
            var inv = Matrix.identity(n)
            for c in 0..<n {
                var p = c
                for r in c + 1..<max(c + 1, n) where abs(m[r, c]) > abs(m[p, c]) { p = r }
                guard abs(m[p, c]) > 1e-12 else { return nil }
                if p != c {
                    for j in 0..<n {
                        m.a.swapAt(c * n + j, p * n + j)
                        inv.a.swapAt(c * n + j, p * n + j)
                    }
                }
                let d = m[c, c]
                for j in 0..<n {
                    m[c, j] /= d
                    inv[c, j] /= d
                }
                for r in 0..<n where r != c {
                    let f = m[r, c]
                    if f == 0 { continue }
                    for j in 0..<n {
                        m[r, j] -= f * m[c, j]
                        inv[r, j] -= f * inv[c, j]
                    }
                }
            }
            return inv
        }

        /// Keeps the matrix symmetric against round-off.
        mutating func symmetrize() {
            for i in 0..<rows {
                for j in i + 1..<max(i + 1, cols) {
                    let v = (self[i, j] + self[j, i]) / 2
                    self[i, j] = v
                    self[j, i] = v
                }
            }
        }
    }
}
