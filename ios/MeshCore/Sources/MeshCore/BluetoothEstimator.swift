import Foundation

// Places phones that have no position (positionSource "none") from the Bluetooth signal strength
// (RSSI) of the links they and their neighbours report, hop by hop from phones that do have one.
// The particle filter tested in the Luotsi prototype; GhostCore's baseline positioning engine
// (GhostCorePipeline.EstimatorPositioning, the "baseline" scenario run). The dashboard and the
// phone's Track view place phones with SignalMap instead; the TypeScript twin was retired with it.
//
// Each phone's belief is a weighted cloud of particles on the floor plane (x east, z north):
//   - anchor (GPS or manual position): a cloud around that position
//   - lost phone with history: last cloud, spread a little each second, kept from drifting by
//     the RSSI of every heard neighbour (sampled from that neighbour's own cloud, so uncertainty
//     grows with every hop) and by the phones it can NOT hear
//   - lost phone with no history: a ring around the first neighbour it hears. RSSI gives
//     distance, not direction: one neighbour leaves a ring, two leave two spots, three a point.

// RadioModel and FloorPoint live in SignalMap.swift (one radio model for the app and the dashboard).
extension RadioModel {
    /// The estimator's name for the standard model: phones outdoors with some foliage.
    public static let outdoors = RadioModel.standard

    /// Chance that one second of listening hears a phone `d` metres away.
    public func hearProbability(atDistance d: Double) -> Double { 1 / (1 + exp((d - range) / soft)) }
}

/// One RSSI reading for the link between phones `a` and `b`.
public struct LinkMeasurement: Equatable {
    public let a: String
    public let b: String
    public let rssi: Double
    /// Mean UWB distance of the ends that measured one (wire v5), m; nil for an RSSI-only link.
    /// The particle filter ignores it; `SignalMapPositioning` uses it.
    public let uwb: Double?

    public init(a: String, b: String, rssi: Double, uwb: Double? = nil) {
        self.a = a
        self.b = b
        self.rssi = rssi
        self.uwb = uwb
    }
}

/// A phone with a position (GPS or manual). `accuracy` is its reported ~68 % radius.
public struct EstimatorAnchor: Equatable {
    public let id: String
    public let x: Double
    public let z: Double
    public let accuracy: Double?

    public init(id: String, x: Double, z: Double, accuracy: Double?) {
        self.id = id
        self.x = x
        self.z = z
        self.accuracy = accuracy
    }
}

public struct BluetoothEstimate: Equatable {
    public let x: Double
    public let z: Double
    /// Radius around (x, z) holding 95 % of the belief.
    public let r95: Double
    /// Ring or two separate spots: the centre is not a good guess.
    public let ambiguous: Bool
    /// Hops to the nearest anchor; nil when not connected to one.
    public let hops: Int?
    /// A sample of the particle cloud for drawing.
    public let cloud: [FloorPoint]
}

/// Seeded PRNG (mulberry32) with a Gaussian helper, so estimates are repeatable in tests.
struct SeededRandom {
    private var state: UInt32

    init(seed: UInt32) { state = seed }

    mutating func next() -> Double {
        state = state &+ 0x6d2b_79f5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }

    mutating func gauss() -> Double {
        let u = max(next(), 1e-12)
        let v = next()
        return (-2 * log(u)).squareRoot() * cos(2 * Double.pi * v)
    }
}

public final class BluetoothEstimator {
    public struct Options {
        public var particles = 600
        /// Neighbour particles averaged per likelihood.
        public var samples = 6
        /// Readings of the same link a second apart are strongly correlated.
        public var temper = 0.15
        /// Max weight of "I can't hear you, so I'm probably not next to you".
        public var silence = 0.85
        /// Cold-start phones: fraction re-drawn on rings each second...
        public var reset = 0.03
        /// ...during their first seconds only.
        public var resetFor = 15
        /// Weight of a neighbour no closer to an anchor and no surer than us.
        public var sideways = 0.3
        /// m per second a phone may move without us knowing (no step data).
        public var jitter = 0.8
        public var cloudPoints = 150
        public var radio = RadioModel.outdoors
        public var seed: UInt32 = 5

        public init() {}
    }

