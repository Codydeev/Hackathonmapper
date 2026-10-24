import Foundation

extension Positioning {
    /// A phone whose position is known well enough to range against.
    public struct Anchor: Equatable, Codable {
        public enum Kind: String, Codable {
            /// Its own GNSS fix, trusted by the integrity check.
            case gnss
            /// Placed at a surveyed or hand-entered spot; static.
            case surveyed
            /// Itself estimated (dead reckoning or Bluetooth): usable only with its uncertainty and
            /// only if its estimate does not depend on us.
            case estimated
        }

        public let id: String
        public let position: Vec2
        /// 1-sigma per axis when measured, m.
        public let sigma: Double
        public let kind: Kind
        /// Local monotonic time the position was valid (receipt time minus the sender's age and
        /// the relay latency).
        public let measuredAt: TimeInterval
        /// Extra timing uncertainty from relaying, s.
        public let timeSigma: TimeInterval
        /// How fast it may move, m/s: 0 for a surveyed anchor, walking pace for a phone.
        public let speedBound: Double
        /// Device ids its position depends on (for `estimated`), to refuse cycles.
        public let dependsOn: [String]
        /// Its position rests on GNSS somewhere upstream.
        public let gnssDependent: Bool

        public init(id: String, position: Vec2, sigma: Double, kind: Kind, measuredAt: TimeInterval,
                    timeSigma: TimeInterval = 0, speedBound: Double = 1.5, dependsOn: [String] = [],
                    gnssDependent: Bool = false) {
            self.id = id
            self.position = position
            self.sigma = sigma
            self.kind = kind
            self.measuredAt = measuredAt
            self.timeSigma = timeSigma
            self.speedBound = speedBound
            self.dependsOn = dependsOn
            self.gnssDependent = gnssDependent || kind == .gnss
        }

        /// Per-axis sigma at time `t`: grown by how far it may have moved since it was measured.
        public func sigma(at t: TimeInterval) -> Double {
            let age = max(0, t - measuredAt) + timeSigma
            let drift = speedBound * age
            return (sigma * sigma + drift * drift).squareRoot()
        }
    }

    /// A median RSSI window against an anchor, ready for geometry.
    public struct RangeObservation: Equatable {
        public let anchor: Anchor
        public let window: RSSIWindow
        public let model: PathLossModel

        public init(anchor: Anchor, window: RSSIWindow, model: PathLossModel) {
            self.anchor = anchor
            self.window = window
            self.model = model
        }

        /// Upper 95 % distance plus the anchor's own 95 % radius: the phone is inside this disc.
        public var discRadius95: Double {
            model.distanceInterval(rssi: window.median).upperBound + Stats.r95PerSigma * anchor.sigma(at: window.t)
        }
    }

    /// What a set of simultaneous range observations says on its own, without motion or history.
    public struct GeometrySolution: Equatable {
        public enum Kind: String, Codable {
            /// Inside a disc around one anchor. One range gives distance, never direction.
            case proximity
            /// Two (or mirror-symmetric) solutions fit equally well; the centre is not a guess.
            case ambiguous
            /// Three or more anchors with usable geometry: a single solution.
            case multilateration
        }

        public let kind: Kind
        /// Best single point for `multilateration`; for the other kinds the centre of the covering
        /// region (for `proximity` the anchor itself), which must not be shown as the phone.
        public let center: Vec2
        /// Covering covariance (for proximity and ambiguous: a Gaussian over the whole region).
        public let covariance: Covariance2
        public let r95: Double
        /// For `ambiguous`: each candidate position.
        public let candidates: [Vec2]
        public let hdop: Double?
        public let anchorIds: [String]
        public let t: TimeInterval
    }

    public enum RangeGeometry {
        /// Maximum horizontal dilution of precision for a multilateration to count.
        public static let maxHDOP = 3.0

        /// Solves 1 anchor -> proximity disc, 2 -> ambiguous pair, 3+ -> multilateration if the
        /// geometry is good and no mirror solution fits as well, else the tightest proximity disc.
        public static func solve(_ observations: [RangeObservation], maxHDOP: Double = maxHDOP) -> GeometrySolution? {
            // One observation per anchor: the latest.
            var latest: [String: RangeObservation] = [:]
            for o in observations where latest[o.anchor.id].map({ $0.window.t < o.window.t }) ?? true { latest[o.anchor.id] = o }
            let obs = latest.values.sorted { $0.anchor.id < $1.anchor.id }
            guard !obs.isEmpty else { return nil }
            let t = obs.map(\.window.t).max()!
            if obs.count == 1 { return proximity(obs[0], t: t) }
            if obs.count == 2 { return twoAnchors(obs, t: t) ?? tightestDisc(obs, t: t) }
            return multilaterate(obs, maxHDOP: maxHDOP, t: t) ?? tightestDisc(obs, t: t)
        }

