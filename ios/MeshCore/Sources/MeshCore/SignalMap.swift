import Foundation

// Signal map: lays phones out on the floor plane so that their distances match the Bluetooth
// ranges measured between them (RSSI turned into meters with the shared radio model). Phones that
// report a position (GPS, UWB, manual, fused) pull the layout towards it with their own accuracy,
// so one solver serves both views:
//   - relative: no placed phone in the group; distances are right, orientation is arbitrary.
//   - pinned: the placed phones don't fix the group's rotation; distances are right, directions not.
//   - world: the placed phones fix the rotation; the layout is in the shared frame.
// Distances read off any view therefore agree with the radio, instead of being the difference of
// two absolute positions that each carry GPS error.
//
// Line-by-line port of website/shared/signalmap.ts, so a phone and the dashboard draw the same
// map; SignalMapTests replays its golden cases (signalmap-golden.json).

/// Log-distance radio model: RSSI = p0 - 10 n log10(d). The single model for every RSSI distance,
/// mirrored by `RADIO_MODEL` in website/shared/contract.ts. Keep the two identical.
public struct RadioModel: Equatable, Codable {
    /// dBm received at 1 m.
    public var p0: Double
    /// Path-loss exponent.
    public var n: Double
    /// dB spread of a smoothed RSSI reading, including phone-model differences.
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

    /// Real phones. Short-range distances from it were checked to about a meter on the Track tab.
    public static let standard = RadioModel(p0: -59, n: 2.5, sigma: 5, range: 60, soft: 8)

    public func expectedRSSI(atDistance d: Double) -> Double { p0 - 10 * n * log10(max(0.5, d)) }
    public func distance(forRSSI rssi: Double) -> Double { pow(10, (p0 - rssi) / (10 * n)) }
}

/// A point on the floor plane of the shared frame, meters.
public struct FloorPoint: Equatable, Codable {
    public let x: Double
    public let z: Double

    public init(x: Double, z: Double) {
        self.x = x
        self.z = z
    }
}

public struct SignalLink: Equatable, Codable {
    public let a: String
    public let b: String
    /// Mean RSSI of the link in dBm (both directions averaged by the caller).
    public let rssi: Double

    public init(a: String, b: String, rssi: Double) {
        self.a = a
        self.b = b
        self.rssi = rssi
    }
}

public struct SignalPrior: Equatable, Codable {
    public let id: String
    public let x: Double
    public let z: Double
    /// Reported 95 % radius in meters; nil when unknown.
    public let r95: Double?

    public init(id: String, x: Double, z: Double, r95: Double?) {
        self.id = id
        self.x = x
        self.z = z
        self.r95 = r95
    }
}

public enum SignalFrame: String, Codable {
    case world, pinned, relative
}

public struct SignalNode: Equatable, Codable {
    public let id: String
    public var x: Double
    public var z: Double
    /// False for a phone with neither a link nor a position of its own: it has no place yet.
    public var placed: Bool
    /// 95 % radius around (x, z); for a ring, around `ringCenter`.
    public var r95: Double
    public var hasPrior: Bool
    /// Index of the connected group, in order of each group's smallest id.
    public var component: Int
    public var frame: SignalFrame
    public var degree: Int
    /// Direction unknown: the phone is somewhere on a circle of `ringRadius` around `ringCenter`.
    public var ringCenter: String?
    public var ringRadius: Double?
    /// Links to the nearest phone with a position; nil when the group has none.
    public var hops: Int?
}

public struct SignalEdge: Equatable, Codable {
    public let a: String
    public let b: String
    public let rssi: Double
    /// Distance from RSSI, m.
    public let measured: Double
    /// One-sigma error of `measured`, m.
    public let sigma: Double
    /// Distance in the solved layout, m.
    public let layout: Double
}

public struct SignalMapResult: Equatable, Codable {
    public let nodes: [SignalNode]
    public let links: [SignalEdge]
    /// The radio model after calibration from links between precisely placed phones.
    public let radio: RadioModel
}

