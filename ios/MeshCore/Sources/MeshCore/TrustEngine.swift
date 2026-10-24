import Foundation

// Luotsi trust engine: decides, fix by fix, whether satellite positioning can be believed, and
// keeps navigating on steps + compass (pedestrian dead reckoning) when it cannot.
// Swift port of js/engine.js in the Luotsi prototype (gps-katoaa), constant for constant and
// message for message, so a phone reaches the same verdicts as the web demo from the same sensor
// stream: TrustEngineTests replays golden runs of the JavaScript engine through it.
//
// Inputs are plain numbers in a local metric frame (x metres east, y metres north, t seconds on
// any monotonic clock), so the same engine runs on live sensors, in simulation and in tests:
//   onFix      GNSS position with its 1-sigma accuracy in metres
//   onStep     one detected step, compass heading in radians (0 = north, clockwise)
//   onMotion   phone resting (no steps, low acceleration variance) or moving again
//   onHeading  a compass reading between steps
//   tick       called a few times per second
//   landmark   the user confirms they stand at a known point
//
// Six independent witnesses each look for a different way GPS can lie. Each returns a score in
// [0, 1] (or nil when it has nothing to say). Trust is the smoothed minimum: one confident
// objection is enough to stop believing GPS.

/// What the engine makes of satellite positioning right now.
public enum TrustVerdict: String {
    /// No fix yet.
    case initial = "init"
    /// GPS has to earn trust first: after the first fix and after a loss of signal.
    case verifying
    /// GPS is used.
    case trusted
    /// GPS is still used, with its accuracy taken as twice as bad, while a witness objects.
    case suspect
    /// GPS is ignored; navigating on steps + compass. It must then agree with the steps for
    /// `Options.recoverHold` seconds before it is trusted again.
    case rejected
    /// No fix for a while (jammed or blocked); navigating on steps + compass.
    case nosignal
}

/// One witness's opinion of the latest fix.
public struct TrustWitness: Equatable {
    /// "signal", "speed", "body", "still", "course" or "agree".
    public let id: String
    public let label: String
    /// 1 when GPS looks right, 0 when it is lying; nil when the witness has nothing to say.
    public let score: Double?
    public let detail: String

    public init(id: String, label: String, score: Double?, detail: String) {
        self.id = id
        self.label = label
        self.score = score
        self.detail = detail
    }
}

/// One line of the engine's event log.
public struct TrustLogEntry: Equatable {
    public let t: Double
    /// "good", "warn", "bad" or "info".
    public let kind: String
    public let text: String

    public init(t: Double, kind: String, text: String) {
        self.t = t
        self.kind = kind
        self.text = text
    }
}

/// The fused position, metres in the engine's frame, with its 1-sigma radius.
public struct TrustEstimate: Equatable {
    public let x: Double
    public let y: Double
    public let sigma: Double

    public init(x: Double, y: Double, sigma: Double) {
        self.x = x
        self.y = y
        self.sigma = sigma
    }
}

public struct TrustState {
    public let verdict: TrustVerdict
    /// 0...100; nil before the first fix.
    public let trust: Int?
    /// Why GPS is not (fully) believed; empty while trusted.
    public let reason: String
    public let estimate: TrustEstimate?
    /// Whether the latest fix was folded into the estimate (false when there is no fix).
    public let fixUsed: Bool
    public let witnesses: [TrustWitness]
    /// Step length learned while GPS was trusted, metres.
    public let stepLength: Double
    /// Compass offset learned while GPS was trusted, degrees.
    public let headingOffsetDegrees: Double
    /// Straight stretches the calibration has learned from.
    public let calibrationBlocks: Int
    /// Distance and time navigated on steps + compass since GPS stopped being used.
    public let deadReckoning: (meters: Double, seconds: Double)?
    /// Total step path, metres.
    public let walked: Double
    /// The latest 80 log lines, oldest first.
    public let events: [TrustLogEntry]

    public var usesGNSS: Bool { verdict == .trusted || verdict == .suspect }

