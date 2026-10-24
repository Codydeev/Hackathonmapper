// Route model runtime for iOS: when a phone drops out of Bluetooth range,
// predicts which way the person went along the path network, as 2-4 routes
// with probabilities ("65% Straight on at the fork in 240 m"), where along
// each route they probably are after t seconds, and the chance they left the
// paths. A line-for-line port of route-model.js (checked against its golden
// cases). Needs MovementModel.swift for Point/TrackPoint.
//
//   let routes = try RouteModel(model: Data(contentsOf: routeModelURL),   // route-model.json
//                               graph: Data(contentsOf: graphURL))         // graphs/hervanta.json
//   let pred = routes.predict(track: reports, now: lastHeard, accuracy: 12)   // once, when the link drops
//   let markers = routes.whereAlong(pred, seconds: now - lastHeard)           // any time after
//   // pred.routes[i].p, .text, .line; markers[i].point, .band; routes.toLatLon(p) for MapKit
//
// Positions are metres in the graph's frame, the same frame as the v2 map
// (MapLayer.toXY / RouteModel.toXY convert GPS coordinates).

import Foundation

public final class RouteModel {
    public typealias Point = MovementModel.Point

    public struct Route {
        public var p: Double
        public let text: String
        public let turn: String
        public let line: [Point]
        public let cum: [Double]
    }

    public struct Prediction {
        public let routes: [Route]
        public let offPath: Double
        public let offNow: Bool
        public let bin: Int
        public let speed: Double
    }

    public struct Marker {
        public let point: Point
        public let band: [Point]
        public let atEnd: Bool
        public let q10: Double, q50: Double, q90: Double
    }

    // Model tables (route-model.json).
    let vEdges: [Double], tGrid: [Double], q: [String: [[Double]]]
    let backMoving: Double, backStopped: Double
    let offT: [Double], offOn: [Double], offOff: [Double]
    let minR: Double, accMul: Double, sigma0: Double, maxStarts: Int, minShare: Double, offPathM: Double, movedM: Double
    let prune: Double, maxLeaves: Int, horizon: Double
    let mergeMinShare: Double, maxRoutes: Int, parallelM: Double, probeM: Double

    // Graph (graphs/<area>.json).
    public let lat0: Double, lon0: Double
    let names: [String]
    let len: [Double], nameIdx: [Int]
    let pts: [[Point]], cum: [[Double]]
    let turnOff: [Int], turnTo: [Int], turnP: [Double]

    struct Cell: Hashable { let i: Int, j: Int }
    struct Sample { let e: Int, s: Double, x: Double, y: Double }
    var grid: [Cell: [Sample]] = [:]
    static let cell = 30.0

    final class Node {
        let d: Int, p: Double, start: Double, end: Double, back: Bool
        weak var parent: Node?
        var children: [Node] = []
        init(d: Int, p: Double, start: Double, end: Double, parent: Node?, back: Bool = false) {
            self.d = d; self.p = p; self.start = start; self.end = end; self.parent = parent; self.back = back
        }
    }

