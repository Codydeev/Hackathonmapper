import Foundation

// Places every fresh phone once a second from the mesh reports. Two estimators work together:
//   - BluetoothEstimator (particle filter) seeds phones without a position and tells a ring or
//     two spots from a fix.
//   - LayoutSolver places every phone of a component that has a UWB distance jointly, so the
//     measured distances hold between the drawn points, even where GPS is off by more than that.
// Components without a UWB link keep the particle filter's estimate, as before.

/// Where a phone's drawn point comes from. Only `reported` positions are measured coordinates.
public enum PositionBasis: Equatable {
    /// The phone's own report: GPS, a typed spot or a UWB anchor fix (moved by at most its sigma).
    case reported(PositionSource)
    /// A GPS phone moved by the UWB distances to its neighbours.
    case gpsRefined
    /// A phone without a position, placed from UWB distances (and bearings where there are some).
    case uwbRanged
    /// A phone without a position, placed from Bluetooth signal strength.
    case bluetooth
}

/// The direction of a phone from its neighbour is unknown: it is somewhere on this ring.
public struct EstimateRing: Equatable {
    /// The neighbour the ring is around.
    public let around: String
    public let center: FloorPoint
    /// The measured distance, UWB when there is one.
    public let radius: Double

    public init(around: String, center: FloorPoint, radius: Double) {
        self.around = around
        self.center = center
        self.radius = radius
    }
}

public struct PhoneFix: Equatable {
    public let id: String
    /// Where to draw the phone. For an ambiguous phone with a ring, a point on that ring.
    public let point: FloorPoint
    /// Radius around `point` holding about 95 % of the belief.
    public let r95: Double
    public let basis: PositionBasis
    /// Ring or two spots: the direction from the neighbour is unknown, so do not draw a dot.
    public let ambiguous: Bool
    public let ring: EstimateRing?
    /// Hops to the nearest phone with a position; 0 for those phones, nil when not connected.
    public let hops: Int?
    /// A sample of the particle cloud (phones without a position only), for a debug overlay.
    public let cloud: [FloorPoint]

    public init(id: String, point: FloorPoint, r95: Double, basis: PositionBasis, ambiguous: Bool,
                ring: EstimateRing?, hops: Int?, cloud: [FloorPoint]) {
        self.id = id
        self.point = point
        self.r95 = r95
        self.basis = basis
        self.ambiguous = ambiguous
        self.ring = ring
        self.hops = hops
        self.cloud = cloud
    }
}

public final class MeshLocator {
    /// m/s a phone may walk between two solutions (temporal prior).
    public static let walkingSpeed = 1.4
    /// A previous solution older than this many updates is not used as a prior.
    public static let memory = 5
    /// Larger relative sigma than max(this, half the shortest link) means the direction is unknown.
    public static let unresolvedSigma = 3.0
    /// sigma -> 95 % radius of a 2D Gaussian.
    static let r95Factor = 2.45

    private let estimator: BluetoothEstimator
    private var calibrator: RadioCalibrator
    private var previous: [String: (point: FloorPoint, variance: Double, call: Int)] = [:]
    private var lastPoint: [String: FloorPoint] = [:]
    private var call = 0

    /// The radio model used for RSSI distances: `options.radio` with p0 fitted to the links that
    /// also have a UWB distance, once there are enough of them.
    public var radio: RadioModel { calibrator.radio }

    public init(options: BluetoothEstimator.Options = .init()) {
        estimator = BluetoothEstimator(options: options)
        calibrator = RadioCalibrator(base: options.radio)
    }