/// Where a real-world map may draw a phone, consistent with the signal map.
public struct WorldPlacement: Equatable {
    /// Best guess; its distance to the ring centre (and to linked phones) is the measured one.
    public let x: Double
    public let z: Double
    /// 95 % radius around (x, z), meters; for a ring it covers the whole ring.
    public let r95: Double
    /// Direction unknown: the phone is somewhere on a ring of `ringRadius` around (ringX, ringZ).
    public let ambiguous: Bool
    public let ringX: Double?
    public let ringZ: Double?
    public let ringRadius: Double?
}

public enum SignalMap {
    public static let sweeps = 300
    public static let tolerance = 1e-6
    public static let minDistance = 0.3
    public static let maxDistance = 500.0
    public static let minPriorSigma = 0.3
    /// Assumed 95 % radius of a position reported without accuracy.
    public static let defaultPriorR95 = 5.0
    public static let calibrationMaxR95 = 3.0
    public static let maxR95 = 1000.0
    /// A group counts as anchored in the world when its rotation is known to about 20 degrees.
    public static let maxWorldRotationSigma = 0.35
    /// Bluetooth links older than this (report age plus `ageMs`) are not used; mirrors
    /// `ESTIMATE_LINK_MAX_AGE_MS`. Reports can spend a few seconds relaying through the mesh.
    public static let linkMaxAge: TimeInterval = 6
    /// 95 % radius of a 2-D Gaussian per unit of its per-axis sigma: sqrt(-2 ln 0.05).
    public static let r95PerSigma = 2.4477468306808166

    private static let sqrtHalf = 0.7071067811865476
    /// Deterministic directions for first placement; no trigonometry, so both ports agree exactly.
    private static let directions: [(Double, Double)] = [
        (0, 1), (sqrtHalf, sqrtHalf), (1, 0), (sqrtHalf, -sqrtHalf),
        (0, -1), (-sqrtHalf, -sqrtHalf), (-1, 0), (-sqrtHalf, sqrtHalf),
    ]

    /// Median distance for an RSSI, clamped to the range the model can mean anything over.
    public static func range(forRSSI rssi: Double, radio: RadioModel) -> Double {
        let d = pow(10, (radio.p0 - rssi) / (10 * radio.n))
        return min(maxDistance, max(minDistance, d))
    }

    /// One-sigma error of a range: RSSI spread is log-normal, so it grows in proportion to distance.
    public static func rangeSigma(_ distance: Double, radio: RadioModel) -> Double {
        distance * log(10) * radio.sigma / (10 * radio.n)
    }

    public static func priorSigma(_ r95: Double?) -> Double {
        max(minPriorSigma, (r95 ?? defaultPriorR95) / r95PerSigma)
    }

    /// Fits p0 and n from links whose two ends both report a precise position (known distance),
    /// with priors that keep a fit from few links close to `radio`.
    public static func calibrate(_ radio: RadioModel, links: [SignalLink], priors: [String: SignalPrior]) -> RadioModel {
        let p0Weight = 1.0 / 36 // prior sigma 6 dB
        let nWeight = 1.0 / 2.25 // prior sigma 1.5
        let w = 1 / (radio.sigma * radio.sigma)
        var s1 = 0.0, sx = 0.0, sxx = 0.0, sy = 0.0, sxy = 0.0
        var count = 0
        for link in links {
            guard let a = priors[link.a], let b = priors[link.b],
                  let ar = a.r95, let br = b.r95, ar <= calibrationMaxR95, br <= calibrationMaxR95 else { continue }
            let dx = a.x - b.x
            let dz = a.z - b.z
            let distance = (dx * dx + dz * dz).squareRoot()
            if distance < 0.5 { continue }
            let x = -10 * log10(distance)
            s1 += w
            sx += w * x
            sxx += w * x * x
            sy += w * link.rssi
            sxy += w * x * link.rssi
            count += 1
        }
        guard count > 0 else { return radio }
        let a11 = s1 + p0Weight
        let a12 = sx
        let a22 = sxx + nWeight
        let b1 = sy + p0Weight * radio.p0
        let b2 = sxy + nWeight * radio.n
        let det = a11 * a22 - a12 * a12
        guard det > 0 else { return radio }
        let p0 = (b1 * a22 - a12 * b2) / det
        let n = (a11 * b2 - a12 * b1) / det
        var result = radio
        result.p0 = min(-20, max(-100, p0))
        result.n = min(5, max(1.5, n))
        return result
    }

