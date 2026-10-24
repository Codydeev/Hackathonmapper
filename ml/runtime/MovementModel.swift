// Movement model runtime for iOS. Predicts where a person is likely to be
// h seconds from now, from where they were over the last 60 s and, with a v2
// model, from the map around them and where they planned to go. Used when a
// phone drops out of Bluetooth range: its last known track keeps moving as a
// growing cloud instead of a frozen dot. Foundation only, no Core ML.
//
//   let model = try MovementModel(json: Data(contentsOf: url))      // movement-model-v2.json
//   let map = try MovementModel.MapLayer(png: pngData, meta: metaJSON)  // optional (v2)
//   let hist = model.history(track: reports, now: now)              // [(t, x, y)], seconds + metres
//   let pred = model.predict(history: hist, accuracy: 12, horizon: 60, map: map, destination: nil)
//   let dots = pred.sample(300)                                     // for drawing
//
// Positions are metres in a flat frame. With a map they must be in the map's
// frame: MapLayer.toXY(lat:lon:) converts GPS coordinates. Without a map any
// frame works (the demo's x/z floor plane, or east/north).

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

public struct MovementModel {
    public struct Spec: Decodable {
        public let version: Int?
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
        let patch: PatchSpec?
        let destFar: Double?
        let cnn: [ConvLayer]?
        let cnnFc: Layer?
    }

    struct Layer: Decodable {
        let w: [[Double]]
        let b: [Double]
    }

    struct ConvLayer: Decodable {
        let w: [[[[Double]]]]
        let b: [Double]
        let stride: Int
        let pad: Int
    }

    struct PatchSpec: Decodable {
        let size: Int
        let res: Double
        let ahead: Double
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

    /// The map image the model reads (R paths, G roads, B water) and its frame.
    public struct MapLayer {
        public struct Meta: Decodable {
            public let lat0: Double
            public let lon0: Double
            public let xMin: Double
            public let yMax: Double
            public let res: Double
            public let width: Int
            public let height: Int
        }

        public let meta: Meta
        let pixels: [UInt8]   // width * height * 3, row by row from the north edge

        public init(rgb: [UInt8], meta: Meta) {
            precondition(rgb.count == meta.width * meta.height * 3)
            self.pixels = rgb
            self.meta = meta
        }