        static func proximity(_ o: RangeObservation, t: TimeInterval) -> GeometrySolution {
            let r = o.discRadius95
            return GeometrySolution(kind: .proximity, center: o.anchor.position,
                                    covariance: .isotropic(sigma: r / Stats.r95PerSigma), r95: r,
                                    candidates: [], hdop: nil, anchorIds: [o.anchor.id], t: t)
        }

        static func tightestDisc(_ obs: [RangeObservation], t: TimeInterval) -> GeometrySolution {
            proximity(obs.min { $0.discRadius95 < $1.discRadius95 }!, t: t)
        }

        /// Whitened residuals and their Jacobian at p, in dB (log-distance), with the anchor's own
        /// uncertainty mapped into each sigma. Huber weights make one blocked link count less.
        static func residuals(_ obs: [RangeObservation], at p: Vec2) -> (r: [Double], jx: [Double], jz: [Double]) {
            var r: [Double] = []
            var jx: [Double] = []
            var jz: [Double] = []
            for o in obs {
                let m = o.model
                let a = o.anchor.position
                let dx = p.x - a.x
                let dz = p.z - a.z
                let dist = max(m.minDistance, hypot(dx, dz))
                let grad = m.slope / dist
                let sa = o.anchor.sigma(at: o.window.t)
                let sigma = (m.totalSigma * m.totalSigma + grad * grad * sa * sa).squareRoot()
                let predicted = m.expectedRSSI(distance: dist)
                if m.isCensored(rssi: o.window.median) && predicted < o.window.median {
                    // Near the receiver's floor a reading only bounds the distance from below:
                    // being farther than it suggests costs nothing.
                    r.append(0)
                    jx.append(0)
                    jz.append(0)
                    continue
                }
                r.append((o.window.median - predicted) / sigma)
                // Derivative of the whitened residual: d(predicted)/dp = -slope (p - a) / d².
                let s = hypot(dx, dz) > m.minDistance ? m.slope / (dist * dist) / sigma : 0
                jx.append(s * dx)
                jz.append(s * dz)
            }
            return (r, jx, jz)
        }

        static func cost(_ r: [Double]) -> Double {
            // Huber loss with k = 1.5 sigma.
            r.reduce(0) { sum, v in sum + (abs(v) <= 1.5 ? v * v : 3 * abs(v) - 2.25) }
        }

        /// Levenberg-Marquardt on the robust cost from one start point.
        static func refine(_ obs: [RangeObservation], from start: Vec2) -> (p: Vec2, cost: Double, info: Covariance2)? {
            var p = start
            var lambda = 1e-2
            var (r, jx, jz) = residuals(obs, at: p)
            var c = cost(r)
            for _ in 0..<40 {
                var a11 = 0.0, a12 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0
                for i in r.indices {
                    let w = abs(r[i]) <= 1.5 ? 1 : 1.5 / abs(r[i])
                    // Gauss-Newton on the residual Jacobian J: (JᵀWJ) dp = -JᵀW r.
                    a11 += w * jx[i] * jx[i]
                    a12 += w * jx[i] * jz[i]
                    a22 += w * jz[i] * jz[i]
                    b1 += w * jx[i] * r[i]
                    b2 += w * jz[i] * r[i]
                }
                b1 = -b1
                b2 = -b2
                let d11 = a11 * (1 + lambda) + 1e-9
                let d22 = a22 * (1 + lambda) + 1e-9
                let det = d11 * d22 - a12 * a12
                guard abs(det) > 1e-15 else { break }
                let step = Vec2(x: (d22 * b1 - a12 * b2) / det, z: (d11 * b2 - a12 * b1) / det)
                let candidate = p + step
                let next = residuals(obs, at: candidate)
                let nc = cost(next.r)
                if nc < c {
                    p = candidate
                    (r, jx, jz) = next
                    let improvement = c - nc
                    c = nc
                    lambda = max(1e-6, lambda / 3)
                    if step.length < 0.01 || improvement < 1e-6 { break }
                } else {
                    lambda *= 4
                    if lambda > 1e6 { break }
                }
            }
            var a11 = 0.0, a12 = 0.0, a22 = 0.0
            for i in r.indices {
                a11 += jx[i] * jx[i]
                a12 += jx[i] * jz[i]
                a22 += jz[i] * jz[i]
            }
            let det = a11 * a22 - a12 * a12
            guard det > 1e-12 else { return nil }
            return (p, c, Covariance2(xx: a22 / det, xz: -a12 / det, zz: a11 / det))
        }

