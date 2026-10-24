import Foundation

/// A position belief on the floor plane (x east, z north, metres): a centre and how far off it may
/// be. Ghost Mode never hands out a centre without its spread.
public struct GhostGaussian: Equatable {
    public var x: Double
    public var z: Double
    /// Covariance in m².
    public var xx: Double
    public var xz: Double
    public var zz: Double

    public init(x: Double, z: Double, xx: Double, xz: Double = 0, zz: Double) {
        self.x = x
        self.z = z
        self.xx = xx
        self.xz = xz
        self.zz = zz
    }

    /// `sigma` is the standard deviation along each axis.
    public static func isotropic(x: Double, z: Double, sigma: Double) -> GhostGaussian {
        GhostGaussian(x: x, z: z, xx: sigma * sigma, zz: sigma * sigma)
    }

    public var determinant: Double { max(xx * zz - xz * xz, 1e-12) }

    /// Squared Mahalanobis distance of a point from the centre.
    public func mahalanobis2(x px: Double, z pz: Double) -> Double {
        let dx = px - x, dz = pz - z
        return (zz * dx * dx - 2 * xz * dx * dz + xx * dz * dz) / determinant
    }

    /// Mass of the smallest ellipse (same shape as the belief) that reaches the point: 0 at the
    /// centre, near 1 far out. A calibrated belief gives uniform levels for the true positions.
    public func level(x px: Double, z pz: Double) -> Double {
        -expm1(-0.5 * mahalanobis2(x: px, z: pz))
    }

    public func logDensity(x px: Double, z pz: Double) -> Double {
        -log(2 * Double.pi) - 0.5 * log(determinant) - 0.5 * mahalanobis2(x: px, z: pz)
    }

    /// Variances along the principal axes (largest first) and the angle of the major axis,
    /// radians counterclockwise from east.
    public var principal: (major: Double, minor: Double, angle: Double) {
        let mean = (xx + zz) / 2
        let d = (((xx - zz) / 2) * ((xx - zz) / 2) + xz * xz).squareRoot()
        let major = mean + d
        let angle = abs(xz) > 1e-12 ? atan2(major - xx, xz) : (xx >= zz ? 0 : Double.pi / 2)
        return (major, max(mean - d, 1e-12), angle)
    }

    /// The ellipse that holds `level` of the mass.
    public func ellipse(level: Double) -> GhostEllipse {
        let k = (-2 * log1p(-min(level, 0.999_999))).squareRoot()
        let p = principal
        return GhostEllipse(semiMajor: k * p.major.squareRoot(), semiMinor: k * p.minor.squareRoot(), angle: p.angle)
    }

    /// Area in m² of the ellipse that holds `level` of the mass.
    public func area(level: Double) -> Double {
        -2 * Double.pi * determinant.squareRoot() * log1p(-min(level, 0.999_999))
    }

    /// Mass inside a circle of radius `r` around the centre. Exact for any covariance: the radial
    /// part integrates in closed form, the angle numerically (periodic, so few nodes suffice).
    public func mass(within r: Double) -> Double {
        guard r > 0 else { return 0 }
        let p = principal
        let l1 = p.major, l2 = p.minor
        let n = 48
        var sum = 0.0
        for i in 0..<n {
            let th = (Double(i) + 0.5) * (Double.pi / 2) / Double(n)
            let c = cos(th), s = sin(th)
            let a = c * c / l1 + s * s / l2
            sum += -expm1(-0.5 * r * r * a) / a
        }
        return min(1, sum / Double(n) / (l1 * l2).squareRoot())
    }

    /// Radius of the circle around the centre that holds `level` of the mass, for maps that draw
    /// circles rather than ellipses.
    public func circleRadius(level: Double) -> Double {
        let level = min(max(level, 1e-6), 0.999_999)
        let k = (-2 * log1p(-level)).squareRoot()
        let p = principal
        var lo = k * p.minor.squareRoot(), hi = k * p.major.squareRoot()
        for _ in 0..<40 where hi - lo > 1e-4 {
            let mid = (lo + hi) / 2
            if mass(within: mid) < level { lo = mid } else { hi = mid }
        }
        return hi
    }

    /// Deterministic points drawn from the belief, for drawing it as a cloud.
    public func samples(_ count: Int, seed: UInt64) -> [(x: Double, z: Double)] {
        let p = principal
        let a = p.major.squareRoot(), b = p.minor.squareRoot()
        let c = cos(p.angle), s = sin(p.angle)
        var state = seed
        func uniform() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var v = state
            v = (v ^ (v >> 30)) &* 0xBF58_476D_1CE4_E5B9
            v = (v ^ (v >> 27)) &* 0x94D0_49BB_1331_11EB
            v ^= v >> 31
            return (Double(v >> 11) + 0.5) / Double(1 << 53)
        }
        return (0..<count).map { _ in
            let r = (-2 * log(uniform())).squareRoot(), th = 2 * Double.pi * uniform()
            let u = a * r * cos(th), v = b * r * sin(th)
            return (x + c * u - s * v, z + s * u + c * v)
        }
    }
}