    private final class Node {
        let id: String
        var anchor: (x: Double, y: Double, sigma: Double)?
        var px: [Double]
        var py: [Double]
        var w: [Double]
        var cdf: [Double]?
        var ready = false
        var cold = false
        var coldAge = 0
        var est: (x: Double, y: Double, r95: Double, ambiguous: Bool)?
        /// Infinity when not connected to an anchor, as in the TypeScript original.
        var hops = Double.infinity
        var links: [(to: String, rssi: Double)] = []

        init(id: String, particles: Int) {
            self.id = id
            px = Array(repeating: 0, count: particles)
            py = Array(repeating: 0, count: particles)
            w = Array(repeating: 1 / Double(particles), count: particles)
        }
    }

    private let o: Options
    private let N: Int
    private var rand: SeededRandom
    /// Insertion order is kept, like the JavaScript Map, so a run is repeatable.
    private var nodes: [String: Node] = [:]
    private var order: [String] = []

    public init(options: Options = Options()) {
        o = options
        N = options.particles
        rand = SeededRandom(seed: options.seed)
    }

    private var orderedNodes: [Node] { order.compactMap { nodes[$0] } }

    /// One second of evidence. `anchors` are phones with a position; `lost` are phones without one;
    /// every other id is forgotten.
    public func update(anchors: [EstimatorAnchor], lost: [String],
                       measurements: [LinkMeasurement]) -> [String: BluetoothEstimate] {
        let keep = Set(anchors.map(\.id) + lost)
        order.removeAll { !keep.contains($0) }
        nodes = nodes.filter { keep.contains($0.key) }
        for id in anchors.map(\.id) + lost where nodes[id] == nil {
            nodes[id] = Node(id: id, particles: N)
            order.append(id)
        }
        for id in lost { nodes[id]?.anchor = nil }
        for a in anchors {
            // Accuracy is a ~68 % radius; never trust a fix to better than 2 m here.
            nodes[a.id]?.anchor = (a.x, a.z, max(2, a.accuracy ?? 5))
        }
        step(measurements)

        var out: [String: BluetoothEstimate] = [:]
        for id in lost {
            guard let n = nodes[id], n.ready, let est = n.est else { continue }
            out[id] = BluetoothEstimate(x: est.x, z: est.y, r95: est.r95, ambiguous: est.ambiguous,
                                        hops: n.hops.isFinite ? Int(n.hops) : nil, cloud: sampleCloud(n))
        }
        return out
    }

    private func g() -> Double { rand.gauss() }

    private func buildCdf(_ n: Node) {
        var c = n.cdf ?? Array(repeating: 0, count: N)
        var s = 0.0
        for k in 0..<N {
            s += n.w[k]
            c[k] = s
        }
        n.cdf = c
    }