    public init(verdict: TrustVerdict, trust: Int?, reason: String, estimate: TrustEstimate?, fixUsed: Bool,
                witnesses: [TrustWitness], stepLength: Double, headingOffsetDegrees: Double,
                calibrationBlocks: Int, deadReckoning: (meters: Double, seconds: Double)?, walked: Double,
                events: [TrustLogEntry]) {
        self.verdict = verdict
        self.trust = trust
        self.reason = reason
        self.estimate = estimate
        self.fixUsed = fixUsed
        self.witnesses = witnesses
        self.stepLength = stepLength
        self.headingOffsetDegrees = headingOffsetDegrees
        self.calibrationBlocks = calibrationBlocks
        self.deadReckoning = deadReckoning
        self.walked = walked
        self.events = events
    }
}

public final class TrustEngine {
    public struct Options {
        /// m, prior until calibrated against trusted GPS.
        public var stepLength = 0.70
        /// m/s, fastest plausible on foot.
        public var vmax = 4.0
        /// Dead-reckoning error growth, fraction of distance.
        public var drift = 0.04
        /// s without a fix = signal lost.
        public var fixTimeout = 4.0
        /// s, displacement-consistency windows.
        public var windows: [Double] = [20, 60, 150, 300]
        /// s between stored history anchors.
        public var anchorEvery = 2.0
        /// s of history kept.
        public var history = 320.0
        /// s of "GPS self-consistent but elsewhere" before doubting ourselves.
        public var conflictAfter = 45.0
        /// m/s the estimate's uncertainty widens during a conflict.
        public var conflictGrowth = 1.0
        /// s of clean evidence before GPS is trusted again.
        public var recoverHold = 8.0
        /// m, floor on estimate sigma after a GPS update.
        public var gnssFloor = 3.0

        public init() {}
    }

    private struct Fix {
        let t: Double
        let x: Double
        let y: Double
        let acc: Double
    }

    /// Fused position with its variance P (m²).
    private struct Estimate {
        var x: Double
        var y: Double
        var P: Double
    }

    /// Dead reckoning, GPS and the estimate as they stood at time t.
    private struct Anchor {
        let t: Double
        let Dx: Double
        let Dy: Double
        let S: Double
        let epoch: Int
        let fix: Fix?
        let est: Estimate?
    }

    /// The latest fix against the estimate: distance e, expected spread s, n = e / s.
    private struct Innovation {
        let n: Double
        let e: Double
        let s: Double
    }

    /// One displacement-consistency window of the steps-vs-GPS witness.
    private struct Window {
        let n: Double
        let r: Double
        let w: Double
        let a: Anchor
        let gps: Double
        let body: Double
    }

    private struct Opinion {
        var score: Double?
        var detail: String
        /// Steps-vs-GPS only: the window to rewind to.
        var worst: Window?

        init(_ score: Double?, _ detail: String, worst: Window? = nil) {
            self.score = score
            self.detail = detail
            self.worst = worst
        }
    }

    private struct Witness {
        let id: String
        let label: String
        let score: Double?
        let detail: String
        let worst: Window?

        init(_ id: String, _ label: String, _ opinion: Opinion) {
            self.id = id
            self.label = label
            score = opinion.score
            detail = opinion.detail
            worst = opinion.worst
        }
    }

    private let o: Options

    private var est: Estimate?
    private var lastFix: Fix?
    private var prevFix: Fix?
    /// Recent fixes.
    private var fixes: [Fix] = []
    private var anchors: [Anchor] = []
    /// Cumulative dead-reckoning displacement and path.
    private var D = (x: 0.0, y: 0.0)
    private var S = 0.0
    private var stepTimes: [Double] = []
    private var still = false
    private var stillSince: Double?
    private var heading: Double?
    private var cal: (L: Double, off: Double, blocks: Int)
    private var calBlock: (fix: Fix, Dx: Double, Dy: Double, S: Double)?
    private var trust = 0.0
    private var verdict = TrustVerdict.initial
    private var reason = ""
    private var recoverSince: Double?
    private var lastEval: Double?
    private var conflictSince: Double?
    private var conflictOffsets: [(t: Double, x: Double, y: Double)] = []
    private var conflictLogged = false
    private var epoch = 0
    /// When GPS stopped being used.
    private var drStart: (t: Double, S: Double)?
    private var speedFlag = (until: -Double.infinity, detail: "")
    private var innovation: Innovation?
    private var fixUsed = false
    private var witnesses: [Witness] = []
    private var events: [TrustLogEntry] = []