    public init(model: Data, graph: Data) throws {
        func obj(_ a: Any?) -> [String: Any] { a as? [String: Any] ?? [:] }
        func num(_ a: Any?) -> Double { (a as? NSNumber)?.doubleValue ?? 0 }
        func nums(_ a: Any?) -> [Double] { (a as? [NSNumber])?.map { $0.doubleValue } ?? [] }
        let m = obj(try JSONSerialization.jsonObject(with: model))
        let speed = obj(m["speed"])
        vEdges = nums(speed["vEdges"]); tGrid = nums(speed["t"])
        var qq: [String: [[Double]]] = [:]
        for (k, v) in obj(speed["q"]) { qq[k] = (v as? [Any] ?? []).map { nums($0) } }
        q = qq
        let back = obj(m["back"]); backMoving = num(back["moving"]); backStopped = num(back["stopped"])
        let off = obj(m["offPath"]); offT = nums(off["t"]); offOn = nums(off["on"]); offOff = nums(off["off"])
        let loc = obj(m["locate"])
        minR = num(loc["minR"]); accMul = num(loc["accMul"]); sigma0 = num(loc["sigma0"]); maxStarts = Int(num(loc["maxStarts"]))
        minShare = num(loc["minShare"]); offPathM = num(loc["offPathM"]); movedM = num(loc["movedM"])
        let ro = obj(m["rollout"]); prune = num(ro["prune"]); maxLeaves = Int(num(ro["maxLeaves"])); horizon = num(ro["horizon"])
        let me = obj(m["merge"])
        mergeMinShare = num(me["minShare"]); maxRoutes = Int(num(me["maxRoutes"])); parallelM = num(me["parallelM"]); probeM = num(me["probeM"])

        let g = obj(try JSONSerialization.jsonObject(with: graph))
        lat0 = num(g["lat0"]); lon0 = num(g["lon0"])
        names = g["names"] as? [String] ?? []
        turnOff = nums(g["turnOff"]).map { Int($0) }; turnTo = nums(g["turnTo"]).map { Int($0) }; turnP = nums(g["turnP"])
        var len: [Double] = [], nameIdx: [Int] = [], pts: [[Point]] = [], cum: [[Double]] = []
        for case let ed as [Any] in g["edges"] as? [Any] ?? [] {
            let L = num(ed[2])
            len.append(L); nameIdx.append(Int(num(ed[4])))
            let f = nums(ed[6])
            var p: [Point] = []
            p.reserveCapacity(f.count / 2)
            var i = 0
            while i + 1 < f.count { p.append(Point(f[i], f[i + 1])); i += 2 }
            var c: [Double] = [0]
            for k in 1..<max(1, p.count) { c.append(c[k - 1] + hypot(p[k].x - p[k - 1].x, p[k].y - p[k - 1].y)) }
            let scale = c[c.count - 1] > 0 ? L / c[c.count - 1] : 1
            var scaled = c.map { $0 * scale }
            scaled[scaled.count - 1] = L   // exact, so every runtime agrees on the end
            pts.append(p); cum.append(scaled)
        }
        self.len = len; self.nameIdx = nameIdx; self.pts = pts; self.cum = cum
        for e in 0..<len.count {
            let L = len[e], n = max(2, Int((L / 5).rounded(.up)) + 1)
            for k in 0..<n {
                let s = L * Double(k) / Double(n - 1), p = at(2 * e, s)
                grid[Cell(i: Int(floor(p.x / Self.cell)), j: Int(floor(p.y / Self.cell))), default: []].append(Sample(e: e, s: s, x: p.x, y: p.y))
            }
        }
    }

    // MARK: Frame

    public func toXY(lat: Double, lon: Double) -> Point {
        let r = 6371000.0, rad = Double.pi / 180
        return Point(r * cos(lat0 * rad) * (lon - lon0) * rad, r * (lat - lat0) * rad)
    }

    public func toLatLon(_ p: Point) -> (lat: Double, lon: Double) {
        let r = 6371000.0, deg = 180 / Double.pi
        return (lat0 + p.y / r * deg, lon0 + p.x / (r * cos(lat0 / deg)) * deg)
    }