        #if canImport(CoreGraphics)
        /// Load the PNG exported next to its meta JSON (ml/export/maps/).
        public init(png: Data, meta metaJSON: Data) throws {
            let meta = try JSONDecoder().decode(Meta.self, from: metaJSON)
            guard let src = CGImageSourceCreateWithData(png as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  img.width == meta.width, img.height == meta.height else {
                throw NSError(domain: "MovementModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "map image does not match its meta"])
            }
            var rgba = [UInt8](repeating: 0, count: meta.width * meta.height * 4)
            let ctx = CGContext(data: &rgba, width: meta.width, height: meta.height, bitsPerComponent: 8,
                                bytesPerRow: meta.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: meta.width, height: meta.height))
            var rgb = [UInt8](repeating: 0, count: meta.width * meta.height * 3)
            for i in 0..<(meta.width * meta.height) {
                rgb[3 * i] = rgba[4 * i]; rgb[3 * i + 1] = rgba[4 * i + 1]; rgb[3 * i + 2] = rgba[4 * i + 2]
            }
            self.init(rgb: rgb, meta: meta)
        }
        #endif

        /// GPS coordinates to this map's metre frame (x east, y north).
        public func toXY(lat: Double, lon: Double) -> Point {
            let r = 6371000.0, rad = Double.pi / 180
            return Point(r * cos(meta.lat0 * rad) * (lon - meta.lon0) * rad, r * (lat - meta.lat0) * rad)
        }

        /// This map's metre frame back to GPS coordinates, for MapKit overlays.
        public func toLatLon(_ p: Point) -> (lat: Double, lon: Double) {
            let r = 6371000.0, deg = 180 / Double.pi
            return (meta.lat0 + p.y / r * deg, meta.lon0 + p.x / (r * cos(meta.lat0 / deg)) * deg)
        }

        func value(row: Int, col: Int, ch: Int) -> Double {
            if row < 0 || col < 0 || row >= meta.height || col >= meta.width { return 0 }
            return Double(pixels[(row * meta.width + col) * 3 + ch]) / 255
        }
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

    /// Everything that does not depend on the horizon: make it once when the
    /// link drops, then call predict(prepared:horizon:) as time passes.
    public struct Prepared {
        let past: [Double]
        let accuracy: Double
        let has: Double
        let th: Double
        public let origin: Point
        let extra: [Double]
        let emb: [Double]
    }

    public let spec: Spec

    public init(json: Data) throws {
        spec = try JSONDecoder().decode(Spec.self, from: json)
    }

    public var usesMap: Bool { spec.cnn != nil }

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

    /// The map patch the model sees: rows from far ahead to behind, columns
    /// from left to right, rotated so the walking direction points up.
    func samplePatch(_ map: MapLayer, origin o: Point, th: Double) -> [Double] {
        let p = spec.patch!, n = p.size, m = map.meta
        var out = [Double](repeating: 0, count: 3 * n * n)
        let c = cos(th), s = sin(th)
        for r in 0..<n {
            for k in 0..<n {
                let u = p.ahead + (Double(n) / 2 - (Double(r) + 0.5)) * p.res
                let v = (Double(n) / 2 - (Double(k) + 0.5)) * p.res
                let x = o.x + c * u - s * v, y = o.y + s * u + c * v
                let col = (x - m.xMin) / m.res - 0.5, row = (m.yMax - y) / m.res - 0.5
                let c0 = Int(col.rounded(.down)), r0 = Int(row.rounded(.down))
                let fc = col - Double(c0), fr = row - Double(r0)
                for ch in 0..<3 {
                    out[(ch * n + r) * n + k] =
                        (1 - fr) * ((1 - fc) * map.value(row: r0, col: c0, ch: ch) + fc * map.value(row: r0, col: c0 + 1, ch: ch))
                        + fr * ((1 - fc) * map.value(row: r0 + 1, col: c0, ch: ch) + fc * map.value(row: r0 + 1, col: c0 + 1, ch: ch))
                }
            }
        }
        return out
    }

    static func silu(_ v: Double) -> Double { v / (1 + exp(-v)) }

    func mapEmbedding(_ patch: [Double]) -> [Double] {
        var input = patch, C = 3, H = spec.patch!.size, W = H
        for layer in spec.cnn! {
            let K = layer.w[0][0].count, O = layer.b.count
            let Ho = (H + 2 * layer.pad - K) / layer.stride + 1, Wo = (W + 2 * layer.pad - K) / layer.stride + 1
            var out = [Double](repeating: 0, count: O * Ho * Wo)
            for o in 0..<O {
                for y in 0..<Ho {
                    for x in 0..<Wo {
                        var sum = layer.b[o]
                        for c in 0..<C {
                            let wk = layer.w[o][c]
                            for ky in 0..<K {
                                let iy = y * layer.stride - layer.pad + ky
                                if iy < 0 || iy >= H { continue }
                                for kx in 0..<K {
                                    let ix = x * layer.stride - layer.pad + kx
                                    if ix < 0 || ix >= W { continue }
                                    sum += wk[ky][kx] * input[(c * H + iy) * W + ix]
                                }
                            }
                        }
                        out[(o * Ho + y) * Wo + x] = Self.silu(sum)
                    }
                }
            }
            input = out; C = O; H = Ho; W = Wo
        }
        let fc = spec.cnnFc!
        return fc.b.indices.map { o in
            var sum = fc.b[o]
            for i in input.indices { sum += fc.w[o][i] * input[i] }
            return Self.silu(sum)
        }
    }

    public func prepare(history hist: [Point], accuracy: Double, map: MapLayer? = nil, destination: Point? = nil) -> Prepared {
        let n = spec.histN
        precondition(hist.count == n)
        let o = hist[n - 1]
        let d = hist.map { Point($0.x - o.x, $0.y - o.y) }
        var th = 0.0, has = 0.0
        for k in spec.headingLookback {
            let vx = -d[n - 1 - k].x, vy = -d[n - 1 - k].y
            if (vx * vx + vy * vy).squareRoot() >= spec.headingMin { th = atan2(vy, vx); has = 1; break }
        }
        let c = cos(th), s = sin(th)
        var past: [Double] = []
        past.reserveCapacity(2 * n)
        for i in 0..<(n - 1) {
            past.append((c * d[i].x + s * d[i].y) / spec.posScale)
            past.append((-s * d[i].x + c * d[i].y) / spec.posScale)
        }
        var extra: [Double] = [], emb: [Double] = []
        if usesMap {
            if let dest = destination {
                let dx = dest.x - o.x, dy = dest.y - o.y, u = c * dx + s * dy, v = -s * dx + c * dy
                let dist = max((u * u + v * v).squareRoot(), 1e-6)
                extra = [u / dist, v / dist, log1p(dist) / log1p(spec.destFar!), 1]
            } else {
                extra = [0, 0, 0, 0]
            }
            extra.append(map == nil ? 0 : 1)
            emb = map.map { mapEmbedding(samplePatch($0, origin: o, th: th)) } ?? [Double](repeating: 0, count: spec.cnnFc!.b.count)
        }
        return Prepared(past: past, accuracy: accuracy, has: has, th: th, origin: o, extra: extra, emb: emb)
    }

    public func predict(prepared p: Prepared, horizon: Double) -> Prediction {
        let h = min(spec.hMax, max(spec.hMin, horizon))
        var x = p.past + [log(h) / log(spec.hMax), (h / spec.hMax).squareRoot(), p.accuracy / spec.accScale, p.has] + p.extra + p.emb
        for (li, layer) in spec.layers.enumerated() {
            var out = layer.b
            for o in out.indices {
                let row = layer.w[o]
                var sum = out[o]
                for i in x.indices { sum += row[i] * x[i] }
                out[o] = li < spec.layers.count - 1 ? Self.silu(sum) : sum
            }
            x = out
        }
        let scale = spec.horizonScale[0] + spec.horizonScale[1] * h
        let c = cos(p.th), s = sin(p.th), o = p.origin
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

    /// history: spec.histN positions, spec.histStep s apart, oldest first.
    /// accuracy: accuracyMeters of those positions. horizon: seconds ahead.
    /// map, destination: optional, used by v2 models.
    public func predict(history: [Point], accuracy: Double, horizon: Double,
                        map: MapLayer? = nil, destination: Point? = nil) -> Prediction {
        predict(prepared: prepare(history: history, accuracy: accuracy, map: map, destination: destination), horizon: horizon)
    }
}