    public init(options: Options = Options()) {
        o = options
        cal = (options.stepLength, 0, 0)
    }

    private func logEvent(_ t: Double, _ kind: String, _ text: String) {
        events.append(TrustLogEntry(t: t, kind: kind, text: text))
        if events.count > 80 { events.removeFirst() }
    }

    private var usingGNSS: Bool { verdict == .trusted || verdict == .suspect }

    private func fixNear(_ t: Double, tolerance tol: Double = 1.5) -> Fix? {
        for f in fixes.reversed() {
            if abs(f.t - t) <= tol { return f }
            if f.t < t - tol { break }
        }
        return nil
    }

    private func anchorNear(_ t: Double, needFix: Bool = true) -> Anchor? {
        for a in anchors.reversed() {
            if a.epoch != epoch { break }
            if needFix && a.fix == nil { continue }
            if abs(a.t - t) <= o.anchorEvery { return a }
            if a.t < t - o.anchorEvery { break }
        }
        return nil
    }

    // MARK: - Witnesses

    private func wSignal(_ t: Double) -> Opinion {
        guard let lastFix else { return Opinion(nil, "Waiting for the first satellite fix") }
        let age = t - lastFix.t
        if age > o.fixTimeout { return Opinion(0, "No satellite fix for \(JS.rounded(age)) s (jammed or blocked)") }
        let acc = lastFix.acc
        if acc > 50 { return Opinion(0.2, "Accuracy \(Self.fmtM(acc)): satellites gone, coarse network position only") }
        if acc > 20 { return Opinion(0.6, "Accuracy degraded to \(Self.fmtM(acc))") }
        return Opinion(1, "Fix every second, accuracy \(Self.fmtM(acc))")
    }

    private func wSpeed(_ t: Double) -> Opinion {
        guard prevFix != nil else { return Opinion(nil, "Needs two fixes") }
        if t < speedFlag.until { return Opinion(0, speedFlag.detail) }
        return Opinion(1, "No impossible jumps (limit \(JS.rounded(o.vmax * 3.6)) km/h on foot)")
    }

    private func wBody(_ t: Double) -> Opinion {
        guard let lastFix, t - lastFix.t <= 1.5 else { return Opinion(nil, "No fresh fix to compare") }
        let ws = usingGNSS ? o.windows : Array(o.windows.prefix(1))
        var results: [Window] = []
        for w in ws {
            guard let a = anchorNear(t - w), let aFix = a.fix else { continue }
            let dGx = lastFix.x - aFix.x, dGy = lastFix.y - aFix.y
            let dPx = D.x - a.Dx, dPy = D.y - a.Dy
            let path = S - a.S
            let r = JS.hypot(dGx - dPx, dGy - dPy)
            let sg = 0.7 * JS.hypot(min(lastFix.acc, 15), min(aFix.acc, 15))
            let n = r / JS.hypot(sg, o.drift * 1.25 * path + 1.5)
            results.append(Window(n: n, r: r, w: w, a: a, gps: JS.hypot(dGx, dGy), body: JS.hypot(dPx, dPy)))
        }
        guard let first = results.first else { return Opinion(nil, "Building history") }
        func toScore(_ n: Double) -> Double { clamp01(1 - (n - 2.2) / 1.8) }
        let worst = results.dropFirst().reduce(first) { $1.n > $0.n ? $1 : $0 }
        // Rewind target: the longest window that already looks wrong is the one most likely to
        // start before the attack did.
        let rewindTo = results.last { toScore($0.n) < 0.5 } ?? worst
        let score = toScore(worst.n)
        let detail = score > 0.7
            ? "GPS moved like your steps (\(Self.fmtM(worst.gps)) vs \(Self.fmtM(worst.body)) in \(JS.string(worst.w)) s)"
            : "GPS moved \(Self.fmtM(worst.gps)), your steps \(Self.fmtM(worst.body)) in the last \(JS.string(worst.w)) s (\(Self.fmtM(worst.r)) apart)"
        return Opinion(score, detail, worst: rewindTo)
    }

