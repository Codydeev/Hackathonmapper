import Foundation

// Places phones that have no position (positionSource "none") from the Bluetooth signal strength
// (RSSI) and UWB distances of the links they and their neighbours report, hop by hop from phones
// that do have one. Swift port of website/server/estimator.ts (the particle filter tested in the
// Luotsi prototype), extended with UWB ranges and bearings. MeshLocator runs it to seed lost phones
// and to tell a ring or two spots from a fix; LayoutSolver does the joint geometry on UWB links.
//
// Each phone's belief is a weighted cloud of particles on the floor plane (x east, z north):
//   - anchor (GPS, manual or UWB-fix position): a cloud around that position
//   - lost phone with history: last cloud, spread a little each second, kept from drifting by
//     every heard neighbour (sampled from that neighbour's own cloud, so uncertainty grows with
//     every hop) and by the phones it can NOT hear
//   - lost phone with no history: a ring around the first neighbour it hears. A range gives
//     distance, not direction: one neighbour leaves a ring, two leave two spots, three a point.
//     A UWB bearing turns the ring into an arc.

public struct RadioModel: Equatable {
    /// dBm received at 1 m.
    public var p0: Double
    /// Path-loss exponent.
    public var n: Double
    /// dB spread of a one-second averaged RSSI reading, including phone-model differences.
    public var sigma: Double
    /// m at which half of the one-second windows still hear the phone.
    public var range: Double
    /// m over which reception fades out.
    public var soft: Double

    public init(p0: Double, n: Double, sigma: Double, range: Double, soft: Double) {
        self.p0 = p0
        self.n = n
        self.sigma = sigma
        self.range = range
        self.soft = soft
    }

    /// Defaults for phones outdoors with some foliage; calibrate with measured RSSI-vs-distance.
    public static let outdoors = RadioModel(p0: -59, n: 2.5, sigma: 5, range: 60, soft: 8)

    public func expectedRSSI(atDistance d: Double) -> Double { p0 - 10 * n * log10(max(0.5, d)) }
    public func distance(forRSSI rssi: Double) -> Double { pow(10, (p0 - rssi) / (10 * n)) }
    public func hearProbability(atDistance d: Double) -> Double { 1 / (1 + exp((d - range) / soft)) }
}

/// A point on the floor plane of the shared frame: x east, z north, meters.
public struct FloorPoint: Equatable {
    public let x: Double
    public let z: Double

    public init(x: Double, z: Double) {
        self.x = x
        self.z = z
    }
}

/// What is known this second about the link between phones `a` and `b`: the mean RSSI, the mean
/// UWB distance (m) and a UWB bearing from `a` toward `b`. A bearing comes only with a distance.
public struct LinkMeasurement: Equatable {
    public let a: String
    public let b: String
    public let rssi: Double?
    public let uwbDistance: Double?
    public let bearing: LinkBearing?

    public init(a: String, b: String, rssi: Double? = nil, uwbDistance: Double? = nil, bearing: LinkBearing? = nil) {
        self.a = a
        self.b = b
        self.rssi = rssi
        self.uwbDistance = uwbDistance
        self.bearing = bearing
    }
}

/// A phone with a position (GPS, manual or UWB fix). `accuracy` is its reported ~68 % radius.
public struct EstimatorAnchor: Equatable {
    public let id: String
    public let x: Double
    public let z: Double
    public let accuracy: Double?
    public let source: PositionSource

    public init(id: String, x: Double, z: Double, accuracy: Double?, source: PositionSource = .manual) {
        self.id = id
        self.x = x
        self.z = z
        self.accuracy = accuracy
        self.source = source
    }

    /// 1-sigma error of the position. GPS is never trusted to better than 2 m; a typed spot or a
    /// UWB anchor fix is good to about 0.3 m unless it says otherwise.
    public var sigma: Double {
        switch source {
        case .gps, .none: return max(2, accuracy ?? 5)
        case .manual, .uwb: return max(0.3, accuracy ?? 0.3)
        }
    }
}