    private func pick(_ n: Node) -> Int {
        guard let cdf = n.cdf else { return Int(rand.next() * Double(N)) }
        let u = rand.next() * cdf[N - 1]
        var lo = 0
        var hi = N - 1
        while lo < hi {
            let mid = (lo + hi) >> 1
            if cdf[mid] < u { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func ringSample(_ n: Node, _ k: Int, _ nb: Node, _ rssi: Double) {
        let q = pick(nb)
        let d = o.radio.distance(forRSSI: rssi + o.radio.sigma * g())
        let th = rand.next() * 2 * Double.pi
        n.px[k] = nb.px[q] + d * sin(th)
        n.py[k] = nb.py[q] + d * cos(th)
    }

    private func summarize(_ n: Node) {
        var mx = 0.0
        var my = 0.0
        var sw = 0.0
        for k in 0..<N {
            mx += n.w[k] * n.px[k]
            my += n.w[k] * n.py[k]
            sw += n.w[k]
        }
        mx /= sw
        my /= sw
        var dist = Array(repeating: 0.0, count: N)
        for k in 0..<N { dist[k] = hypot(n.px[k] - mx, n.py[k] - my) }
        let idx = (0..<N).sorted { dist[$0] < dist[$1] }
        var r95 = dist[idx[N - 1]]
        var acc = 0.0
        for k in idx {
            acc += n.w[k] / sw
            if acc >= 0.95 {
                r95 = dist[k]
                break
            }
        }
        // A ring or two separate blobs has almost no weight near its centre.
        var core = 0.0
        for k in 0..<N where dist[k] < 0.25 * r95 { core += n.w[k] / sw }
        n.est = (mx, my, r95, r95 > 15 && core < 0.05)
    }

    private func resample(_ n: Node) {
        var nx = Array(repeating: 0.0, count: N)
        var ny = Array(repeating: 0.0, count: N)
        let sum = n.w.reduce(0, +)
        let stepSize = sum / Double(N)
        var u = rand.next() * stepSize
        var c = n.w[0]
        var i = 0
        for k in 0..<N {
            while u > c && i < N - 1 {
                i += 1
                c += n.w[i]
            }
            nx[k] = n.px[i] + 0.5 * g()
            ny[k] = n.py[i] + 0.5 * g()
            u += stepSize
        }
        n.px = nx
        n.py = ny
        n.w = Array(repeating: 1 / Double(N), count: N)
    }

    private func sampleCloud(_ n: Node) -> [FloorPoint] {
        (0..<o.cloudPoints).map { _ in
            let k = pick(n)
            return FloorPoint(x: n.px[k], z: n.py[k])
        }
    }

    private func step(_ measurements: [LinkMeasurement]) {
        let radio = o.radio
        let all = orderedNodes
        for n in all { n.links = [] }
        for m in measurements {
            guard let a = nodes[m.a], let b = nodes[m.b], a !== b else { continue }
            a.links.append((b.id, m.rssi))
            b.links.append((a.id, m.rssi))
        }

        // Anchors: a cloud around their position.
        for n in all {
            guard let anchor = n.anchor else { continue }
            for k in 0..<N {
                n.px[k] = anchor.x + anchor.sigma * g()
                n.py[k] = anchor.y + anchor.sigma * g()
            }
            n.w = Array(repeating: 1 / Double(N), count: N)
            n.cdf = nil
            n.ready = true
            n.cold = false
        }

        // Hop count from the nearest anchor.
        for n in all { n.hops = n.anchor == nil ? .infinity : 0 }
        var queue = all.filter { $0.anchor != nil }
        while !queue.isEmpty {
            let n = queue.removeFirst()
            for l in n.links {
                guard let m = nodes[l.to] else { continue }
                if m.hops > n.hops + 1 {
                    m.hops = n.hops + 1
                    queue.append(m)
                }
            }
        }

        // Lost phones, closest to an anchor first so information flows outward (stable order).
        let lost = all.enumerated()
            .filter { $0.element.anchor == nil }
            .sorted { $0.element.hops != $1.element.hops ? $0.element.hops < $1.element.hops : $0.offset < $1.offset }
            .map(\.element)
        var logw = Array(repeating: 0.0, count: N)
        for n in lost {
            if n.ready {
                for k in 0..<N {
                    n.px[k] += o.jitter * g()
                    n.py[k] += o.jitter * g()
                }
            }

            let known = n.links.filter { nodes[$0.to]?.ready == true }
            if !n.ready {
                guard !known.isEmpty else { continue }
                let first = known.dropFirst().reduce(known[0]) { a, b in
                    nodes[a.to]!.hops <= nodes[b.to]!.hops ? a : b
                }
                let source = nodes[first.to]!
                for k in 0..<N { ringSample(n, k, source, first.rssi) }
                n.w = Array(repeating: 1 / Double(N), count: N)
                n.ready = true
                n.cold = true
                n.coldAge = 0
            } else if n.cold && !known.isEmpty {
                n.coldAge += 1
                if n.coldAge < o.resetFor {
                    let resets = Int((o.reset * Double(N)).rounded())
                    for _ in 0..<resets {
                        let l = known[Int(rand.next() * Double(known.count))]
                        let k = Int(rand.next() * Double(N))
                        ringSample(n, k, nodes[l.to]!, l.rssi)
                        n.w[k] = 1 / Double(N)
                    }
                }
            }

            // Weigh: every heard neighbour, and every settled phone we cannot hear.
            let heard = Set(n.links.map(\.to))
            let silent = all.filter { m in
                m !== n && m.ready && !heard.contains(m.id) && (m.est.map { $0.r95 < 2 * radio.range } ?? false)
            }
            if !known.isEmpty || !silent.isEmpty {
                let neighbours = known.map { l -> (node: Node, rssi: Double, weight: Double) in
                    let nb = nodes[l.to]!
                    var upstream = nb.hops < n.hops
                    if !upstream, let nbEst = nb.est, let nEst = n.est { upstream = nbEst.r95 < 0.7 * nEst.r95 }
                    return (nb, l.rssi, upstream ? 1 : o.sideways)
                }
                for k in 0..<N {
                    var lw = 0.0
                    for (nb, rssi, weight) in neighbours {
                        var p = 0.0
                        for _ in 0..<o.samples {
                            let q = pick(nb)
                            let d = hypot(n.px[k] - nb.px[q], n.py[k] - nb.py[q])
                            let z = (rssi - radio.expectedRSSI(atDistance: d)) / radio.sigma
                            p += exp(-0.5 * z * z)
                        }
                        lw += weight * log(p / Double(o.samples) + 1e-12)
                    }
                    for m in silent {
                        var p = 0.0
                        for _ in 0..<o.samples {
                            let q = pick(m)
                            p += 1 - o.silence * radio.hearProbability(atDistance: hypot(n.px[k] - m.px[q], n.py[k] - m.py[q]))
                        }
                        lw += log(p / Double(o.samples))
                    }
                    logw[k] = log(n.w[k] + 1e-300) + o.temper * lw
                }
                let maxLog = logw.max() ?? 0
                var sum = 0.0
                for k in 0..<N {
                    n.w[k] = exp(logw[k] - maxLog)
                    sum += n.w[k]
                }
                var ess = 0.0
                for k in 0..<N {
                    n.w[k] /= sum
                    ess += n.w[k] * n.w[k]
                }
                if 1 / ess < Double(N) / 2 { resample(n) }
            }
            buildCdf(n)
            summarize(n)
            if n.cold, let est = n.est, est.r95 < 20 { n.cold = false } // ring resolved: stop re-seeding
        }
        for n in all where n.anchor != nil { summarize(n) }
    }
}

extension BluetoothEstimator {
    public struct Input: Equatable {
        public let anchors: [EstimatorAnchor]
        public let lost: [String]
        public let measurements: [LinkMeasurement]
    }

    /// Estimator input from the latest mesh reports, built as the dashboard builds it: fresh
    /// reports with a GPS or manual position are anchors, fresh `none` reports are lost phones,
    /// and each pair of phones gets one RSSI, the mean of what either end reported recently.
    public static func input(reports: [DeviceUpdate], receivedAt: [String: Date], now: Date,
                             reportMaxAge: TimeInterval, linkMaxAge: TimeInterval) -> Input {
        let fresh = reports
            .filter { update in receivedAt[update.id].map { now.timeIntervalSince($0) <= reportMaxAge } ?? false }
            .sorted { $0.id < $1.id }
        var anchors: [EstimatorAnchor] = []
        var lost: [String] = []
        for update in fresh {
            if update.positionSource == PositionSource.none {
                lost.append(update.id)
            } else {
                // A missing source comes from an older build and means manual.
                anchors.append(EstimatorAnchor(id: update.id, x: update.position.x, z: update.position.z,
                                               accuracy: update.accuracyMeters))
            }
        }

        var pairs: [String: (a: String, b: String, sum: Double, count: Int, uwbSum: Double, uwbCount: Int)] = [:]
        for update in fresh {
            let reportAge = now.timeIntervalSince(receivedAt[update.id] ?? now)
            for neighbor in update.neighbors ?? [] {
                guard let rssi = neighbor.rssi,
                      reportAge + Double(neighbor.ageMs ?? 0) / 1000 <= linkMaxAge else { continue }
                let (a, b) = update.id < neighbor.id ? (update.id, neighbor.id) : (neighbor.id, update.id)
                let key = a + "\n" + b
                var pair = pairs[key] ?? (a, b, 0, 0, 0, 0)
                pair.sum += Double(rssi)
                pair.count += 1
                if let uwb = neighbor.uwbDistanceM, uwb.isFinite, uwb >= 0 {
                    pair.uwbSum += uwb
                    pair.uwbCount += 1
                }
                pairs[key] = pair
            }
        }
        let measurements = pairs.keys.sorted().compactMap { key in
            pairs[key].map {
                LinkMeasurement(a: $0.a, b: $0.b, rssi: $0.sum / Double($0.count),
                                uwb: $0.uwbCount > 0 ? $0.uwbSum / Double($0.uwbCount) : nil)
            }
        }
        return Input(anchors: anchors, lost: lost, measurements: measurements)
    }
}