    private func wStill(_ t: Double) -> Opinion {
        guard still, let stillSince, t - stillSince >= 4 else { return Opinion(nil, "Only judges while the phone rests") }
        guard let lastFix, t - lastFix.t <= 1.5 else { return Opinion(nil, "No fresh fix to compare") }
        guard let f0 = fixNear(stillSince + 1, tolerance: 2) else { return Opinion(nil, "No fix from when the phone stopped") }
        let d = JS.hypot(lastFix.x - f0.x, lastFix.y - f0.y)
        let thr = max(8, 1.5 * max(lastFix.acc, f0.acc))
        let score = clamp01(1 - (d - thr) / thr)
        let secs = JS.rounded(t - stillSince)
        return Opinion(score, score > 0.7
            ? "Phone still \(secs) s and GPS stayed put"
            : "Phone still \(secs) s, but GPS says you moved \(Self.fmtM(d))")
    }

    private func wCourse(_ t: Double) -> Opinion {
        let recentSteps = stepTimes.filter { $0 > t - 10 }.count
        if recentSteps < 8 { return Opinion(nil, "Only judges while walking") }
        guard let f0 = fixNear(t - 10), let a = anchorNear(t - 10, needFix: false), let lastFix, t - lastFix.t <= 1.5 else {
            return Opinion(nil, "Building history")
        }
        let dGx = lastFix.x - f0.x, dGy = lastFix.y - f0.y
        let dPx = D.x - a.Dx, dPy = D.y - a.Dy
        if JS.hypot(dGx, dGy) < 8 || JS.hypot(dPx, dPy) < 6 { return Opinion(nil, "Too little movement to compare directions") }
        let cG = (LuotsiGeo.deg(LuotsiGeo.headingOf(dGx, dGy)) + 360).truncatingRemainder(dividingBy: 360)
        let cP = (LuotsiGeo.deg(LuotsiGeo.headingOf(dPx, dPy)) + 360).truncatingRemainder(dividingBy: 360)
        let diff = abs(LuotsiGeo.deg(LuotsiGeo.wrapPi(LuotsiGeo.rad(cG - cP))))
        let score = clamp01(1 - (diff - 35) / 40)
        return Opinion(score, "GPS course \(JS.rounded(cG))°, compass \(JS.rounded(cP))° (\(JS.rounded(diff))° apart)")
    }

    private func wAgree() -> Opinion {
        guard let innovation else { return Opinion(nil, "Needs an estimate") }
        let score = clamp01(1 - (innovation.n - 2) / 2)
        return Opinion(score, score > 0.7
            ? "GPS is \(Self.fmtM(innovation.e)) from where your body says you are (within ±\(Self.fmtM(innovation.s)))"
            : "GPS is \(Self.fmtM(innovation.e)) from where your body says you are (expected ±\(Self.fmtM(innovation.s)))")
    }

    // MARK: - Verdict

    private func startDeadReckoning(_ t: Double) {
        if drStart == nil { drStart = (t, S) }
    }

    /// Undo the GPS updates that a slow-drag spoof slipped in before detection: restart from the
    /// estimate at the start of the inconsistent window and replay the steps walked since.
    private func rewind(_ t: Double, _ worst: Window?) {
        guard let a = worst?.a, let then = a.est, let before = est else { return }
        let path = S - a.S
        let sd = then.P.squareRoot() + o.drift * path
        let now = Estimate(x: then.x + (D.x - a.Dx), y: then.y + (D.y - a.Dy), P: sd * sd)
        est = now
        let moved = JS.hypot(now.x - before.x, now.y - before.y)
        if moved > 2 {
            logEvent(t, "info", "Rewound \(JS.rounded(t - a.t)) s to the last consistent point and replayed the steps (moved estimate \(Self.fmtM(moved)))")
        }
    }