public struct BluetoothEstimate: Equatable {
    public let x: Double
    public let z: Double
    /// Radius around (x, z) holding 95 % of the belief.
    public let r95: Double
    /// Ring or two separate spots: the centre is not a good guess.
    public let ambiguous: Bool
    /// When ambiguous: the neighbour the phone is on a ring around, and the measured distance.
    public let ring: EstimateRing?
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
        /// A phone with this many links may have no free link slot (BluetoothMesh caps them at 8),
        /// so "not linked" says nothing about distance: no silence penalty on either side.
        public var silenceMaxLinks = 6
        /// Cold-start phones: fraction re-drawn on rings each second...
        public var reset = 0.03
        /// ...during their first seconds only.
        public var resetFor = 15
        /// Weight of a neighbour no closer to an anchor and no surer than us.
        public var sideways = 0.3
        /// m per second a phone may move without us knowing (no step data).
        public var jitter = 0.8
        /// The same with a UWB link, which pins the phone down again every second.
        public var uwbJitter = 0.4
        /// UWB links replace RSSI: more neighbour particles per likelihood, far less tempering.
        public var uwbSamples = 24
        public var uwbTemper = 0.6
        /// m added (in quadrature) to the UWB error for the spacing of the neighbour's particles.
        public var uwbSpread = 0.5
        /// Likelihood floor of a UWB range, so one body-blocked reading cannot wipe out the cloud.
        public var uwbFloor = 0.01
        /// An estimate is a ring or two spots when its r95 is above this and < 5 % of it is near the centre.
        public var ambiguousRadius = 3.0
        public var cloudPoints = 150
        public var radio = RadioModel.outdoors
        public var seed: UInt32 = 5