    /// The same 31 positions, 2 s apart, that MovementModel.history makes.
    public func history(track: [MovementModel.TrackPoint], now: Double) -> [Point] {
        precondition(!track.isEmpty)
        var out: [Point] = []
        var j = 0
        for i in stride(from: 30, through: 0, by: -1) {
            let t = now - Double(i) * 2
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

    // MARK: Geometry

    static func wrap(_ a: Double) -> Double {
        ((a + .pi).truncatingRemainder(dividingBy: 2 * .pi) + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi) - .pi
    }

    func at(_ d: Int, _ s: Double) -> Point {
        let e = d >> 1, c = cum[e], p = pts[e], L = len[e]
        let u = d & 1 == 1 ? L - s : s
        if u <= 0 { return p[0] }
        if u >= c[c.count - 1] { return p[p.count - 1] }
        var i = 1
        while c[i] < u { i += 1 }
        let f = (u - c[i - 1]) / max(1e-9, c[i] - c[i - 1])
        return Point(p[i - 1].x + f * (p[i].x - p[i - 1].x), p[i - 1].y + f * (p[i].y - p[i - 1].y))
    }

    func piece(_ d: Int, _ s0: Double, _ s1: Double) -> [Point] {
        let e = d >> 1, L = len[e]
        var out = [at(d, s0)]
        var inner = cum[e].enumerated().map { (d & 1 == 1 ? L - $0.element : $0.element, $0.offset) }.filter { $0.0 > s0 + 1e-6 && $0.0 < s1 - 1e-6 }
        if d & 1 == 1 { inner.reverse() }
        for (_, i) in inner { out.append(pts[e][i]) }
        out.append(at(d, s1))
        return out
    }

    func headingOut(_ d: Int) -> Double {
        let a = at(d, 0), b = at(d, min(25, len[d >> 1]))
        return atan2(b.y - a.y, b.x - a.x)
    }

    func headingIn(_ d: Int) -> Double {
        let L = len[d >> 1], a = at(d, max(0, L - 25)), b = at(d, L)
        return atan2(b.y - a.y, b.x - a.x)
    }

    /// Edges with a sample point within r, nearest distance and offset, in first-found order.
    func near(_ p: Point, _ r: Double) -> [(e: Int, dist: Double, s: Double)] {
        var order: [Int] = [], best: [Int: (Double, Double)] = [:]
        let c0 = Int(floor((p.x - r) / Self.cell)), c1 = Int(floor((p.x + r) / Self.cell))
        let r0 = Int(floor((p.y - r) / Self.cell)), r1 = Int(floor((p.y + r) / Self.cell))
        for i in c0...c1 {
            for j in r0...r1 {
                for smp in grid[Cell(i: i, j: j)] ?? [] {
                    let dist = hypot(smp.x - p.x, smp.y - p.y)
                    guard dist <= r else { continue }
                    if let old = best[smp.e] {
                        if dist < old.0 { best[smp.e] = (dist, smp.s) }
                    } else {
                        order.append(smp.e)
                        best[smp.e] = (dist, smp.s)
                    }
                }
            }
        }
        return order.map { ($0, best[$0]!.0, best[$0]!.1) }
    }

    func nearestDist(_ p: Point, _ r: Double) -> Double {
        near(p, r).map(\.dist).min() ?? .infinity
    }

    // MARK: Tables

    func speedBin(_ v: Double) -> Int {
        var b = 0
        while b < vEdges.count && v >= vEdges[b] { b += 1 }
        return b
    }

    static func interp(_ xs: [Double], _ ys: [Double], _ x: Double) -> Double {
        if x <= xs[0] { return ys[0] }
        for i in 1..<xs.count where x <= xs[i] {
            return ys[i - 1] + (x - xs[i - 1]) / (xs[i] - xs[i - 1]) * (ys[i] - ys[i - 1])
        }
        return ys[ys.count - 1]
    }

    func distAt(_ which: String, _ bin: Int, _ t: Double) -> Double {
        Self.interp(tGrid, q[which]![bin], t)
    }

    // MARK: Prediction

    struct Start { let d: Int, s: Double, p: Double, back: Bool }

    func locate(_ hist: [Point], _ acc: Double) -> (starts: [Start], offNow: Bool, moved: Bool, th: Double) {
        let n = hist.count, last = hist[n - 1]
        let recent = hist.suffix(10).map { nearestDist($0, 3 * offPathM) }.sorted()
        let offNow = recent[recent.count >> 1] > offPathM
        let R = max(minR, accMul * acc), sig2 = acc * acc + sigma0 * sigma0
        var cands = near(last, R).map { (e: $0.e, s: $0.s, w: exp(-$0.dist * $0.dist / (2 * sig2))) }
        if cands.isEmpty {
            cands = near(last, 4 * R).map { (e: $0.e, s: $0.s, w: exp(-$0.dist * $0.dist / (2 * sig2 * 16))) }
        }
        cands = cands.enumerated().sorted { $0.element.w != $1.element.w ? $0.element.w > $1.element.w : $0.offset < $1.offset }.map(\.element)
        let tot = cands.reduce(0) { $0 + $1.w }
        cands = cands.enumerated().filter { $0.offset < maxStarts && $0.element.w / tot >= minShare }.map(\.element)
        let t2 = cands.reduce(0) { $0 + $1.w }
        let backPt = hist[n - 1], from = hist[max(0, n - 11)]
        let moved = hypot(backPt.x - from.x, backPt.y - from.y) >= movedM
        let th = atan2(backPt.y - from.y, backPt.x - from.x)
        let pBack = moved ? backMoving : backStopped
        var starts: [Start] = []
        for c in cands {
            let share = c.w / t2, Le = len[c.e]
            let a = at(2 * c.e, max(0, c.s - 5)), b = at(2 * c.e, min(Le, c.s + 5))
            let tangent = atan2(b.y - a.y, b.x - a.x)
            let fwdAligned = !moved || cos(th - tangent) >= 0
            let pFwd = moved ? (fwdAligned ? 1 - pBack : pBack) : 0.5
            starts.append(Start(d: 2 * c.e, s: c.s, p: share * pFwd, back: moved && !fwdAligned))
            starts.append(Start(d: 2 * c.e + 1, s: Le - c.s, p: share * (1 - pFwd), back: moved && fwdAligned))
        }
        return (starts.filter { $0.p > 0 }, offNow, moved, th)
    }

    func rollout(_ starts: [Start], _ dmax: Double) -> Node {
        let root = Node(d: -1, p: 1, start: 0, end: 0, parent: nil)
        var heap: [Node] = []   // sorted by p, ties in insertion order; popLast takes the most likely
        func push(_ x: Node) {
            var lo = 0, hi = heap.count
            while lo < hi { let mid = (lo + hi) >> 1; if heap[mid].p <= x.p { lo = mid + 1 } else { hi = mid } }
            heap.insert(x, at: lo)
        }
        for s in starts {
            let node = Node(d: s.d, p: s.p, start: s.s, end: len[s.d >> 1] - s.s, parent: root, back: s.back)
            root.children.append(node)
            push(node)
        }
        var leaves = starts.count
        while let x = heap.popLast() {
            if x.end >= dmax || leaves >= maxLeaves { continue }
            var added = 0
            for k in turnOff[x.d]..<turnOff[x.d + 1] {
                let p = x.p * turnP[k]
                if p < prune { continue }
                let d = turnTo[k]
                let c = Node(d: d, p: p, start: 0, end: x.end + len[d >> 1], parent: x)
                x.children.append(c)
                push(c)
                added += 1
            }
            if added > 0 { leaves += added - 1 }
        }
        return root
    }

    struct Cluster { var members: [Node]; var p: Double; let probe: Point }

    func probePoint(_ x: Node) -> Point {
        let l = len[x.d >> 1] - x.start
        return at(x.d, x.start + min(l, probeM))
    }

    func clusters(_ children: [Node]) -> [Cluster] {
        var out: [Cluster] = []
        let sorted = children.enumerated().sorted { $0.element.p != $1.element.p ? $0.element.p > $1.element.p : $0.offset < $1.offset }.map(\.element)
        for c in sorted {
            let pc = probePoint(c)
            if let i = out.firstIndex(where: { hypot($0.probe.x - pc.x, $0.probe.y - pc.y) < parallelM }) {
                out[i].members.append(c); out[i].p += c.p
            } else {
                out.append(Cluster(members: [c], p: c.p, probe: pc))
            }
        }
        return out
    }

    final class Group {
        let anchors: [Node]
        var excluded: [ObjectIdentifier: Node] = [:]
        var fork: Node?, via: Node?
        init(anchors: [Node], fork: Node?, via: Node?) { self.anchors = anchors; self.fork = fork; self.via = via }
    }

    static func heaviest(_ xs: [Node]) -> Node { xs.dropFirst().reduce(xs[0]) { $1.p > $0.p ? $1 : $0 } }

    func merge(_ root: Node, _ total: Double) -> [(mass: Double, chain: [Node], fork: Node?, via: Node?)] {
        var groups = [Group(anchors: [root], fork: nil, via: nil)]
        func live(_ x: Node, _ g: Group) -> [Node] { x.children.filter { g.excluded[ObjectIdentifier($0)] == nil } }
        func firstFork(_ g: Group) -> (at: Node, clusters: [Cluster], dist: Double)? {
            var x: Node? = Self.heaviest(g.anchors)
            while let y = x {
                let cl = clusters(live(y, g)).filter { $0.p >= mergeMinShare * total }
                if cl.count >= 2 { return (y, cl, y === root ? 0 : y.end) }
                let kids = live(y, g)
                x = kids.isEmpty ? nil : Self.heaviest(kids)
            }
            return nil
        }
        while groups.count < maxRoutes {
            var best: (g: Group, f: (at: Node, clusters: [Cluster], dist: Double))?
            for g in groups {
                if let f = firstFork(g), best == nil || f.dist < best!.f.dist { best = (g, f) }
            }
            guard let (g, f) = best else { break }
            let stay = f.clusters[0]
            if g.via == nil && f.at !== root { g.fork = f.at; g.via = stay.members[0] }
            var split = 0
            for c in f.clusters.dropFirst() {
                if groups.count >= maxRoutes { break }
                for m in c.members { g.excluded[ObjectIdentifier(m)] = m }
                groups.append(Group(anchors: c.members, fork: f.at, via: c.members[0]))
                split += 1
            }
            if split == 0 { break }
        }
        return groups.compactMap { g in
            let mass = g.anchors.reduce(0) { $0 + $1.p } - g.excluded.values.reduce(0) { $0 + $1.p }
            var x: Node? = Self.heaviest(g.anchors)
            var chain: [Node] = []
            var y = x
            while let z = y, z !== root { chain.insert(z, at: 0); y = z.parent }
            while let z = x {
                let kids = live(z, g)
                x = kids.isEmpty ? nil : Self.heaviest(kids)
                if let k = x { chain.append(k) }
            }
            return chain.isEmpty || mass <= 0 ? nil : (mass, chain, g.fork, g.via)
        }
    }

    func pointAlong(_ line: [Point], _ cum: [Double], _ s: Double) -> Point {
        if s <= 0 { return line[0] }
        if s >= cum[cum.count - 1] { return line[line.count - 1] }
        var i = 1
        while cum[i] < s { i += 1 }
        let f = (s - cum[i - 1]) / max(1e-9, cum[i] - cum[i - 1])
        return Point(line[i - 1].x + f * (line[i].x - line[i - 1].x), line[i - 1].y + f * (line[i].y - line[i - 1].y))
    }

    func describe(chain: [Node], fork: Node?, via: Node?, line: [Point], cum: [Double], heading: Double, moved: Bool) -> (turn: String, text: String) {
        var name: String?
        for x in chain { let k = nameIdx[x.d >> 1]; if k >= 0 { name = names[k]; break } }
        let along = name.map { " · \($0)" } ?? ""
        if chain[0].back && (fork == nil || fork!.d == -1) { return ("back", "Turned back\(along)") }
        guard let fork = fork, let via = via, fork.d != -1 else {
            if cum.count < 2 { return ("along", "Along this path\(along)") }
            let p = pointAlong(line, cum, min(60, cum[cum.count - 1])), o = line[0]
            if !moved {
                let deg = ((90 - atan2(p.y - o.y, p.x - o.x) * 180 / .pi) + 360).truncatingRemainder(dividingBy: 360)
                let compass = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"][Int((deg / 45).rounded()) % 8]
                return ("along", "Heading \(compass)\(along)")
            }
            let a = Self.wrap(atan2(p.y - o.y, p.x - o.x) - heading), deg = abs(a) * 180 / .pi
            let side = a > 0 ? "left" : "right"
            let words = deg < 30 ? "Ahead" : deg < 150 ? "Off to the \(side)" : "Back the way they came"
            return (deg < 30 ? "along" : deg < 150 ? side : "back", "\(words)\(along)")
        }
        let a = Self.wrap(headingOut(via.d) - headingIn(fork.d)), deg = abs(a) * 180 / .pi
        let side = a > 0 ? "left" : "right"
        let turn = deg < 15 ? "straight" : deg < 45 ? "slight \(side)" : deg <= 145 ? side : "back"
        let words = ["straight": "Straight on", "slight left": "Bear left", "slight right": "Bear right",
                     "left": "Left", "right": "Right", "back": "Back"][turn]!
        let dist = max(0, Int((fork.end / 10).rounded()) * 10)
        return (turn, "\(words) at the fork in \(dist) m\(along)")
    }

    /// hist: 31 positions, 2 s apart, oldest first. accuracy: accuracyMeters.
    public func predictRoutes(history hist: [Point], accuracy: Double) -> Prediction {
        let n = hist.count, last = hist[n - 1], first = hist[0]
        let v = hypot(last.x - first.x, last.y - first.y) / (Double(n - 1) * 2)
        let bin = speedBin(v)
        let dmax = distAt("q90", bin, horizon) + 30
        let loc = locate(hist, accuracy)
        let pOff = Self.interp(offT, loc.offNow ? offOff : offOn, horizon)
        if loc.starts.isEmpty { return Prediction(routes: [], offPath: 1, offNow: true, bin: bin, speed: v) }
        let root = rollout(loc.starts, dmax)
        let total = loc.starts.reduce(0) { $0 + $1.p }
        var routes: [Route] = merge(root, total).map { r in
            var line: [Point] = [], cum: [Double] = []
            var dist = 0.0
            for x in r.chain {
                for p in piece(x.d, x.start, len[x.d >> 1]) {
                    if let q = line.last { dist += hypot(p.x - q.x, p.y - q.y) }
                    line.append(p); cum.append(dist)
                }
            }
            let (turn, text) = describe(chain: r.chain, fork: r.fork, via: r.via, line: line, cum: cum, heading: loc.th, moved: loc.moved)
            return Route(p: r.mass / total * (1 - pOff), text: text, turn: turn, line: line, cum: cum)
        }
        routes = routes.enumerated().sorted { $0.element.p != $1.element.p ? $0.element.p > $1.element.p : $0.offset < $1.offset }.map(\.element)
        // Standing at a junction can give the same route twice: merge routes within 20 m all the way.
        var out: [Route] = []
        for r in routes {
            let twin = out.firstIndex { o in
                let L = min(o.cum[o.cum.count - 1], r.cum[r.cum.count - 1])
                var s = 0.0
                while s <= L {
                    let a = pointAlong(o.line, o.cum, s), b = pointAlong(r.line, r.cum, s)
                    if hypot(a.x - b.x, a.y - b.y) > 20 { return false }
                    s += 25
                }
                return true
            }
            if let i = twin { out[i].p += r.p } else { out.append(r) }
        }
        out = out.enumerated().sorted { $0.element.p != $1.element.p ? $0.element.p > $1.element.p : $0.offset < $1.offset }.map(\.element)
        return Prediction(routes: out, offPath: pOff, offNow: loc.offNow, bin: bin, speed: v)
    }

    /// Same input as MovementModel: the lost person's reports, oldest first, and when they were last heard.
    public func predict(track: [MovementModel.TrackPoint], now: Double, accuracy: Double) -> Prediction {
        predictRoutes(history: history(track: track, now: now), accuracy: accuracy)
    }

    /// Where along each route they probably are `seconds` after the link dropped.
    public func whereAlong(_ pred: Prediction, seconds t: Double) -> [Marker] {
        let q10 = distAt("q10", pred.bin, t), q50 = distAt("q50", pred.bin, t), q90 = distAt("q90", pred.bin, t)
        return pred.routes.map { r in
            var band = [pointAlong(r.line, r.cum, q10)]
            for (i, c) in r.cum.enumerated() where c > q10 && c < q90 { band.append(r.line[i]) }
            band.append(pointAlong(r.line, r.cum, q90))
            return Marker(point: pointAlong(r.line, r.cum, q50), band: band, atEnd: q50 >= r.cum[r.cum.count - 1], q10: q10, q50: q50, q90: q90)
        }
    }
}