    private func evaluate(_ t: Double) {
        witnesses = [
            Witness("signal", "Satellite signal", wSignal(t)),
            Witness("speed", "Possible speed", wSpeed(t)),
            Witness("body", "Steps vs GPS", wBody(t)),
            Witness("still", "Still-phone test", wStill(t)),
            Witness("course", "Compass vs GPS course", wCourse(t)),
            Witness("agree", "Where your body says you are", wAgree()),
        ]
        let active = witnesses.filter { $0.score != nil }
        let signal = witnesses[0]
        let agree = witnesses[5]
        // The first witness with the lowest score.
        var lowest: Witness?
        var lowestScore = 0.0
        for w in active where lowest == nil || w.score! < lowestScore {
            lowest = w
            lowestScore = w.score!
        }
        let target = lowest == nil ? 0 : lowestScore * 100

        let dt = lastEval.map { max(0, t - $0) } ?? 0
        lastEval = t
        let tau = target < trust ? 0.6 : 3.0
        trust += (target - trust) * (1 - exp(-dt / tau))
        if lowest != nil && lowestScore <= 0.05 { trust = min(trust, 5) }

        let prev = verdict
        if lastFix == nil {
            verdict = .initial
        } else if signal.score == 0 {
            verdict = .nosignal
            reason = signal.detail
            recoverSince = nil
            startDeadReckoning(t)
        } else if usingGNSS {
            if let lowest, trust < 40 || lowestScore <= 0.05 {
                verdict = .rejected
                reason = lowest.detail
                startDeadReckoning(t)
                if lowest.id == "body" { rewind(t, lowest.worst) }
            } else if trust < 70 {
                verdict = .suspect
                reason = lowest?.detail ?? ""
            } else {
                verdict = .trusted
                reason = ""
            }
        } else {
            // INIT, VERIFYING, REJECTED or back from NOSIGNAL: GPS has to earn trust.
            let clean = trust >= 75 && lowest != nil && lowestScore >= 0.75 && (agree.score == nil || agree.score! >= 0.9)
            if clean {
                if recoverSince == nil { recoverSince = t }
            } else {
                recoverSince = nil
            }

            // Conflict: GPS moves exactly like the user's steps but sits somewhere else. Either
            // it is offset-spoofed or our own estimate was dragged off by an attack we missed.
            // Neither side can be proven, so ask the user for a landmark and slowly widen our own
            // uncertainty until GPS fits again. Only a steady offset counts: one that keeps growing
            // is a drag attack still in progress, and must never be waited out.
            let others = active.filter { $0.id != "agree" }
            let othersClean = others.count >= 2 && others.allSatisfy { $0.score! >= 0.75 }
            if othersClean, let agreeScore = agree.score, agreeScore < 0.8, let current = est, let lastFix,
               let innovation {
                let off = (t: t, x: lastFix.x - current.x, y: lastFix.y - current.y)
                // A big jump starts a new story; otherwise keep a sliding window.
                if let prevOff = conflictOffsets.last, JS.hypot(prevOff.x - off.x, prevOff.y - off.y) > 15 {
                    conflictOffsets = []
                }
                conflictOffsets.append(off)
                if conflictSince == nil || conflictOffsets[0].t > conflictSince! { conflictSince = conflictOffsets[0].t }
                while let first = conflictOffsets.first, first.t < t - o.conflictAfter { conflictOffsets.removeFirst() }

                // Drift rate of the offset: mean of the last third vs the first third.
                var steady = false
                if t - conflictSince! >= o.conflictAfter {
                    let third = o.conflictAfter / 3
                    let early = conflictOffsets.filter { $0.t < t - 2 * third }
                    let late = conflictOffsets.filter { $0.t >= t - third }
                    if !early.isEmpty && !late.isEmpty {
                        let a = Self.mean(early), b = Self.mean(late)
                        steady = JS.hypot(b.x - a.x, b.y - a.y) / (2 * third) < 0.18
                    }
                }
                if steady {
                    if !conflictLogged {
                        logEvent(t, "warn", "GPS and your steps tell two stories \(Self.fmtM(innovation.e)) apart. Confirm at a landmark to settle it")
                        conflictLogged = true
                    }
                    let sd = current.P.squareRoot() + o.conflictGrowth * dt
                    est?.P = sd * sd
                }
                reason = steady
                    ? "GPS moves like you but is \(Self.fmtM(innovation.e)) from your estimate. Confirm at a landmark"
                    : agree.detail
            } else {
                conflictSince = nil
                conflictOffsets = []
                conflictLogged = false
            }
            let hold = prev == .initial || (prev == .verifying && drStart == nil) ? 4 : o.recoverHold
            if let recoverSince, t - recoverSince >= hold {
                verdict = .trusted
                reason = ""
                epoch += 1
                drStart = nil
                calBlock = nil
            } else if prev == .nosignal || prev == .initial {
                verdict = .verifying
            } else if prev == .rejected, let lowest, lowestScore < 0.75, conflictSince == nil {
                reason = lowest.detail
            }
        }

        if verdict != prev {
            let message: (kind: String, text: String)?
            switch verdict {
            case .trusted:
                message = ("good", prev == .verifying && events.isEmpty
                    ? "GPS consistent with steps and compass: trusted"
                    : "GPS consistent again: trusted")
            case .suspect: message = ("warn", "GPS suspicious: \(reason)")
            case .rejected: message = ("bad", "GPS rejected: \(reason). Navigating on steps + compass")
            case .nosignal: message = ("bad", "\(reason). Navigating on steps + compass")
            case .verifying:
                message = ("info", prev == .nosignal ? "Satellites back: verifying before trusting them" : "First fix: verifying")
            case .initial: message = nil
            }
            if let message { logEvent(t, message.kind, message.text) }
        }
    }

