import Foundation
import XCTest
@testable import MeshCore

/// The Swift TrustEngine and GPSAttacker against the Luotsi JavaScript originals (js/engine.js,
/// js/attacker.js). Resources/trust-engine-golden.json holds five runs of the simulated campus
/// walk, recorded from the JavaScript simulator and attacker: a clean walk with a 30 s stop, a
/// 0.5 m/s drag, a teleport to Pulkovo, jamming (with some steps arriving as a compass reading plus
/// a heading-less step), and a 0.2 m/s stealth drag settled by a landmark. Every engine input is
/// replayed in order, and once per second the Swift state must equal the JavaScript one: verdict,
/// trust, reason, all six witnesses, the event log, the estimate (to 1e-6 m) and calibration.
/// The behavioural checks after that hold even if the goldens are regenerated.
final class TrustEngineTests: XCTestCase {
    // MARK: Golden data

    private struct Golden: Decodable {
        let dt: Double
        let landmarkLabel: String
        let witnessIds: [String]
        let witnessLabels: [String]
        let scenarios: [Scenario]
        let attacker: AttackerGolden
    }

    private struct Scenario: Decodable {
        struct Attack: Decodable {
            let mode: String
            let at: Double
            let secs: Double
        }

        let name: String
        let seed: Int
        let attack: Attack?
        /// Of every input number, to prove the JSON decoded to the doubles JavaScript replayed.
        let fingerprint: String
        /// Witness details and reasons, referenced by index.
        let strings: [String]
        /// [kind, t, ...]: 0 fix (x, y, acc), 1 step (heading or null), 2 motion (still 0/1),
        /// 3 tick, 4 landmark (x, y, sigma), 5 compass heading.
        let events: [[Double?]]
        let snapshots: [Snapshot]
    }

    private struct Snapshot: Decodable {
        /// Index of the tick event after which the state was taken.
        let i: Int
        let t: Double
        let verdict: String
        let trust: Int?
        let reason: Int
        let est: [Double]?
        let used: Bool
        let dr: [Double]?
        let walked: Double
        /// Step length, heading offset (degrees), calibration blocks.
        let cal: [Double]
        /// Length of the (80-line) log.
        let count: Int
        /// [score or null, detail] per witness.
        let witnesses: [[Double?]]
        /// Log lines added since the previous snapshot.
        let log: [LogLine]
        /// Simulated true position, for the behavioural checks.
        let truth: [Double]
    }

