// Movement model runtime for iOS. Predicts where a person is likely to be
// h seconds from now, from where they were over the last 60 s. Used when a
// phone drops out of Bluetooth range: its last known track keeps moving as a
// growing cloud instead of a frozen dot. Foundation only, no Core ML needed:
// the network is ~46k numbers and runs in well under a millisecond.
//
//   let model = try MovementModel(json: Data(contentsOf: url))   // movement-model.json
//   let hist = model.history(track: reports, now: now)           // [(t, x, y)], seconds + metres
//   let pred = model.predict(history: hist, accuracy: 12, horizon: 60)
//   let dots = pred.sample(300)                                  // for drawing
//
// Positions are metres in any flat frame (the demo's x/z floor plane, or
// east/north). The prediction comes back in the same frame.

import Foundation

public struct MovementModel {
    public struct Spec: Decodable {
        public let K: Int
        public let histN: Int
        public let histStep: Double
        public let hMin: Double
        public let hMax: Double
        public let headingLookback: [Int]
        public let headingMin: Double
        public let posScale: Double
        public let accScale: Double
        public let stdFloor: Double
        public let horizonScale: [Double]
        let layers: [Layer]
    }

    struct Layer: Decodable {
        let w: [[Double]]
        let b: [Double]
    }

    public struct Point {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    public struct TrackPoint {
        public var t: Double
        public var x: Double
        public var y: Double
        public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
    }

    /// A mixture of 2D Gaussians: where the person may be.
    public struct Prediction {
        public let weights: [Double]
        public let means: [Point]
        public let covs: [(xx: Double, xy: Double, yy: Double)]

        /// Probability density per square metre at a point.
        public func density(_ p: Point) -> Double {
            var sum = 0.0
            for k in weights.indices {
                let c = covs[k]
                let det = c.xx * c.yy - c.xy * c.xy
                let dx = p.x - means[k].x, dy = p.y - means[k].y
                let q = (c.yy * dx * dx - 2 * c.xy * dx * dy + c.xx * dy * dy) / det
                sum += weights[k] * exp(-q / 2) / (2 * .pi * det.squareRoot())
            }
            return sum
        }

        /// Random positions from the prediction, for a cloud or a particle filter.
        public func sample<G: RandomNumberGenerator>(_ n: Int, using rng: inout G) -> [Point] {
            (0..<n).map { _ in
                var u = Double.random(in: 0..<1, using: &rng)
                var k = 0
                while k < weights.count - 1 && u > weights[k] { u -= weights[k]; k += 1 }
                let c = covs[k]
                let l11 = c.xx.squareRoot(), l21 = c.xy / l11, l22 = max(0, c.yy - l21 * l21).squareRoot()
                let r = (-2 * log(1 - Double.random(in: 0..<1, using: &rng))).squareRoot()
                let a = 2 * Double.pi * Double.random(in: 0..<1, using: &rng)
                let z1 = r * cos(a), z2 = r * sin(a)
                return Point(means[k].x + l11 * z1, means[k].y + l21 * z1 + l22 * z2)
            }
        }

        public func sample(_ n: Int) -> [Point] {
            var g = SystemRandomNumberGenerator()
            return sample(n, using: &g)
        }
    }

    public let spec: Spec

    public init(json: Data) throws {
        spec = try JSONDecoder().decode(Spec.self, from: json)
    }

    /// Positions every histStep seconds ending at `now`, oldest first, linearly
    /// interpolated from reports sorted by time. Before the first report the
    /// person is assumed to have stood at the first position.
    public func history(track: [TrackPoint], now: Double) -> [Point] {
        precondition(!track.isEmpty)
        var out: [Point] = []
        var j = 0
        for i in stride(from: spec.histN - 1, through: 0, by: -1) {
            let t = now - Double(i) * spec.histStep
            while j < track.count - 1 && track[j + 1].t <= t { j += 1 }
            let a = track[j], b = track[min(j + 1, track.count - 1)]
            if t <= a.t || j == track.count - 1 { out.append(Point(a.x, a.y)) }
            else if t >= b.t { out.append(Point(b.x, b.y)) }
            else {
                let f = (t - a.t) / (b.t - a.t)
                out.append(Point(a.x + f * (b.x - a.x), a.y + f * (b.y - a.y)))
            }
        }
        return out
    }

    /// history: spec.histN positions, spec.histStep s apart, oldest first.
    /// accuracy: accuracyMeters of those positions. horizon: seconds ahead.
    public func predict(history hist: [Point], accuracy: Double, horizon: Double) -> Prediction {
        let n = spec.histN
        precondition(hist.count == n)
        let h = min(spec.hMax, max(spec.hMin, horizon))
        let o = hist[n - 1]
        let d = hist.map { Point($0.x - o.x, $0.y - o.y) }
        var th = 0.0, has = 0.0
        for k in spec.headingLookback {
            let vx = -d[n - 1 - k].x, vy = -d[n - 1 - k].y
            if (vx * vx + vy * vy).squareRoot() >= spec.headingMin { th = atan2(vy, vx); has = 1; break }
        }
        let c = cos(th), s = sin(th)
        var x: [Double] = []
        x.reserveCapacity(2 * n + 2)
        for i in 0..<(n - 1) {
            x.append((c * d[i].x + s * d[i].y) / spec.posScale)
            x.append((-s * d[i].x + c * d[i].y) / spec.posScale)
        }
        x += [log(h) / log(spec.hMax), (h / spec.hMax).squareRoot(), accuracy / spec.accScale, has]

        for (li, layer) in spec.layers.enumerated() {
            var out = layer.b
            for o in out.indices {
                let row = layer.w[o]
                var sum = out[o]
                for i in x.indices { sum += row[i] * x[i] }
                out[o] = li < spec.layers.count - 1 ? sum / (1 + exp(-sum)) : sum
            }
            x = out
        }

        let scale = spec.horizonScale[0] + spec.horizonScale[1] * h
        var logits: [Double] = [], means: [Point] = [], covs: [(xx: Double, xy: Double, yy: Double)] = []
        for k in 0..<spec.K {
            let q = Array(x[(6 * k)..<(6 * k + 6)])
            logits.append(q[0])
            let mx = q[1] * scale, my = q[2] * scale
            let sx = spec.stdFloor + exp(min(3, max(-7, q[3]))) * scale
            let sy = spec.stdFloor + exp(min(3, max(-7, q[4]))) * scale
            let r = 0.95 * tanh(q[5])
            means.append(Point(o.x + c * mx - s * my, o.y + s * mx + c * my))
            let xx = sx * sx, yy = sy * sy, xy = r * sx * sy
            covs.append((c * c * xx - 2 * c * s * xy + s * s * yy,
                         c * s * (xx - yy) + (c * c - s * s) * xy,
                         s * s * xx + 2 * c * s * xy + c * c * yy))
        }
        let m = logits.max()!
        let e = logits.map { exp($0 - m) }
        let z = e.reduce(0, +)
        return Prediction(weights: e.map { $0 / z }, means: means, covs: covs)
    }
}