    private static func uwb(_ m: LinkMeasurement) -> Double? {
        m.uwbDistance.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    /// Measured distance of a link: UWB when there is one, else from the RSSI.
    private func distance(_ m: LinkMeasurement) -> Double? {
        if let d = Self.uwb(m) { return d }
        return m.rssi.map { radio.distance(forRSSI: $0) }
    }

    /// Orders links UWB first, then shortest.
    private func rank(_ m: LinkMeasurement) -> (Int, Double) {
        (Self.uwb(m) == nil ? 1 : 0, distance(m) ?? Double.infinity)
    }

    private static func unit(from a: FloorPoint, to b: FloorPoint) -> (x: Double, z: Double)? {
        let d = hypot(b.x - a.x, b.z - a.z)
        guard d > 1e-6, d.isFinite else { return nil }
        return ((b.x - a.x) / d, (b.z - a.z) / d)
    }

    /// One update, normally once a second (`interval`). Returns a fix for every fresh phone that
    /// has one: all phones with a position, and phones without one that are placed.
    public func update(_ input: BluetoothEstimator.Input, interval: TimeInterval = 1) -> [String: PhoneFix] {
        call += 1
        calibrator.add(input.measurements)
        estimator.radio = calibrator.radio
        let estimates: [String: BluetoothEstimate] = input.lost.isEmpty
            ? [:]
            : estimator.update(anchors: input.anchors, lost: input.lost, measurements: input.measurements)

        var anchors: [String: EstimatorAnchor] = [:]
        for a in input.anchors where anchors[a.id] == nil { anchors[a.id] = a }
        let lost = input.lost.filter { anchors[$0] == nil }
        let ids = (Array(anchors.keys) + lost).sorted()
        let known = Set(ids)

        // Usable links, and who is linked to whom.
        let links = input.measurements.filter { m in
            m.a != m.b && known.contains(m.a) && known.contains(m.b) && (m.rssi != nil || Self.uwb(m) != nil)
        }
        var adjacent: [String: [LinkMeasurement]] = [:]
        for m in links {
            adjacent[m.a, default: []].append(m)
            adjacent[m.b, default: []].append(m)
        }
        func other(_ m: LinkMeasurement, _ id: String) -> String { m.a == id ? m.b : m.a }

        // Hops from the nearest phone with a position.
        var hops: [String: Int] = [:]
        var queue = ids.filter { anchors[$0] != nil }
        for id in queue { hops[id] = 0 }
        var head = 0
        while head < queue.count {
            let id = queue[head]
            head += 1
            for m in adjacent[id] ?? [] where hops[other(m, id)] == nil {
                hops[other(m, id)] = hops[id]! + 1
                queue.append(other(m, id))
            }
        }

        // Connected components, in a stable order.
        var component: [String: Int] = [:]
        var components: [[String]] = []
        for id in ids where component[id] == nil {
            var members = [id]
            component[id] = components.count
            var next = 0
            while next < members.count {
                let current = members[next]
                next += 1
                for m in adjacent[current] ?? [] where component[other(m, current)] == nil {
                    component[other(m, current)] = components.count
                    members.append(other(m, current))
                }
            }
            components.append(members.sorted())
        }

        var fixes: [String: PhoneFix] = [:]
        var solved = Set<String>()
        for members in components {
            let memberSet = Set(members)
            let inside = links.filter { memberSet.contains($0.a) }
            guard inside.contains(where: { Self.uwb($0) != nil }), members.contains(where: { anchors[$0] != nil }) else { continue }
            for fix in solve(members, inside, anchors, estimates, hops, interval: interval) { fixes[fix.id] = fix }
            solved.formUnion(members)
        }

        // Everything else: phones with a position at their report, the others from the particle filter.
        for id in ids where !solved.contains(id) {
            guard let a = anchors[id] else { continue }
            fixes[id] = PhoneFix(id: id, point: FloorPoint(x: a.x, z: a.z), r95: Self.r95Factor * a.sigma,
                                 basis: .reported(a.source), ambiguous: false, ring: nil, hops: 0, cloud: [])
        }
        let filtered = lost.filter { !solved.contains($0) }
            .sorted { (hops[$0] ?? Int.max, $0) < (hops[$1] ?? Int.max, $1) }
        for id in filtered {
            guard let estimate = estimates[id] else { continue }
            var point = FloorPoint(x: estimate.x, z: estimate.z)
            var ring: EstimateRing?
            if estimate.ambiguous, let r = estimate.ring {
                // The neighbour's drawn point, so the drawn distance is the measured one.
                let center = fixes[r.around]?.point ?? r.center
                let toward: (x: Double, z: Double) = lastPoint[id].flatMap { Self.unit(from: center, to: $0) }
                    ?? Self.unit(from: center, to: point) ?? (0, 1)
                point = FloorPoint(x: center.x + r.radius * toward.x, z: center.z + r.radius * toward.z)
                ring = EstimateRing(around: r.around, center: center, radius: r.radius)
            }
            fixes[id] = PhoneFix(id: id, point: point, r95: estimate.r95, basis: .bluetooth,
                                 ambiguous: estimate.ambiguous, ring: ring, hops: hops[id], cloud: estimate.cloud)
        }

        previous = previous.filter { known.contains($0.key) && call - $0.value.call <= Self.memory }
        lastPoint = fixes.mapValues(\.point)
        return fixes
    }

    /// Solves one component that has a UWB link and at least one phone with a position.
    private func solve(_ members: [String], _ links: [LinkMeasurement], _ anchors: [String: EstimatorAnchor],
                       _ estimates: [String: BluetoothEstimate], _ hops: [String: Int],
                       interval: TimeInterval) -> [PhoneFix] {
        func other(_ m: LinkMeasurement, _ id: String) -> String { m.a == id ? m.b : m.a }
        var adjacent: [String: [LinkMeasurement]] = [:]
        for m in links {
            adjacent[m.a, default: []].append(m)
            adjacent[m.b, default: []].append(m)
        }

        // Start from the previous solution, a phone's own position, or a seed next to a neighbour.
        var start: [String: FloorPoint] = [:]
        var priors: [LayoutSolver.Prior] = []
        for id in members {
            if let a = anchors[id] {
                priors.append(LayoutSolver.Prior(id: id, point: FloorPoint(x: a.x, z: a.z), sigma: a.sigma))
            }
            if let last = previous[id], call - last.call <= Self.memory {
                start[id] = last.point
                // Kalman-style: the previous solution's error plus how far the phone may have walked.
                let walked = Self.walkingSpeed * max(interval, 0.1) * Double(call - last.call)
                priors.append(LayoutSolver.Prior(id: id, point: last.point,
                                                 sigma: (last.variance + walked * walked).squareRoot()))
            } else if let a = anchors[id] {
                start[id] = FloorPoint(x: a.x, z: a.z)
            }
        }
        // Seed phones without a start at the measured distance from a seeded neighbour (UWB first),
        // toward the particle filter's estimate; spread on a golden-angle spiral when it has none.
        var seeded = 0
        var pending = members.filter { start[$0] == nil }
            .sorted { (hops[$0] ?? Int.max, $0) < (hops[$1] ?? Int.max, $1) }
        while !pending.isEmpty {
            var progressed = false
            for id in pending {
                let candidates = (adjacent[id] ?? []).filter { start[other($0, id)] != nil }
                guard let link = candidates.min(by: { rank($0) < rank($1) }), let center = start[other(link, id)], let radius = distance(link) else { continue }
                let angle = Double(seeded) * 2.399_963
                seeded += 1
                let toward: (x: Double, z: Double) = estimates[id]
                    .flatMap { Self.unit(from: center, to: FloorPoint(x: $0.x, z: $0.z)) } ?? (sin(angle), cos(angle))
                start[id] = FloorPoint(x: center.x + max(radius, 0.1) * toward.x, z: center.z + max(radius, 0.1) * toward.z)
                progressed = true
            }
            pending = pending.filter { start[$0] == nil }
            if !progressed { break }
        }

        var ranges: [LayoutSolver.Range] = []
        var signals: [LayoutSolver.Signal] = []
        var bearings: [LayoutSolver.Bearing] = []
        for m in links {
            if let d = Self.uwb(m) {
                // An RSSI adds nothing where the same pair has a UWB distance.
                ranges.append(LayoutSolver.Range(a: m.a, b: m.b, distance: d))
                if let bearing = m.bearing { bearings.append(LayoutSolver.Bearing(from: m.a, to: m.b, bearing: bearing)) }
            } else if let rssi = m.rssi {
                signals.append(LayoutSolver.Signal(a: m.a, b: m.b, rssi: rssi))
            }
        }
        let solution = LayoutSolver.solve(LayoutSolver.Problem(start: start, priors: priors, ranges: ranges,
                                                               signals: signals, bearings: bearings, radio: radio))

        // Points; a typed spot or a UWB fix moves by at most its sigma.
        var points: [String: FloorPoint] = [:]
        var sigmas: [String: Double] = [:]
        for id in members {
            guard var point = solution.points[id] else { continue }
            if let a = anchors[id], a.source == .manual || a.source == .uwb {
                let reported = FloorPoint(x: a.x, z: a.z)
                let moved = hypot(point.x - a.x, point.z - a.z)
                if moved > a.sigma, let u = Self.unit(from: reported, to: point) {
                    point = FloorPoint(x: a.x + a.sigma * u.x, z: a.z + a.sigma * u.z)
                }
            }
            let sigma = min(solution.sigma(id) ?? 1 / LayoutSolver.regularization.squareRoot(),
                            1 / LayoutSolver.regularization.squareRoot())
            points[id] = point
            sigmas[id] = sigma
            previous[id] = (point, sigma * sigma, call)
        }

        var fixes: [PhoneFix] = []
        // Phones with a position first, so a ring can be centred on its neighbour's drawn point.
        func order(_ id: String) -> (Int, Int, String) { (anchors[id] == nil ? 1 : 0, hops[id] ?? Int.max, id) }
        let ordered = members.sorted { order($0) < order($1) }
        for id in ordered {
            guard let point = points[id], let sigma = sigmas[id] else { continue }
            let own = adjacent[id] ?? []
            let hasUWB = own.contains { Self.uwb($0) != nil }
            if let a = anchors[id] {
                // A GPS phone without a UWB link of its own stays at its report.
                let refined = a.source == .gps && hasUWB
                let drawn = a.source == .gps && !hasUWB ? FloorPoint(x: a.x, z: a.z) : point
                points[id] = drawn
                fixes.append(PhoneFix(id: id, point: drawn,
                                      r95: Self.r95Factor * (refined ? sigma : min(sigma, a.sigma)),
                                      basis: refined ? .gpsRefined : .reported(a.source),
                                      ambiguous: false, ring: nil, hops: 0, cloud: []))
                continue
            }

            // Direction unknown: the vector to the nearest neighbour (UWB first) is unsure across.
            let reference = own.min { rank($0) < rank($1) }
            let hasBearing = own.contains { $0.bearing != nil && Self.uwb($0) != nil }
            var ambiguous = false
            var ring: EstimateRing?
            var drawn = point
            var r95 = Self.r95Factor * sigma
            if let reference, let radius = distance(reference) {
                let neighbour = other(reference, id)
                let relative = solution.relativeSigma(id, neighbour) ?? .infinity
                let unresolved = relative > max(Self.unresolvedSigma, 0.5 * radius)
                // The filter sees two spots the solver cannot; a bearing tells them apart.
                ambiguous = unresolved || (estimates[id]?.ambiguous == true && !hasBearing)
                if ambiguous, let center = points[neighbour] {
                    let toward: (x: Double, z: Double) = Self.unit(from: center, to: point) ?? (0, 1)
                    drawn = FloorPoint(x: center.x + radius * toward.x, z: center.z + radius * toward.z)
                    ring = EstimateRing(around: neighbour, center: center, radius: radius)
                    r95 = radius + Self.r95Factor * (sigmas[neighbour] ?? 0)
                    points[id] = drawn
                }
            }
            fixes.append(PhoneFix(id: id, point: drawn, r95: r95, basis: hasUWB ? .uwbRanged : .bluetooth,
                                  ambiguous: ambiguous, ring: ring, hops: hops[id], cloud: estimates[id]?.cloud ?? []))
        }
        return fixes
    }
}