    private struct Adjacent {
        let other: String
        let distance: Double
        let weight: Double
    }

    public static func solve(ids rawIds: [String], links rawLinks: [SignalLink], priors rawPriors: [SignalPrior],
                             radio inputRadio: RadioModel, previous: [String: FloorPoint]? = nil,
                             calibrate shouldCalibrate: Bool = false) -> SignalMapResult {
        let ids = Array(Set(rawIds)).sorted()
        var index: [String: Int] = [:]
        for (i, id) in ids.enumerated() { index[id] = i }
        var priors: [String: SignalPrior] = [:]
        for prior in rawPriors where index[prior.id] != nil { priors[prior.id] = prior }

        // One link per pair; duplicates are averaged.
        var pairs: [String: (a: String, b: String, sum: Double, count: Int)] = [:]
        for link in rawLinks {
            guard link.a != link.b, index[link.a] != nil, index[link.b] != nil, link.rssi.isFinite else { continue }
            let (a, b) = link.a < link.b ? (link.a, link.b) : (link.b, link.a)
            let key = a + "\n" + b
            var pair = pairs[key] ?? (a, b, 0, 0)
            pair.sum += link.rssi
            pair.count += 1
            pairs[key] = pair
        }
        let links = pairs.keys.sorted().map { key -> SignalLink in
            let pair = pairs[key]!
            return SignalLink(a: pair.a, b: pair.b, rssi: pair.sum / Double(pair.count))
        }

        let radio = shouldCalibrate ? calibrate(inputRadio, links: links, priors: priors) : inputRadio

        var adjacency: [String: [Adjacent]] = [:]
        for id in ids { adjacency[id] = [] }
        for link in links {
            let distance = range(forRSSI: link.rssi, radio: radio)
            let sigma = rangeSigma(distance, radio: radio)
            let weight = 1 / (sigma * sigma)
            adjacency[link.a]!.append(Adjacent(other: link.b, distance: distance, weight: weight))
            adjacency[link.b]!.append(Adjacent(other: link.a, distance: distance, weight: weight))
        }
        for id in ids { adjacency[id]!.sort { $0.other < $1.other } }

        // Connected groups, numbered in order of their smallest id.
        var component: [String: Int] = [:]
        var groups: [[String]] = []
        for id in ids where component[id] == nil {
            var group: [String] = []
            var queue = [id]
            component[id] = groups.count
            while !queue.isEmpty {
                let u = queue.removeFirst()
                group.append(u)
                for edge in adjacency[u]! where component[edge.other] == nil {
                    component[edge.other] = groups.count
                    queue.append(edge.other)
                }
            }
            groups.append(group.sorted())
        }

        // Start from the last layout, then reported positions, then spread out from placed phones.
        var position: [String: (x: Double, z: Double)] = [:]
        for id in ids {
            if let last = previous?[id], last.x.isFinite, last.z.isFinite {
                position[id] = (last.x, last.z)
            } else if let prior = priors[id] {
                position[id] = (prior.x, prior.z)
            }
        }
        var placements = 0
        for group in groups {
            var queue = group.filter { position[$0] != nil }
            if queue.isEmpty {
                position[group[0]] = (0, 0)
                queue.append(group[0])
            }
            while !queue.isEmpty {
                let u = queue.removeFirst()
                let from = position[u]!
                for edge in adjacency[u]! where position[edge.other] == nil {
                    let (dx, dz) = directions[placements % directions.count]
                    placements += 1
                    position[edge.other] = (from.x + edge.distance * dx, from.z + edge.distance * dz)
                    queue.append(edge.other)
                }
            }
        }

        // Stress majorization, one phone at a time: move each phone to the weighted mean of where
        // its links and its own reported position say it should be.
        for _ in 0..<sweeps {
            var maxMove = 0.0
            for id in ids {
                let p = position[id]!
                var sumX = 0.0, sumZ = 0.0, total = 0.0
                if let prior = priors[id] {
                    let sigma = priorSigma(prior.r95)
                    let lambda = 1 / (sigma * sigma)
                    sumX += lambda * prior.x
                    sumZ += lambda * prior.z
                    total += lambda
                }
                for edge in adjacency[id]! {
                    let q = position[edge.other]!
                    let dx = p.x - q.x
                    let dz = p.z - q.z
                    let dist = (dx * dx + dz * dz).squareRoot()
                    var ux = 0.0
                    var uz = 0.0
                    if dist < 1e-9 {
                        let direction = directions[(index[id]! + index[edge.other]!) % directions.count]
                        ux = direction.0
                        uz = direction.1
                    } else {
                        ux = dx / dist
                        uz = dz / dist
                    }
                    sumX += edge.weight * (q.x + edge.distance * ux)
                    sumZ += edge.weight * (q.z + edge.distance * uz)
                    total += edge.weight
                }
                if total == 0 { continue }
                let x = sumX / total
                let z = sumZ / total
                maxMove = max(maxMove, abs(x - p.x), abs(z - p.z))
                position[id] = (x, z)
            }
            if maxMove < tolerance { break }
        }

        // The most precise placed phone of each group: the point the group turns about.
        let pins: [String?] = groups.map { group in
            var best: String?
            for id in group {
                guard let prior = priors[id] else { continue }
                if let current = best, priorSigma(prior.r95) >= priorSigma(priors[current]!.r95) { continue }
                best = id
            }
            return best
        }
        // How well the other placed phones fix the group's rotation about the pin: each pulls with
        // its precision times its squared distance from the pin.
        let rotationSigma: [Double] = groups.indices.map { c in
            guard let pin = pins[c] else { return .infinity }
            let center = position[pin]!
            var information = 0.0
            for id in groups[c] where id != pin {
                guard let prior = priors[id] else { continue }
                let sigma = priorSigma(prior.r95)
                let p = position[id]!
                let dx = p.x - center.x
                let dz = p.z - center.z
                information += (dx * dx + dz * dz) / (sigma * sigma)
            }
            return information > 0 ? 1 / information.squareRoot() : .infinity
        }
        let frames: [SignalFrame] = groups.indices.map { c in
            guard pins[c] != nil else { return .relative }
            return rotationSigma[c] < maxWorldRotationSigma ? .world : .pinned
        }

        // Hops from the nearest placed phone.
        var hops: [String: Int] = [:]
        var hopQueue = ids.filter { priors[$0] != nil }
        for id in hopQueue { hops[id] = 0 }
        while !hopQueue.isEmpty {
            let u = hopQueue.removeFirst()
            for edge in adjacency[u]! where hops[edge.other] == nil {
                hops[edge.other] = hops[u]! + 1
                hopQueue.append(edge.other)
            }
        }

        let nodes: [SignalNode] = ids.map { id in
            let p = position[id]!
            let c = component[id]!
            let frame = frames[c]
            let edges = adjacency[id]!
            let prior = priors[id]
            var node = SignalNode(id: id, x: p.x, z: p.z, placed: true, r95: 0, hasPrior: prior != nil, component: c,
                                  frame: frame, degree: edges.count, ringCenter: nil, ringRadius: nil, hops: hops[id])
            if prior == nil && edges.isEmpty {
                node.placed = false
                node.r95 = maxR95
                return node
            }
            if prior == nil && edges.count == 1 {
                // One link gives a distance, not a direction.
                let edge = edges[0]
                node.ringCenter = edge.other
                node.ringRadius = edge.distance
                node.r95 = min(maxR95, edge.distance + 1.96 * rangeSigma(edge.distance, radio: radio))
                return node
            }
            // Local uncertainty from the information each link and the prior give.
            var a = 0.0, b = 0.0, d = 0.0
            if let prior {
                let sigma = priorSigma(prior.r95)
                a += 1 / (sigma * sigma)
                d += 1 / (sigma * sigma)
            }
            for edge in edges {
                let q = position[edge.other]!
                let dx = p.x - q.x
                let dz = p.z - q.z
                let dist = (dx * dx + dz * dz).squareRoot()
                if dist < 1e-9 { continue }
                let ux = dx / dist
                let uz = dz / dist
                a += edge.weight * ux * ux
                b += edge.weight * ux * uz
                d += edge.weight * uz * uz
            }
            let det = a * d - b * b
            var r95 = det > 1e-12 * (a + d) * (a + d) ? r95PerSigma * ((a + d) / det / 2).squareRoot() : maxR95
            if let pin = pins[c], id != pin {
                let q = position[pin]!
                let dx = p.x - q.x
                let dz = p.z - q.z
                let fromPin = (dx * dx + dz * dz).squareRoot()
                if frame == .pinned {
                    // The group can still turn about its pin: the distance is known, the direction is not.
                    node.ringCenter = pin
                    node.ringRadius = fromPin
                    r95 += fromPin
                } else {
                    // Anchored, but the remaining rotation error grows with distance from the pin.
                    let across = r95PerSigma * fromPin * rotationSigma[c]
                    r95 = (r95 * r95 + across * across).squareRoot()
                }
            }
            node.r95 = min(maxR95, r95)
            return node
        }

        let edges: [SignalEdge] = links.map { link in
            let p = position[link.a]!
            let q = position[link.b]!
            let dx = p.x - q.x
            let dz = p.z - q.z
            let measured = range(forRSSI: link.rssi, radio: radio)
            return SignalEdge(a: link.a, b: link.b, rssi: link.rssi, measured: measured,
                              sigma: rangeSigma(measured, radio: radio), layout: (dx * dx + dz * dz).squareRoot())
        }

        return SignalMapResult(nodes: nodes, links: edges, radio: radio)
    }