        static func hdop(_ obs: [RangeObservation], at p: Vec2) -> Double? {
            var a11 = 0.0, a12 = 0.0, a22 = 0.0
            for o in obs {
                let d = o.anchor.position - p
                let l = d.length
                guard l > 1e-6 else { continue }
                a11 += d.x * d.x / (l * l)
                a12 += d.x * d.z / (l * l)
                a22 += d.z * d.z / (l * l)
            }
            let det = a11 * a22 - a12 * a12
            guard det > 1e-9 else { return nil }
            return ((a11 + a22) / det).squareRoot()
        }

        /// Circle intersections of two median ranges (one point when they only touch or miss).
        static func intersections(_ a: Vec2, _ ra: Double, _ b: Vec2, _ rb: Double) -> [Vec2] {
            let d = a.distance(to: b)
            guard d > 1e-6 else { return [a] }
            let u = (b - a) * (1 / d)
            if ra + rb <= d || abs(ra - rb) >= d {
                // No crossing: the best point lies on the line through the anchors.
                let along = ra + rb <= d ? ra + (d - ra - rb) / 2 : (ra > rb ? ra : -ra)
                return [a + u * along]
            }
            let x = (ra * ra - rb * rb + d * d) / (2 * d)
            let h = max(0, ra * ra - x * x).squareRoot()
            let base = a + u * x
            let perp = Vec2(x: -u.z, z: u.x)
            return [base + perp * h, base - perp * h]
        }

        static func twoAnchors(_ obs: [RangeObservation], t: TimeInterval) -> GeometrySolution? {
            let (a, b) = (obs[0], obs[1])
            let starts = intersections(a.anchor.position, a.model.medianDistance(rssi: a.window.median),
                                       b.anchor.position, b.model.medianDistance(rssi: b.window.median))
            let solutions = starts.compactMap { refine(obs, from: $0) }
            guard !solutions.isEmpty else { return nil }
            return covering(solutions.map { ($0.p, $0.info) }, kind: .ambiguous, anchorIds: obs.map(\.anchor.id), hdop: nil, t: t)
        }

        /// A Gaussian over every candidate: centre between them, radius reaching each one's own r95.
        static func covering(_ parts: [(p: Vec2, info: Covariance2)], kind: GeometrySolution.Kind, anchorIds: [String],
                             hdop: Double?, t: TimeInterval) -> GeometrySolution {
            let center = parts.reduce(Vec2.zero) { $0 + $1.p } * (1 / Double(parts.count))
            let r95 = parts.map { $0.p.distance(to: center) + $0.info.r95 }.max() ?? 0
            return GeometrySolution(kind: kind, center: center, covariance: .isotropic(sigma: r95 / Stats.r95PerSigma),
                                    r95: r95, candidates: parts.map(\.p), hdop: hdop, anchorIds: anchorIds, t: t)
        }

        static func multilaterate(_ obs: [RangeObservation], maxHDOP: Double, t: TimeInterval) -> GeometrySolution? {
            // Start from the weighted centroid and from every pairwise circle intersection, so a
            // mirror solution is found if it exists rather than hidden by the start point.
            var starts: [Vec2] = []
            var sw = 0.0
            var centroid = Vec2.zero
            for o in obs {
                let d = o.model.medianDistance(rssi: o.window.median)
                let w = 1 / max(1, d * d)
                centroid = centroid + o.anchor.position * w
                sw += w
            }
            starts.append(centroid * (1 / sw))
            for i in obs.indices {
                for j in obs.indices where j > i {
                    starts += intersections(obs[i].anchor.position, obs[i].model.medianDistance(rssi: obs[i].window.median),
                                            obs[j].anchor.position, obs[j].model.medianDistance(rssi: obs[j].window.median))
                }
            }
            let solutions = starts.compactMap { refine(obs, from: $0) }.sorted { $0.cost < $1.cost }
            guard let best = solutions.first, let h = hdop(obs, at: best.p), h <= maxHDOP else { return nil }

            // Inflate by the reduced chi-square when the residuals are larger than the model says.
            let dof = Double(max(1, obs.count - 2))
            let scale = max(1, best.cost / dof)
            let info = Covariance2(xx: best.info.xx * scale, xz: best.info.xz * scale, zz: best.info.zz * scale)

            // A second minimum that fits about as well and lies outside the best one's error disc
            // is a mirror ambiguity (e.g. three nearly collinear anchors).
            let rivals = solutions.dropFirst().filter {
                $0.cost - best.cost < Stats.chi2_1dof_95 && $0.p.distance(to: best.p) > max(3, info.r95)
            }
            if let rival = rivals.first {
                return covering([(best.p, info), (rival.p, rival.info)], kind: .ambiguous,
                                anchorIds: obs.map(\.anchor.id), hdop: h, t: t)
            }
            return GeometrySolution(kind: .multilateration, center: best.p, covariance: info, r95: info.r95,
                                    candidates: [], hdop: h, anchorIds: obs.map(\.anchor.id), t: t)
        }
    }
}