        public init() {}
    }

    /// One link as seen from a node. `bearing` points from `to` toward the node itself.
    private struct Link {
        let to: String
        let rssi: Double?
        let uwb: Double?
        let bearing: LinkBearing?
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
        var ring: EstimateRing?
        /// Infinity when not connected to an anchor, as in the TypeScript original.
        var hops = Double.infinity
        var links: [Link] = []

        init(id: String, particles: Int) {
            self.id = id
            px = Array(repeating: 0, count: particles)
            py = Array(repeating: 0, count: particles)
            w = Array(repeating: 1 / Double(particles), count: particles)
        }
    }

    private var o: Options
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

    /// The radio model for RSSI links; MeshLocator replaces it as RadioCalibrator learns p0.
    public var radio: RadioModel {
        get { o.radio }
        set { o.radio = newValue }
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
        for a in anchors { nodes[a.id]?.anchor = (a.x, a.z, a.sigma) }
        step(measurements)

        var out: [String: BluetoothEstimate] = [:]
        for id in lost {
            guard let n = nodes[id], n.ready, let est = n.est else { continue }
            out[id] = BluetoothEstimate(x: est.x, z: est.y, r95: est.r95, ambiguous: est.ambiguous,
                                        ring: est.ambiguous ? n.ring : nil,
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

    /// Draws particle `k` of `n` at the link's distance from a particle of `nb`: the UWB distance
    /// when there is one (in the bearing's direction when there is one), else the RSSI distance.
    private func ringSample(_ n: Node, _ k: Int, _ nb: Node, _ link: Link) {
        let q = pick(nb)
        let d: Double
        var th = rand.next() * 2 * Double.pi
        if let uwb = link.uwb {
            d = max(0.05, uwb + LayoutSolver.uwbSigma(distance: uwb) * g())
            if let bearing = link.bearing {
                th = (bearing.degrees + bearing.errorDegrees * g()) * Double.pi / 180
            }
        } else if let rssi = link.rssi {
            d = o.radio.distance(forRSSI: rssi + o.radio.sigma * g())
        } else {
            return
        }
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
        n.est = (mx, my, r95, r95 > o.ambiguousRadius && core < 0.05)
    }

    /// The ring an ambiguous phone is on: around the neighbour with a UWB distance, else the one
    /// closest to an anchor, else the nearest; the radius is the measured distance.
    private func ring(for n: Node, _ known: [Link]) -> EstimateRing? {
        func key(_ l: Link, _ radius: Double) -> (Int, Double, Double) {
            (l.uwb == nil ? 1 : 0, nodes[l.to]?.hops ?? Double.infinity, radius)
        }
        let measured = known.compactMap { l -> (link: Link, radius: Double)? in
            if let uwb = l.uwb { return (l, uwb) }
            guard let rssi = l.rssi else { return nil }
            return (l, o.radio.distance(forRSSI: rssi))
        }
        guard let best = measured.min(by: { key($0.link, $0.radius) < key($1.link, $1.radius) }),
              let nb = nodes[best.link.to] else { return nil }
        let center: FloorPoint
        if let anchor = nb.anchor {
            center = FloorPoint(x: anchor.x, z: anchor.y)
        } else if let est = nb.est {
            center = FloorPoint(x: est.x, z: est.y)
        } else {
            return nil
        }
        return EstimateRing(around: nb.id, center: center, radius: best.radius)
    }

    private func resample(_ n: Node, spread: Double) {
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
            nx[k] = n.px[i] + spread * g()
            ny[k] = n.py[i] + spread * g()
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
            let uwb = m.uwbDistance.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            guard let a = nodes[m.a], let b = nodes[m.b], a !== b, m.rssi != nil || uwb != nil else { continue }
            let bearing = uwb == nil ? nil : m.bearing
            // Each end keeps the bearing from the other end toward itself.
            a.links.append(Link(to: b.id, rssi: m.rssi, uwb: uwb, bearing: bearing?.reversed))
            b.links.append(Link(to: a.id, rssi: m.rssi, uwb: uwb, bearing: bearing))
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
            n.ring = nil
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
            let hasUWB = n.links.contains { $0.uwb != nil }
            if n.ready {
                let jitter = hasUWB ? o.uwbJitter : o.jitter
                for k in 0..<N {
                    n.px[k] += jitter * g()
                    n.py[k] += jitter * g()
                }
            }

            let known = n.links.filter { nodes[$0.to]?.ready == true }
            if !n.ready {
                guard !known.isEmpty else { continue }
                // Seed from a UWB distance when there is one, else from the neighbour closest to an anchor.
                func rank(_ l: Link) -> (Int, Double) { (l.uwb == nil ? 1 : 0, nodes[l.to]!.hops) }
                let first = known.dropFirst().reduce(known[0]) { a, b in rank(a) <= rank(b) ? a : b }
                let source = nodes[first.to]!
                for k in 0..<N { ringSample(n, k, source, first) }
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
                        ringSample(n, k, nodes[l.to]!, l)
                        n.w[k] = 1 / Double(N)
                    }
                }
            }

            // Weigh: every heard neighbour, and every settled phone we cannot hear unless either
            // side may be out of link slots.
            let heard = Set(n.links.map(\.to))
            let silent: [Node] = n.links.count >= o.silenceMaxLinks ? [] : all.filter { m in
                m !== n && m.ready && !heard.contains(m.id) && m.links.count < o.silenceMaxLinks
                    && (m.est.map { $0.r95 < 2 * radio.range } ?? false)
            }
            if !known.isEmpty || !silent.isEmpty {
                let neighbours = known.map { l -> (node: Node, link: Link, weight: Double) in
                    let nb = nodes[l.to]!
                    var upstream = nb.hops < n.hops
                    if !upstream, let nbEst = nb.est, let nEst = n.est { upstream = nbEst.r95 < 0.7 * nEst.r95 }
                    return (nb, l, upstream ? 1 : o.sideways)
                }
                for k in 0..<N {
                    var lw = 0.0
                    for (nb, link, weight) in neighbours {
                        if let uwb = link.uwb {
                            // UWB replaces RSSI on this link: Gaussian in distance, and in angle with a bearing.
                            let su = LayoutSolver.uwbSigma(distance: uwb)
                            let s = (su * su + o.uwbSpread * o.uwbSpread).squareRoot()
                            let bearing = link.bearing.map {
                                (angle: $0.degrees * Double.pi / 180, error: max(1, $0.errorDegrees) * Double.pi / 180)
                            }
                            var p = 0.0
                            for _ in 0..<o.uwbSamples {
                                let q = pick(nb)
                                let dx = n.px[k] - nb.px[q]
                                let dz = n.py[k] - nb.py[q]
                                let z = (hypot(dx, dz) - uwb) / s
                                var e = z * z
                                if let bearing {
                                    let a = wrappedAngle(atan2(dx, dz) - bearing.angle) / bearing.error
                                    e += a * a
                                }
                                p += exp(-0.5 * e)
                            }
                            lw += o.uwbTemper * weight * log(p / Double(o.uwbSamples) + o.uwbFloor)
                        } else if let rssi = link.rssi {
                            var p = 0.0
                            for _ in 0..<o.samples {
                                let q = pick(nb)
                                let d = hypot(n.px[k] - nb.px[q], n.py[k] - nb.py[q])
                                let z = (rssi - radio.expectedRSSI(atDistance: d)) / radio.sigma
                                p += exp(-0.5 * z * z)
                            }
                            lw += o.temper * weight * log(p / Double(o.samples) + 1e-12)
                        }
                    }
                    for m in silent {
                        var p = 0.0
                        for _ in 0..<o.samples {
                            let q = pick(m)
                            p += 1 - o.silence * radio.hearProbability(atDistance: hypot(n.px[k] - m.px[q], n.py[k] - m.py[q]))
                        }
                        lw += o.temper * log(p / Double(o.samples))
                    }
                    logw[k] = log(n.w[k] + 1e-300) + lw
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
                if 1 / ess < Double(N) / 2 { resample(n, spread: hasUWB ? 0.2 : 0.5) }
            }
            buildCdf(n)
            summarize(n)
            n.ring = n.est?.ambiguous == true ? ring(for: n, known) : nil
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

        public init(anchors: [EstimatorAnchor], lost: [String], measurements: [LinkMeasurement]) {
            self.anchors = anchors
            self.lost = lost
            self.measurements = measurements
        }
    }

    private struct PairEvidence {
        let a: String
        let b: String
        var rssiSum = 0.0
        var rssiCount = 0
        var uwbSum = 0.0
        var uwbCount = 0
        /// From `a` toward `b`.
        var bearing: LinkBearing?
    }

    /// Estimator input from the latest mesh reports, built as the dashboard builds it: fresh
    /// reports with a GPS, manual or UWB-fix position are anchors, fresh `none` reports are lost
    /// phones, and each pair of phones gets the mean RSSI and the mean UWB distance of what either
    /// end reported recently, plus the bearing with the smaller error, turned to point from a to b.
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
                                               accuracy: update.accuracyMeters,
                                               source: update.positionSource ?? .manual))
            }
        }

        var pairs: [String: PairEvidence] = [:]
        for update in fresh {
            let reportAge = now.timeIntervalSince(receivedAt[update.id] ?? now)
            for neighbor in update.neighbors ?? [] {
                let uwb = neighbor.uwbDistanceM.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                guard neighbor.rssi != nil || uwb != nil,
                      reportAge + Double(neighbor.ageMs ?? 0) / 1000 <= linkMaxAge else { continue }
                let reporterIsA = update.id < neighbor.id
                let (a, b) = reporterIsA ? (update.id, neighbor.id) : (neighbor.id, update.id)
                let key = a + "\n" + b
                var pair = pairs[key] ?? PairEvidence(a: a, b: b)
                if let rssi = neighbor.rssi {
                    pair.rssiSum += Double(rssi)
                    pair.rssiCount += 1
                }
                if let uwb {
                    pair.uwbSum += uwb
                    pair.uwbCount += 1
                    if let degrees = neighbor.uwbBearingDeg, degrees.isFinite {
                        let error = neighbor.uwbBearingErrorDeg.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 30
                        let measured = LinkBearing(degrees: degrees, errorDegrees: error)
                        let aToB = reporterIsA ? measured : measured.reversed
                        if pair.bearing.map({ aToB.errorDegrees < $0.errorDegrees }) ?? true { pair.bearing = aToB }
                    }
                }
                pairs[key] = pair
            }
        }
        let measurements = pairs.keys.sorted().compactMap { key -> LinkMeasurement? in
            guard let pair = pairs[key] else { return nil }
            let uwb = pair.uwbCount > 0 ? pair.uwbSum / Double(pair.uwbCount) : nil
            return LinkMeasurement(a: pair.a, b: pair.b,
                                   rssi: pair.rssiCount > 0 ? pair.rssiSum / Double(pair.rssiCount) : nil,
                                   uwbDistance: uwb, bearing: uwb == nil ? nil : pair.bearing)
        }
        return Input(anchors: anchors, lost: lost, measurements: measurements)
    }
}