    /// A node's spot on a real-world map: its layout position, which keeps every Bluetooth
    /// distance, plus the ring around its centre when only the distance is known. A relative
    /// group has no place in the world (show it on the signal map instead).
    public static func placeInWorld(_ node: SignalNode, nodes: [String: SignalNode], depth: Int = 0) -> WorldPlacement? {
        guard node.placed, node.frame != .relative, depth <= 4 else { return nil }
        if let ringCenter = node.ringCenter, let ringRadius = node.ringRadius {
            guard let center = nodes[ringCenter], let placed = placeInWorld(center, nodes: nodes, depth: depth + 1) else { return nil }
            return WorldPlacement(x: node.x, z: node.z,
                                  r95: min(maxR95, ringRadius + node.r95 + (placed.ambiguous ? placed.r95 : 0)),
                                  ambiguous: true, ringX: placed.x, ringZ: placed.z, ringRadius: ringRadius)
        }
        return WorldPlacement(x: node.x, z: node.z, r95: node.r95, ambiguous: false, ringX: nil, ringZ: nil, ringRadius: nil)
    }

    /// Points on a placement's ring, for maps that draw clouds; empty when the spot is known.
    public static func ringPoints(_ placement: WorldPlacement, count: Int = 24) -> [FloorPoint] {
        guard placement.ambiguous, let radius = placement.ringRadius, let cx = placement.ringX, let cz = placement.ringZ else { return [] }
        return (0..<count).map { k in
            let angle = 2 * Double.pi * Double(k) / Double(count)
            return FloorPoint(x: cx + radius * sin(angle), z: cz + radius * cos(angle))
        }
    }
}
