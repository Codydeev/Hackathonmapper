import XCTest
@testable import MeshCore

/// Accuracy against ground truth on synthetic tracks (never field accuracy). Each scenario runs a
/// few seeds through four variants on identical data and scores the GNSS outage only:
/// - hold-last: the last trusted fix with a circle growing at walking pace (the app before this)
/// - pdr: the engine without Bluetooth
/// - ble: the engine without motion sensors
/// - fusion: everything
/// Set POSITIONING_SEEDS for more seeds and POSITIONING_REPORT=<path> to write the JSON report.
final class PositioningAccuracyTests: XCTestCase {
    struct VariantResult: Codable {
        let summary: PZ.AccuracySummary
        /// Pooled median error at fixed times after GNSS was lost.
        let horizonErrors: [String: Double]
        /// Seconds after the outage until the first non-unavailable estimate (worst seed).
        let placedAfter: Double?
    }

    struct ScenarioResult: Codable {
        let name: String
        let seeds: Int
        let outage: Double
        let variants: [String: VariantResult]
    }

    private static var report: [ScenarioResult] = []
    private var seeds: [UInt64] {
        let n = ProcessInfo.processInfo.environment["POSITIONING_SEEDS"].flatMap(Int.init) ?? 6
        return (1...UInt64(max(1, n))).map { $0 }
    }

    private func engine(bluetooth: Bool = true, motion: Bool = true) -> PZ.Engine {
        var config = PZ.Engine.Config()
        config.useBluetooth = bluetooth
        config.useMotion = motion
        config.useCompass = motion
        return PZ.Engine(selfId: "phone-b", frameId: "hervanta-v1", config: config)
    }

    private func run(_ name: String, outageFrom lossAt: Double, _ make: (UInt64) -> SyntheticWalk,
                     variants: [String] = ["hold-last", "pdr", "ble", "fusion"]) -> ScenarioResult {
        var pooled: [String: [PZ.ReplayEpoch]] = [:]
        var horizons: [String: [Int: [Double]]] = [:]
        var placed: [String: [Double]] = [:]
        var duration = 0.0
        for seed in seeds {
            let walk = make(seed)
            duration = walk.duration
            let records = walk.generate().records
            for v in variants {
                let epochs: [PZ.ReplayEpoch]
                switch v {
                case "hold-last": epochs = HoldLastBaseline.run(records, end: walk.duration)
                case "pdr": epochs = PZ.Replay.run(records, engine: engine(bluetooth: false))
                case "ble": epochs = PZ.Replay.run(records, engine: engine(motion: false))
                default: epochs = PZ.Replay.run(records, engine: engine())
                }
                let outage = epochs.filter { $0.estimate.t > lossAt }
                pooled[v, default: []] += outage
                for h in [10, 30, 60, 120, 180, 300, 600] {
                    if let e = outage.first(where: { abs($0.estimate.t - (lossAt + Double(h))) < 0.5 }) {
                        if let err = e.error ?? e.candidateError ?? e.truth.flatMap({ t in e.estimate.regionCenter.map { $0.distance(to: t) } }) {
                            horizons[v, default: [:]][h, default: []].append(err)
                        }
                    }
                }
                if let first = outage.first(where: { $0.estimate.method != .unavailable }) {
                    placed[v, default: []].append(first.estimate.t - lossAt)
                } else {
                    placed[v, default: []].append(.infinity)
                }
            }
        }
        var results: [String: VariantResult] = [:]
        for v in variants {
            let h = (horizons[v] ?? [:]).reduce(into: [String: Double]()) { $0["\($1.key)s"] = PZ.Stats.median($1.value) }
            results[v] = VariantResult(summary: .of(pooled[v] ?? []), horizonErrors: h, placedAfter: placed[v]?.max())
        }
        let scenario = ScenarioResult(name: name, seeds: seeds.count, outage: duration - lossAt, variants: results)
        Self.report.append(scenario)
        print(Self.table(scenario))
        return scenario
    }