    /// Mean offset, summed as the JavaScript reduce does (each term divided first).
    private static func mean(_ offsets: [(t: Double, x: Double, y: Double)]) -> (x: Double, y: Double) {
        let n = Double(offsets.count)
        var m = (x: 0.0, y: 0.0)
        for c in offsets { m = (m.x + c.x / n, m.y + c.y / n) }
        return m
    }

    private func pushAnchor(_ t: Double) {
        if let last = anchors.last, t - last.t < o.anchorEvery { return }
        let f = lastFix.flatMap { t - $0.t <= 1.0 ? $0 : nil }
        anchors.append(Anchor(t: t, Dx: D.x, Dy: D.y, S: S, epoch: epoch, fix: f, est: usingGNSS ? est : nil))
        while let first = anchors.first, first.t < t - o.history { anchors.removeFirst() }
    }

    // MARK: - Calibration

    /// While GPS is trusted, learn the user's step length and the compass offset so dead
    /// reckoning is as good as possible when GPS goes away.
    private func calibrate(_ t: Double) {
        guard verdict == .trusted, trust >= 85, let lastFix, t - lastFix.t <= 1.0 else {
            calBlock = nil
            return
        }
        guard let block = calBlock else {
            calBlock = (lastFix, D.x, D.y, S)
            return
        }
        let path = S - block.S
        if path < 35 { return }
        let dGx = lastFix.x - block.fix.x, dGy = lastFix.y - block.fix.y
        let dPx = D.x - block.Dx, dPy = D.y - block.Dy
        let g = JS.hypot(dGx, dGy), p = JS.hypot(dPx, dPy)
        calBlock = (lastFix, D.x, D.y, S)
        if p < 0.75 * path || g < 20 { return } // only learn from fairly straight stretches
        let k = 0.2
        cal.L = max(0.45, min(1.0, cal.L * (1 + k * (g / p - 1))))
        let dOff = LuotsiGeo.wrapPi(LuotsiGeo.headingOf(dGx, dGy) - LuotsiGeo.headingOf(dPx, dPy))
        cal.off = max(LuotsiGeo.rad(-25), min(LuotsiGeo.rad(25), cal.off + k * dOff))
        cal.blocks += 1
    }

    // MARK: - Inputs