    private struct LogLine: Decodable {
        let t: Double
        let kind: String
        let text: String

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            t = try c.decode(Double.self)
            kind = try c.decode(String.self)
            text = try c.decode(String.self)
        }
    }

    /// Numbers as hex bit patterns, so the comparison is bit for bit.
    private struct AttackerGolden: Decodable {
        struct Op: Decodable {
            let op: String
            let mode: String?
            let t: String?
            let x: String?
            let y: String?
            let acc: String?
            let dragRate: Double?
            let dragDir: Double?
            let out: [String]?
            let value: String?
        }

        let seed: UInt32
        let fake: [String]
        let next: [String]
        let gauss: [String]
        let ops: [Op]
    }

    private static var cachedGolden: Golden?
    private static var cachedRuns: [String: [TrustState]] = [:]

    private func golden() throws -> Golden {
        if let golden = Self.cachedGolden { return golden }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "trust-engine-golden", withExtension: "json",
                                                  subdirectory: "Resources"))
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
        Self.cachedGolden = golden
        return golden
    }

    /// Replays a scenario's inputs through TrustEngine; the Swift state at each snapshot.
    private func replay(_ scenario: Scenario, landmarkLabel: String) -> [TrustState] {
        if let states = Self.cachedRuns[scenario.name] { return states }
        let engine = TrustEngine()
        var states: [TrustState] = []
        for (i, e) in scenario.events.enumerated() {
            let t = e[1]!
            switch Int(e[0]!) {
            case 0: engine.onFix(t: t, x: e[2]!, y: e[3]!, accuracy: e[4])
            case 1: engine.onStep(t: t, heading: e[2])
            case 2: engine.onMotion(t: t, still: e[2] == 1)
            case 3: engine.tick(t: t)
            case 4: engine.landmark(t: t, x: e[2]!, y: e[3]!, sigma: e[4]!, label: landmarkLabel)
            case 5: engine.onHeading(e[2]!)
            default: XCTFail("unknown event \(e)")
            }
            if states.count < scenario.snapshots.count && scenario.snapshots[states.count].i == i {
                states.append(engine.state(t: scenario.snapshots[states.count].t))
            }
        }
        Self.cachedRuns[scenario.name] = states
        return states
    }

    private func run(_ name: String) throws -> [(snapshot: Snapshot, state: TrustState)] {
        let golden = try golden()
        let scenario = try XCTUnwrap(golden.scenarios.first { $0.name == name })
        return Array(zip(scenario.snapshots, replay(scenario, landmarkLabel: golden.landmarkLabel)))
    }

    private func fingerprint(_ events: [[Double?]]) -> String {
        var h: UInt64 = 0
        for e in events {
            for case let v? in e { h = ((h << 1) | (h >> 63)) ^ v.bitPattern }
        }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    // MARK: Golden replay

    func testReplaysJavaScriptEngineExactly() throws {
        let golden = try golden()
        XCTAssertEqual(golden.scenarios.map(\.name), ["clean", "drag", "teleport", "jam", "stealth-drag"])
        var snapshots = 0
        var maxEstimate = 0.0, maxOther = 0.0
        for scenario in golden.scenarios {
            XCTAssertEqual(fingerprint(scenario.events), scenario.fingerprint, "\(scenario.name): inputs decoded differently")
            let states = replay(scenario, landmarkLabel: golden.landmarkLabel)
            XCTAssertEqual(states.count, scenario.snapshots.count, scenario.name)
            var log: [TrustLogEntry] = []
            for (snap, state) in zip(scenario.snapshots, states) {
                log += snap.log.map { TrustLogEntry(t: $0.t, kind: $0.kind, text: $0.text) }
                if let difference = difference(state, snap, scenario.strings, Array(log.suffix(80)), golden) {
                    XCTFail("\(scenario.name): first difference at t = \(snap.t) s: \(difference)")
                    break
                }
                if let e = state.estimate, let g = snap.est {
                    maxEstimate = max(maxEstimate, abs(e.x - g[0]), abs(e.y - g[1]), abs(e.sigma - g[2]))
                }
                maxOther = max(maxOther, abs(state.walked - snap.walked), abs(state.stepLength - snap.cal[0]),
                               abs(state.headingOffsetDegrees - snap.cal[1]))
                snapshots += 1
            }
        }
        print("TrustEngine golden replay: \(snapshots) snapshots in \(golden.scenarios.count) scenarios match JavaScript;"
            + " largest estimate difference \(maxEstimate) m, walked/calibration \(maxOther)")
    }

    /// The first way `state` differs from the JavaScript snapshot, if any.
    private func difference(_ state: TrustState, _ snap: Snapshot, _ strings: [String], _ log: [TrustLogEntry],
                            _ golden: Golden) -> String? {
        func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }
        if state.verdict.rawValue != snap.verdict { return "verdict \(state.verdict.rawValue), JavaScript \(snap.verdict)" }
        if state.trust != snap.trust { return "trust \(String(describing: state.trust)), JavaScript \(String(describing: snap.trust))" }
        if state.reason != strings[snap.reason] { return "reason \"\(state.reason)\", JavaScript \"\(strings[snap.reason])\"" }
        switch (state.estimate, snap.est) {
        case (nil, nil): break
        case let (e?, g?):
            if !near(e.x, g[0], 1e-6) || !near(e.y, g[1], 1e-6) || !near(e.sigma, g[2], 1e-6) {
                return "estimate \(e), JavaScript \(g)"
            }
        default: return "estimate \(String(describing: state.estimate)), JavaScript \(String(describing: snap.est))"
        }
        if state.fixUsed != snap.used { return "fixUsed \(state.fixUsed), JavaScript \(snap.used)" }
        switch (state.deadReckoning, snap.dr) {
        case (nil, nil): break
        case let (d?, g?):
            if !near(d.meters, g[0], 1e-9) || !near(d.seconds, g[1], 1e-9) { return "dead reckoning \(d), JavaScript \(g)" }
        default: return "dead reckoning \(String(describing: state.deadReckoning)), JavaScript \(String(describing: snap.dr))"
        }
        if !near(state.walked, snap.walked, 1e-9) { return "walked \(state.walked), JavaScript \(snap.walked)" }
        if !near(state.stepLength, snap.cal[0], 1e-9) || !near(state.headingOffsetDegrees, snap.cal[1], 1e-9)
            || state.calibrationBlocks != Int(snap.cal[2]) {
            return "calibration \(state.stepLength) \(state.headingOffsetDegrees) \(state.calibrationBlocks), JavaScript \(snap.cal)"
        }
        if state.events.count != snap.count { return "\(state.events.count) log lines, JavaScript \(snap.count)" }
        if state.events != log {
            let i = zip(state.events, log).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                ?? min(state.events.count, log.count)
            return "log line \(i): \(state.events.dropFirst(i).first.map { "\($0)" } ?? "none"), JavaScript \(log.dropFirst(i).first.map { "\($0)" } ?? "none")"
        }
        if state.witnesses.map(\.id) != golden.witnessIds || state.witnesses.map(\.label) != golden.witnessLabels {
            return "witnesses \(state.witnesses.map(\.id))"
        }
        for (w, g) in zip(state.witnesses, snap.witnesses) {
            switch (w.score, g[0]) {
            case (nil, nil): break
            case let (a?, b?): if !near(a, b, 1e-9) { return "\(w.id) score \(a), JavaScript \(b)" }
            default: return "\(w.id) score \(String(describing: w.score)), JavaScript \(String(describing: g[0]))"
            }
            let detail = strings[Int(g[1]!)]
            if w.detail != detail { return "\(w.id) \"\(w.detail)\", JavaScript \"\(detail)\"" }
        }
        return nil
    }

    // MARK: Behaviour (holds for regenerated goldens too)

    private func error(_ run: (snapshot: Snapshot, state: TrustState)) -> Double {
        guard let e = run.state.estimate else { return .infinity }
        return hypot(e.x - run.snapshot.truth[0], e.y - run.snapshot.truth[1])
    }

    private func attackWindow(_ name: String) throws -> (at: Double, end: Double) {
        let attack = try XCTUnwrap(try golden().scenarios.first { $0.name == name }?.attack)
        return (attack.at, attack.at + attack.secs)
    }

    func testCleanWalkIsTrustedAfterWarmUp() throws {
        let runs = try run("clean")
        // Verifying from the first fix, trusted about 8 s later.
        let firstTrusted = try XCTUnwrap(runs.first { $0.state.verdict == .trusted })
        XCTAssertLessThanOrEqual(firstTrusted.snapshot.t, 12)
        let warm = runs.filter { $0.snapshot.t > 30 }
        let trusted = Double(warm.filter { $0.state.verdict == .trusted }.count) / Double(warm.count)
        XCTAssertGreaterThan(trusted, 0.97)
        XCTAssertFalse(warm.contains { $0.state.verdict == .rejected })
        XCTAssertLessThan(warm.map(error).max() ?? .infinity, 15)
        // The walker stops for 30 s: the still-phone test speaks up and finds GPS stayed put.
        XCTAssertTrue(warm.contains { $0.state.witnesses[3].score == 1 })
        XCTAssertGreaterThan(try XCTUnwrap(runs.last).state.calibrationBlocks, 0)
    }

    func testTeleportIsRejectedAtOnceAndNeverUsed() throws {
        let runs = try run("teleport")
        let (at, end) = try attackWindow("teleport")
        let during = runs.filter { $0.snapshot.t >= at && $0.snapshot.t < end }
        let detected = try XCTUnwrap(during.first { !$0.state.usesGNSS })
        XCTAssertLessThanOrEqual(detected.snapshot.t - at, 1.5)
        // Fixes come every whole second, so from `at + 1` on the latest fix is a spoofed one.
        XCTAssertFalse(during.contains { $0.snapshot.t >= at + 1 && $0.state.fixUsed }, "a spoofed fix moved the estimate")
        XCTAssertLessThan(during.map(error).max() ?? .infinity, 30)
        XCTAssertEqual(try XCTUnwrap(runs.last).state.verdict, .trusted)
    }

    func testJammingGoesToNoSignalAndRecovers() throws {
        let runs = try run("jam")
        let (at, end) = try attackWindow("jam")
        let during = runs.filter { $0.snapshot.t >= at && $0.snapshot.t < end }
        let detected = try XCTUnwrap(during.first { !$0.state.usesGNSS })
        XCTAssertLessThanOrEqual(detected.snapshot.t - at, 6)
        XCTAssertTrue(during.contains { $0.state.verdict == .nosignal })
        let last = try XCTUnwrap(during.last)
        XCTAssertNotNil(last.state.deadReckoning)
        XCTAssertLessThan(error(last), 2 * (last.state.estimate?.sigma ?? 0), "error outside the claimed uncertainty")
        let back = try XCTUnwrap(runs.first { $0.snapshot.t >= end && $0.state.verdict == .trusted })
        XCTAssertLessThanOrEqual(back.snapshot.t - end, 30)
    }

    func testSlowDragIsRejectedAndRewound() throws {
        let runs = try run("drag")
        let (at, end) = try attackWindow("drag")
        let during = runs.filter { $0.snapshot.t >= at && $0.snapshot.t < end }
        let detected = try XCTUnwrap(during.first { !$0.state.usesGNSS })
        XCTAssertLessThanOrEqual(detected.snapshot.t - at, 90)
        XCTAssertLessThan(error(try XCTUnwrap(during.last)), 25)
        XCTAssertTrue(try XCTUnwrap(runs.last).state.events.contains { $0.text.hasPrefix("Rewound") })
    }

    func testStealthDragConflictIsSettledByALandmark() throws {
        let runs = try run("stealth-drag")
        let events = try XCTUnwrap(runs.last).state.events
        XCTAssertTrue(events.contains { $0.kind == "warn" && $0.text.contains("tell two stories") })
        XCTAssertEqual(events.last?.text, "Position reset at the point you marked (±6 m)")
        XCTAssertEqual(try XCTUnwrap(runs.last).state.verdict, .trusted)
    }

    // MARK: Engine basics

    func testStateBeforeAndAtTheFirstFix() {
        let engine = TrustEngine()
        var state = engine.state(t: 0)
        XCTAssertEqual(state.verdict, .initial)
        XCTAssertNil(state.trust)
        XCTAssertNil(state.estimate)
        XCTAssertFalse(state.fixUsed)
        XCTAssertTrue(state.witnesses.isEmpty)
        XCTAssertNil(state.deadReckoning)
        XCTAssertEqual(state.stepLength, 0.7)

        engine.tick(t: 0.5)
        engine.onStep(t: 0.7, heading: nil) // no compass yet: ignored
        state = engine.state(t: 0.7)
        XCTAssertEqual(state.witnesses.map(\.id), ["signal", "speed", "body", "still", "course", "agree"])
        XCTAssertEqual(state.witnesses[0].detail, "Waiting for the first satellite fix")
        XCTAssertEqual(state.walked, 0)

        engine.onFix(t: 1, x: 10, y: 20, accuracy: nil)
        state = engine.state(t: 1)
        XCTAssertEqual(state.verdict, .verifying)
        XCTAssertNotNil(state.trust)
        XCTAssertEqual(state.estimate, TrustEstimate(x: 10, y: 20, sigma: 10))
        XCTAssertFalse(state.fixUsed)
        XCTAssertEqual(state.events, [TrustLogEntry(t: 1, kind: "info", text: "First fix: verifying")])
    }

    func testLogKeepsTheLatest80Lines() {
        let engine = TrustEngine()
        for k in 0..<100 { engine.landmark(t: Double(k), x: 0, y: 0, label: "mark \(k)") }
        let events = engine.state(t: 100).events
        XCTAssertEqual(events.count, 80)
        XCTAssertEqual(events.first, TrustLogEntry(t: 20, kind: "info", text: "Position reset at mark 20 (±8 m)"))
        XCTAssertEqual(events.last?.text, "Position reset at mark 99 (±8 m)")
    }

    func testAccuracyDefaultsAsInJavaScript() {
        // acc = max(1, acc || 10): missing, zero and NaN mean 10 m; nothing is better than 1 m.
        for (accuracy, sigma) in [(nil, 10.0), (0, 10), (.nan, 10), (0.5, 1), (25, 25)] as [(Double?, Double)] {
            let engine = TrustEngine()
            engine.onFix(t: 1, x: 0, y: 0, accuracy: accuracy)
            XCTAssertEqual(engine.state(t: 1).estimate?.sigma, sigma, "accuracy \(String(describing: accuracy))")
        }
    }

    func testStandingPhoneIsTrustedThenRejectedWhenGPSWanders() {
        // A resting phone with a steady fix is trusted after ~8 s; if GPS then wanders 0.5 m/s while
        // the phone stays still, the still-phone test rejects it.
        let engine = TrustEngine()
        engine.onMotion(t: 0.5, still: true)
        var trustedAt: Double?, rejectedAt: Double?
        for k in 1...600 {
            let t = Double(k) / 10
            if k % 10 == 0 { engine.onFix(t: t, x: t > 20 ? 0.5 * (t - 20) : 0, y: 0, accuracy: 4) }
            engine.tick(t: t)
            let state = engine.state(t: t)
            if trustedAt == nil && state.verdict == .trusted { trustedAt = t }
            if rejectedAt == nil && state.verdict == .rejected {
                rejectedAt = t
                XCTAssertTrue(state.reason.hasPrefix("Phone still"), state.reason)
            }
        }
        XCTAssertEqual(trustedAt ?? 0, 9.1, accuracy: 1e-9)
        XCTAssertEqual(rejectedAt ?? 0, 46.6, accuracy: 1e-9)
    }

    func testJavaScriptNumberHelpers() {
        // Expected strings from node: fmtM uses Math.round below 1 km and toFixed above it.
        let meters: [(Double, String)] = [
            (0.4, "0 m"), (0.5, "1 m"), (2.5, "3 m"), (999.4, "999 m"), (999.5, "1000 m"), (1000, "1.0 km"),
            (1049.99, "1.0 km"), (1050, "1.1 km"), (1150, "1.1 km"), (1250, "1.3 km"), (9950, "9.9 km"),
            (9999, "10.0 km"), (10000, "10 km"), (12500, "13 km"), (13500, "14 km"), (394000.5, "394 km"),
        ]
        for (m, text) in meters { XCTAssertEqual(TrustEngine.fmtM(m), text, "fmtM(\(m))") }
        let fixed: [(Double, Int, String)] = [
            (0.25, 1, "0.3"), (1.15, 1, "1.1"), (1.25, 1, "1.3"), (2.5, 0, "3"), (3.5, 0, "4"), (0.2, 1, "0.2"),
            (63, 1, "63.0"), (1.05, 1, "1.1"), (10.75, 1, "10.8"),
        ]
        for (v, digits, text) in fixed { XCTAssertEqual(JS.toFixed(v, digits), text, "(\(v)).toFixed(\(digits))") }
        let rounds: [(Double, Double)] = [(2.5, 3), (-2.5, -2), (0.49999999999999994, 0), (-0.5, 0), (1.5, 2), (99.5, 100), (-0.4, 0)]
        for (v, r) in rounds { XCTAssertEqual(JS.round(v), r, "Math.round(\(v))") }
        XCTAssertEqual(JS.string(20), "20")
        XCTAssertEqual(JS.string(1_391_933), "1391933")

        // Math.hypot in node, bit for bit (libm's hypot is an ulp off for several of these).
        let hypots: [(String, String, String)] = [
            ("4008000000000000", "4010000000000000", "4014000000000000"),
            ("3f50624dd2f1a9fc", "401e000000000000", "401e000004795318"),
            ("c028800000000000", "3fb999999999999a", "402880357f7557db"),
            ("405edd2f1a9fbe77", "4088a8189374bc6a", "4088f4e59fc8ba4f"),
            ("3fe6a0902de00d1b", "3fe6a0902de00d1b", "3fefffebe3621dbc"),
            ("411e848000000000", "3f689374bc6a7efa", "411e848000000000"),
            ("c062b88fd358f11f", "c061ea7c743e54f9", "4069e996cd6ebbaf"),
            ("4056de98af86bd31", "c03c175124442ea4", "4057ec6adf23ddb5"),
            ("40524bf701eb97ef", "404a8b3e2487167e", "40569a7b09aadfe9"),
            ("40479cd020d539a1", "c055edf238a2dbe4", "4058e7d6faf150bf"),
            ("c052b9644c1272c9", "4024c20d8691841a", "4052e732cdaf7412"),
            ("4061805fdbb780bf", "c03755709cd2aae2", "4061be2ae57e2e2d"),
        ]
        for (a, b, h) in hypots {
            XCTAssertEqual(JS.hypot(Self.double(a), Self.double(b)).bitPattern, Self.double(h).bitPattern, "hypot(\(a), \(b))")
        }
    }

    // MARK: Attacker

    private static func double(_ hex: String) -> Double { Double(bitPattern: UInt64(hex, radix: 16)!) }

    func testTeleportReportsTheFakeSpotConfidently() throws {
        var attacker = GPSAttacker(teleportTo: (x: 160_000, y: -180_000), seed: 3)
        XCTAssertNil(attacker.mode)
        attacker.start(.teleport, t: 10)
        XCTAssertEqual(attacker.mode, .teleport)
        var sum = (x: 0.0, y: 0.0)
        for k in 0..<50 {
            let fix = try XCTUnwrap(attacker.apply(t: 10 + Double(k), x: 5, y: 5, accuracy: 4))
            XCTAssertEqual(fix.accuracy, 3)
            XCTAssertLessThan(hypot(fix.x - 160_000, fix.y + 180_000), 12) // ±2 m per axis
            sum = (sum.x + fix.x / 50, sum.y + fix.y / 50)
        }
        XCTAssertLessThan(hypot(sum.x - 160_000, sum.y + 180_000), 1.5)
    }

    func testJamDegradesForThreeSecondsThenStops() throws {
        var attacker = GPSAttacker(teleportTo: (x: 0, y: 0))
        attacker.start(.jam, t: 100)
        for dt in [0.0, 1, 2, 2.9] {
            let fix = try XCTUnwrap(attacker.apply(t: 100 + dt, x: 10, y: 20, accuracy: 4))
            XCTAssertEqual(fix.accuracy, 60 + 40 * dt, accuracy: 1e-12)
            XCTAssertLessThan(hypot(fix.x - 10, fix.y - 20), 200) // ±30 m per axis
        }
        for dt in [3.0, 3.5, 60] { XCTAssertNil(attacker.apply(t: 100 + dt, x: 10, y: 20, accuracy: 4)) }
        XCTAssertEqual(attacker.elapsed(t: 105), 5)
        attacker.stop()
        XCTAssertEqual(attacker.elapsed(t: 105), 0)
        let fix = try XCTUnwrap(attacker.apply(t: 106, x: 10, y: 20, accuracy: 4))
        XCTAssertEqual([fix.x, fix.y, fix.accuracy], [10, 20, 4])
    }

    func testDragOffsetGrowsAtTheGivenRateAndDirection() throws {
        var attacker = GPSAttacker(teleportTo: (x: 0, y: 0))
        attacker.start(.drag, t: 50, dragRate: 0.4, dragDirectionDegrees: 90)
        var fix = try XCTUnwrap(attacker.apply(t: 60, x: 1, y: 2, accuracy: 4))
        XCTAssertEqual(fix.x, 1 + 0.4 * 10, accuracy: 1e-9)
        XCTAssertEqual(fix.y, 2, accuracy: 1e-9)
        XCTAssertEqual(fix.accuracy, 4)
        // Rate and direction persist into the next drag; a zero rate leaves them (JavaScript `if (rate)`).
        attacker.start(.drag, t: 100, dragRate: 0)
        fix = try XCTUnwrap(attacker.apply(t: 105, x: 0, y: 0, accuracy: 4))
        XCTAssertEqual(fix.x, 2, accuracy: 1e-9)
        XCTAssertEqual(fix.y, 0, accuracy: 1e-9)

        // Default: 0.5 m/s towards 75°.
        var fresh = GPSAttacker(teleportTo: (x: 0, y: 0))
        fresh.start(.drag, t: 0)
        fix = try XCTUnwrap(fresh.apply(t: 10, x: 0, y: 0, accuracy: 5))
        XCTAssertEqual(hypot(fix.x, fix.y), 5, accuracy: 1e-9)
        XCTAssertEqual(atan2(fix.x, fix.y) * 180 / Double.pi, 75, accuracy: 1e-9)
    }

    func testAttackerMatchesJavaScript() throws {
        let golden = try golden().attacker
        // mulberry32 (SeededRandom.next) is bit-identical to geo.js rng.
        var rand = SeededRandom(seed: golden.seed)
        XCTAssertEqual(golden.next.map { _ in rand.next().bitPattern }, golden.next.map { Self.double($0).bitPattern })
        // gauss() goes through libm's log and cos, which differ from V8's in the last bit now and then.
        rand = SeededRandom(seed: golden.seed)
        for hex in golden.gauss {
            let g = rand.gauss(), js = Self.double(hex)
            XCTAssertLessThanOrEqual(abs(g - js), 2 * js.ulp, "gauss \(g) vs \(js)")
        }

        var attacker = GPSAttacker(teleportTo: (x: Self.double(golden.fake[0]), y: Self.double(golden.fake[1])), seed: golden.seed)
        var applied = 0, identical = 0
        for op in golden.ops {
            switch op.op {
            case "start":
                let mode = try XCTUnwrap(op.mode.flatMap(GPSAttack.init(rawValue:)))
                attacker.start(mode, t: Self.double(try XCTUnwrap(op.t)), dragRate: op.dragRate, dragDirectionDegrees: op.dragDir)
            case "stop":
                attacker.stop()
            case "elapsed":
                XCTAssertEqual(attacker.elapsed(t: Self.double(op.t!)).bitPattern, Self.double(op.value!).bitPattern)
            case "apply":
                let fix = attacker.apply(t: Self.double(op.t!), x: Self.double(op.x!), y: Self.double(op.y!),
                                         accuracy: Self.double(op.acc!))
                guard let out = op.out else {
                    XCTAssertNil(fix, "JavaScript reported no fix at \(Self.double(op.t!))")
                    continue
                }
                let got = try XCTUnwrap(fix, "JavaScript reported a fix at \(Self.double(op.t!))")
                let js = out.map(Self.double)
                applied += 1
                if [got.x, got.y, got.accuracy].map(\.bitPattern) == js.map(\.bitPattern) { identical += 1 }
                XCTAssertEqual(got.x, js[0], accuracy: 1e-9)
                XCTAssertEqual(got.y, js[1], accuracy: 1e-9)
                XCTAssertEqual(got.accuracy.bitPattern, js[2].bitPattern)
            default:
                XCTFail("unknown op \(op.op)")
            }
        }
        print("GPSAttacker: \(identical) of \(applied) fixes bit-identical to JavaScript")
    }
}