    static func table(_ s: ScenarioResult) -> String {
        func f(_ v: Double?) -> String { v.map { $0.isFinite ? String(format: "%.1f", $0) : "never" } ?? "-" }
        func pct(_ v: Double?) -> String { v.map { String(format: "%.0f%%", 100 * $0) } ?? "-" }
        var lines = ["", "### \(s.name) (\(s.seeds) seeds, \(Int(s.outage)) s outage)",
                     "| variant | median err | p95 err | median r95 | truth in r95 | point avail | placed after | err@60s | err@120s | err@300s | methods |",
                     "|---|---|---|---|---|---|---|---|---|---|---|"]
        for name in ["hold-last", "pdr", "ble", "fusion"] {
            guard let v = s.variants[name] else { continue }
            let m = v.summary
            let methods = m.methods.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            lines.append("| \(name) | \(f(m.medianError)) | \(f(m.p95Error)) | \(f(m.medianR95)) | \(pct(m.containment)) | \(pct(m.pointAvailability)) | \(f(v.placedAfter)) | \(f(v.horizonErrors["60s"])) | \(f(v.horizonErrors["120s"])) | \(f(v.horizonErrors["300s"])) | \(methods) |")
        }
        return lines.joined(separator: "\n")
    }

    override class func tearDown() {
        if let path = ProcessInfo.processInfo.environment["POSITIONING_REPORT"], !report.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: URL(fileURLWithPath: path))
        }
        super.tearDown()
    }

    // MARK: - Scenarios

    /// ARCHITECTURE.md S1 / T5: B loses GNSS on a 3-minute loop, one trusted phone 10-20 m away.
    static func s1(_ seed: UInt64) -> SyntheticWalk {
        var w = SyntheticWalk()
        w.seed = seed
        w.duration = 240
        w.gnssUntil = 60
        w.waypoints = [PZ.Vec2(x: 30, z: 0), PZ.Vec2(x: 30, z: 20), PZ.Vec2(x: 0, z: 20), PZ.Vec2(x: 0, z: 0)]
        w.pauses = [(150, 10)]
        w.disturbances = [.init(center: PZ.Vec2(x: 30, z: 20), radius: 5, bias: PZ.degrees(35), flagged: false)]
        var r = SimRandom(seed: seed &+ 7)
        w.anchors = [.init(id: "phone-a", position: PZ.Vec2(x: 15, z: 10), rssiOffset: 2 * r.gauss())]
        w.strideLength = r.uniform(0.66, 0.80)
        w.accelAmplitude = r.uniform(0.25, 0.35)
        return w
    }

    static func fourAnchors(_ seed: UInt64) -> SyntheticWalk {
        var w = SyntheticWalk()
        w.seed = seed
        w.anchors = SyntheticWalk.fourCornerAnchors(seed: seed)
        var r = SimRandom(seed: seed &+ 7)
        w.strideLength = r.uniform(0.66, 0.80)
        w.accelAmplitude = r.uniform(0.25, 0.35)
        return w
    }

    func testS1OutageWithOneTrustedNeighbour() {
        let s = run("S1/T5: one trusted neighbour, 3 min outage, synthetic", outageFrom: 60, Self.s1)
        let fusion = s.variants["fusion"]!
        // AC-4: placed within 5 s; truth inside r95 in >= 90 % of 1 s samples.
        XCTAssertLessThanOrEqual(fusion.placedAfter!, 5)
        XCTAssertGreaterThanOrEqual(fusion.summary.containment!, 0.90)
        XCTAssertGreaterThanOrEqual(s.variants["ble"]!.summary.containment!, 0.90, "one anchor alone: honest region")
        XCTAssertLessThan(fusion.summary.medianError!, s.variants["hold-last"]!.summary.medianError!)
    }

    /// S1 with sensors worse than the model assumes: unseen speed changes, a 1°/s gyro bias, noisy
    /// compass with unflagged disturbances, 5 m correlated GNSS error, ±4 dB phones, 6 dB shadowing.
    static func s1Harsh(_ seed: UInt64) -> SyntheticWalk {
        var w = s1(seed)
        var r = SimRandom(seed: seed &+ 13)
        w.strideVariation = 0.15
        w.gyroBias = PZ.degrees(1)
        w.compassNoise = PZ.degrees(10)
        w.disturbances = [
            .init(center: PZ.Vec2(x: 30, z: 20), radius: 6, bias: PZ.degrees(50), flagged: false),
            .init(center: PZ.Vec2(x: 0, z: 10), radius: 5, bias: PZ.degrees(-40), flagged: false),
            .init(center: PZ.Vec2(x: 15, z: 0), radius: 4, bias: PZ.degrees(60), flagged: false),
        ]
        w.gnssCorrelated = 5
        w.shadowSigma = 6
        w.anchors = [.init(id: "phone-a", position: PZ.Vec2(x: 15, z: 10), rssiOffset: 4 * r.gauss())]
        return w
    }

    func testS1WithHarshSensors() {
        let s = run("S1 harsh: unseen speed changes, 1°/s gyro bias, disturbed compass, 6 dB shadowing, synthetic", outageFrom: 60, Self.s1Harsh)
        let fusion = s.variants["fusion"]!
        XCTAssertLessThanOrEqual(fusion.placedAfter!, 5)
        // Beyond the model on purpose; AC-4's 90 % applies to S1 above. Here r95 must degrade, not collapse.
        XCTAssertGreaterThanOrEqual(fusion.summary.containment!, 0.85, "worse sensors must widen r95, not break it")
    }

    func testFourAnchorsTenMinuteOutage() {
        let s = run("Four anchors, 10 min outage, synthetic", outageFrom: 120, Self.fourAnchors)
        let fusion = s.variants["fusion"]!.summary
        let pdr = s.variants["pdr"]!.summary
        let hold = s.variants["hold-last"]!.summary
        XCTAssertGreaterThanOrEqual(fusion.containment!, 0.90)
        XCTAssertLessThan(fusion.medianError!, pdr.medianError!)
        XCTAssertLessThan(fusion.medianError!, hold.medianError!)
    }

    func testNoAnchorsDeadReckoningOnly() {
        let s = run("No anchors, 10 min outage, synthetic", outageFrom: 120, { seed in
            var w = Self.fourAnchors(seed)
            w.anchors = []
            return w
        }, variants: ["hold-last", "pdr"])
        let pdr = s.variants["pdr"]!.summary
        XCTAssertGreaterThanOrEqual(pdr.containment!, 0.90)
        XCTAssertLessThan(pdr.medianError!, s.variants["hold-last"]!.summary.medianError!)
    }

    /// Scores a walk recorded on a phone (PositioningService.startRecording). With "simulate losing
    /// GPS" on, the hidden fixes are already reference records; for a walk recorded with GPS in use,
    /// set POSITIONING_MASK_AFTER=<seconds of monotonic time> to hide fixes after that time instead.
    ///   POSITIONING_LOG=walk.jsonl swift test --filter PositioningAccuracyTests/testReplayRecordedWalk
    func testReplayRecordedWalk() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["POSITIONING_LOG"] else { throw XCTSkip("set POSITIONING_LOG to a recorded .jsonl walk") }
        let records = try PZ.LogRecord.decodeLines(Data(contentsOf: URL(fileURLWithPath: path)))
        var selfId = "phone"
        var frameId = GeoFrame.defaultFrameId
        for case .header(let id, let frame, _) in records {
            selfId = id
            frameId = frame
        }
        var options = PZ.Replay.Options()
        options.maskGNSSAfter = env["POSITIONING_MASK_AFTER"].flatMap(Double.init)
        let epochs = PZ.Replay.run(records, engine: PZ.Engine(selfId: selfId, frameId: frameId), options: options)
        let lossAt = options.maskGNSSAfter ?? epochs.first { $0.truth != nil }?.estimate.t ?? 0
        let outage = epochs.filter { $0.estimate.t > lossAt }
        let summary = PZ.AccuracySummary.of(outage)
        let placed = outage.first { $0.estimate.method != .unavailable }.map { $0.estimate.t - lossAt }
        let scenario = ScenarioResult(name: "Recorded walk \(URL(fileURLWithPath: path).lastPathComponent), scored against its GPS reference (which has its own error)",
                                      seeds: 1, outage: (outage.last?.estimate.t ?? lossAt) - lossAt,
                                      variants: ["fusion": VariantResult(summary: summary, horizonErrors: [:], placedAfter: placed)])
        Self.report.append(scenario)
        print(Self.table(scenario))
        XCTAssertGreaterThan(summary.epochs, 0, "no reference positions in the recording")
    }

    func testColdStartWithoutGNSS() {
        let s = run("Cold start, never any GNSS, four anchors, synthetic", outageFrom: 0, { seed in
            var w = Self.fourAnchors(seed)
            w.gnssUntil = 0
            w.duration = 300
            return w
        }, variants: ["ble", "fusion"])
        XCTAssertGreaterThanOrEqual(s.variants["fusion"]!.summary.containment!, 0.85)
    }
}