    /// A GNSS fix: x east, y north, metres; `accuracy` its 1-sigma radius. As in JavaScript
    /// (`acc || 10`), a missing, zero or NaN accuracy counts as 10 m, and nothing as better than 1 m.
    public func onFix(t: Double, x: Double, y: Double, accuracy: Double?) {
        let reported = accuracy.flatMap { $0 == 0 || $0.isNaN ? nil : $0 } ?? 10
        let acc = max(1, reported)
        let fix = Fix(t: t, x: x, y: y, acc: acc)
        prevFix = lastFix
        lastFix = fix
        fixes.append(fix)
        while let first = fixes.first, first.t < t - o.history { fixes.removeFirst() }

        if est == nil { est = Estimate(x: x, y: y, P: acc * acc) }

        if let prevFix {
            let d = JS.hypot(x - prevFix.x, y - prevFix.y)
            let dtf = max(0.2, t - prevFix.t)
            let v = max(0, d - 1.5 * (acc + prevFix.acc)) / dtf
            if v > o.vmax && t - prevFix.t < 30 {
                speedFlag = (t + 8, "GPS jumped \(Self.fmtM(d)) in \(JS.toFixed(dtf, 1)) s (\(JS.rounded(v * 3.6)) km/h on foot?)")
            }
        }

        let prior = est!
        let e = JS.hypot(x - prior.x, y - prior.y)
        let s = (prior.P + acc * acc).squareRoot()
        let latest = Innovation(n: e / s, e: e, s: s)
        innovation = latest

        pushAnchor(t)
        evaluate(t)

        fixUsed = false
        if usingGNSS && latest.n < 5, var updated = est {
            let R = verdict == .suspect ? (2 * acc) * (2 * acc) : acc * acc
            let K = updated.P / (updated.P + R)
            updated.x += K * (x - updated.x)
            updated.y += K * (y - updated.y)
            updated.P = max((1 - K) * updated.P, o.gnssFloor * o.gnssFloor)
            est = updated
            fixUsed = true
        }
        calibrate(t)
    }

    /// One detected step. `heading` in radians (0 = north, clockwise); nil keeps the last compass
    /// reading. Steps before any compass reading are ignored: no compass, no dead reckoning.
    public func onStep(t: Double, heading newHeading: Double?) {
        if let newHeading { heading = newHeading }
        guard let heading else { return }
        let L = cal.L
        let hh = heading + cal.off
        D.x += L * sin(hh)
        D.y += L * cos(hh)
        S += L
        stepTimes.append(t)
        while let first = stepTimes.first, first < t - 15 { stepTimes.removeFirst() }
        if still {
            still = false
            stillSince = nil
        }
        if var moved = est {
            moved.x += L * sin(hh)
            moved.y += L * cos(hh)
            let sd = moved.P.squareRoot() + o.drift * L
            moved.P = sd * sd
            est = moved
        }
        pushAnchor(t)
    }

    /// The phone started resting (no steps, low acceleration variance) or moving again.
    public func onMotion(t: Double, still s: Bool) {
        if s && !still { stillSince = t }
        if !s { stillSince = nil }
        still = s
    }

    /// A compass reading (radians, 0 = north, clockwise) for the next steps.
    public func onHeading(_ heading: Double) {
        self.heading = heading
    }

    /// Call a few times per second.
    public func tick(t: Double) {
        pushAnchor(t)
        evaluate(t)
    }

    /// The user confirms they stand at a known point (x, y) with 1-sigma `sigma` metres.
    public func landmark(t: Double, x: Double, y: Double, sigma: Double = 8, label: String = "landmark") {
        est = Estimate(x: x, y: y, P: sigma * sigma)
        innovation = lastFix.map { f in
            let e = JS.hypot(f.x - x, f.y - y)
            let s = (sigma * sigma + f.acc * f.acc).squareRoot()
            return Innovation(n: e / s, e: e, s: s)
        }
        logEvent(t, "info", "Position reset at \(label) (±\(JS.rounded(sigma)) m)")
        if drStart != nil { drStart = (t, S) }
    }