/// Semi-axes in metres; `angle` is the major axis, radians counterclockwise from east.
public struct GhostEllipse: Equatable, Codable {
    public let semiMajor: Double
    public let semiMinor: Double
    public let angle: Double
}

/// A Gaussian with heavy tails: the same centre and shape at a few scales. People mostly keep
/// going the way the filter expects, and sometimes stop or turn; one scale cannot say both. All
/// regions are still ellipses of the core shape, so levels, circles and areas stay exact.
public struct GhostBelief: Equatable {
    public struct Scale: Equatable, Codable {
        public let weight: Double
        /// Variance multiplier on the core covariance.
        public let variance: Double

        public init(weight: Double, variance: Double) {
            self.weight = weight
            self.variance = variance
        }
    }

    public var core: GhostGaussian
    public var scales: [Scale]

    public init(core: GhostGaussian, scales: [Scale] = [Scale(weight: 1, variance: 1)]) {
        self.core = core
        let total = scales.map(\.weight).reduce(0, +)
        self.scales = scales.map { Scale(weight: $0.weight / total, variance: $0.variance) }
    }

    public var x: Double { core.x }
    public var z: Double { core.z }

    /// Mixture covariance (for consumers that only take one ellipse).
    public var covariance: GhostGaussian {
        let m = scales.map { $0.weight * $0.variance }.reduce(0, +)
        return GhostGaussian(x: core.x, z: core.z, xx: core.xx * m, xz: core.xz * m, zz: core.zz * m)
    }

    /// Mass of the smallest centred ellipse that reaches the point.
    public func level(x px: Double, z pz: Double) -> Double {
        cdf(core.mahalanobis2(x: px, z: pz))
    }

    public func logDensity(x px: Double, z pz: Double) -> Double {
        let d2 = core.mahalanobis2(x: px, z: pz)
        let terms = scales.map { log($0.weight) - log($0.variance) - 0.5 * d2 / $0.variance }
        let m = terms.max()!
        return m + log(terms.map { exp($0 - m) }.reduce(0, +)) - log(2 * Double.pi) - 0.5 * log(core.determinant)
    }

    public func mass(within r: Double) -> Double {
        scales.map { $0.weight * scaled($0.variance).mass(within: r) }.reduce(0, +)
    }

    public func circleRadius(level: Double) -> Double {
        let level = min(max(level, 1e-6), 0.999_999)
        var lo = 0.0, hi = scales.map { scaled($0.variance).circleRadius(level: level) }.max()!
        for _ in 0..<50 where hi - lo > 1e-4 {
            let mid = (lo + hi) / 2
            if mass(within: mid) < level { lo = mid } else { hi = mid }
        }
        return hi
    }

    /// Squared Mahalanobis radius (in the core's metric) of the ellipse that holds `level`.
    public func radius2(level: Double) -> Double {
        let level = min(max(level, 1e-6), 0.999_999)
        var lo = 0.0, hi = 1.0
        while cdf(hi) < level { hi *= 2 }
        for _ in 0..<60 where hi - lo > 1e-9 * hi {
            let mid = (lo + hi) / 2
            if cdf(mid) < level { lo = mid } else { hi = mid }
        }
        return hi
    }

    public func ellipse(level: Double) -> GhostEllipse {
        let k = radius2(level: level).squareRoot()
        let p = core.principal
        return GhostEllipse(semiMajor: k * p.major.squareRoot(), semiMinor: k * p.minor.squareRoot(), angle: p.angle)
    }

    public func area(level: Double) -> Double {
        Double.pi * radius2(level: level) * core.determinant.squareRoot()
    }

    public func samples(_ count: Int, seed: UInt64) -> [(x: Double, z: Double)] {
        let unit = core.samples(count, seed: seed)
        var cum = 0.0
        let bounds = scales.map { s -> (Double, Double) in cum += s.weight; return (cum, s.variance.squareRoot()) }
        return unit.enumerated().map { i, p in
            // Spread the scales evenly over the points instead of drawing them, so the cloud is stable.
            let u = (Double(i) + 0.5) / Double(count)
            let k = bounds.first { u <= $0.0 }?.1 ?? bounds[bounds.count - 1].1
            return (core.x + k * (p.x - core.x), core.z + k * (p.z - core.z))
        }
    }

    private func cdf(_ d2: Double) -> Double {
        scales.map { $0.weight * -expm1(-0.5 * d2 / $0.variance) }.reduce(0, +)
    }

    private func scaled(_ v: Double) -> GhostGaussian {
        GhostGaussian(x: core.x, z: core.z, xx: core.xx * v, xz: core.xz * v, zz: core.zz * v)
    }
}