    public func state(t: Double) -> TrustState {
        // JavaScript would report NaN for a trust poisoned by non-finite inputs; Int cannot.
        let rounded = trust.isFinite ? Int(JS.round(trust)) : 0
        return TrustState(
            verdict: verdict,
            trust: lastFix == nil ? nil : rounded,
            reason: reason,
            estimate: est.map { TrustEstimate(x: $0.x, y: $0.y, sigma: $0.P.squareRoot()) },
            fixUsed: lastFix != nil && fixUsed,
            witnesses: witnesses.map { TrustWitness(id: $0.id, label: $0.label, score: $0.score, detail: $0.detail) },
            stepLength: cal.L,
            headingOffsetDegrees: LuotsiGeo.deg(cal.off),
            calibrationBlocks: cal.blocks,
            deadReckoning: drStart.map { (meters: S - $0.S, seconds: t - $0.t) },
            walked: S,
            events: events
        )
    }

    /// Distances in messages: "12 m", "1.3 km", "387 km".
    static func fmtM(_ m: Double) -> String {
        m >= 1000 ? "\(JS.toFixed(m / 1000, m >= 10000 ? 0 : 1)) km" : "\(JS.rounded(m)) m"
    }
}

/// Math.max(0, Math.min(1, v)), which keeps a NaN (Swift's min and max would turn it into 1).
private func clamp01(_ v: Double) -> Double { v.isNaN ? v : max(0, min(1, v)) }

/// geo.js helpers. Headings everywhere: radians, 0 = north, clockwise positive.
enum LuotsiGeo {
    static let radiansPerDegree = Double.pi / 180
    static func rad(_ degrees: Double) -> Double { degrees * radiansPerDegree }
    static func deg(_ radians: Double) -> Double { radians / radiansPerDegree }
    static func headingOf(_ dx: Double, _ dy: Double) -> Double { atan2(dx, dy) }
    static func wrapPi(_ a: Double) -> Double { atan2(sin(a), cos(a)) }
}

/// Where JavaScript numbers behave differently from Swift's, reproduced so the engine's numbers
/// and messages match the JavaScript original exactly.
enum JS {
    /// Math.round: halves round up (Swift's .rounded() takes 2.5 to 3 but also -2.5 to -3).
    static func round(_ v: Double) -> Double {
        let down = v.rounded(.down)
        return v - down >= 0.5 ? down + 1 : down
    }

    /// `${Math.round(v)}`.
    static func rounded(_ v: Double) -> String { string(round(v)) }

    /// A number as a JavaScript template string prints it, for the integers used in messages.
    static func string(_ v: Double) -> String {
        if v == v.rounded(.towardZero) && abs(v) < 1e21 { return v == 0 ? "0" : String(format: "%.0f", v) }
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v < 0 ? "-Infinity" : "Infinity" }
        return "\(v)"
    }

    /// Number.prototype.toFixed: the exact binary value rounded, ties away from zero, where printf
    /// rounds exact ties to even (1.25 gives "1.3" in JavaScript, "1.2" in printf).
    static func toFixed(_ v: Double, _ digits: Int) -> String {
        let magnitude = abs(v)
        // An exact tie has the form odd / 2^(digits + 1).
        let halves = magnitude * Double(1 << (digits + 1))
        if halves == halves.rounded(.down) && halves.truncatingRemainder(dividingBy: 2) == 1 {
            let scale = pow(10, Double(digits))
            let n = (magnitude * scale).rounded(.up)
            return (v < 0 ? "-" : "") + String(format: "%.\(digits)f", n / scale)
        }
        return String(format: "%.\(digits)f", v)
    }

    /// Math.hypot as V8 computes it (normalised by the larger value, then a compensated sum,
    /// which for two values is plain), one ulp off libm's hypot for many inputs.
    static func hypot(_ a: Double, _ b: Double) -> Double {
        let x = abs(a), y = abs(b)
        if x.isInfinite || y.isInfinite { return .infinity }
        if x.isNaN || y.isNaN { return .nan }
        let m = max(x, y)
        if m == 0 { return 0 }
        let nx = x / m, ny = y / m
        return (nx * nx + ny * ny).squareRoot() * m
    }
}
