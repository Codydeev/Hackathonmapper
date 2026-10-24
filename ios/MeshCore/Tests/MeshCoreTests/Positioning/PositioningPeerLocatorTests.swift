import XCTest
@testable import MeshCore

/// The peer locator in the pipeline's positioning slot, against today's BluetoothEstimator, on every
/// contract scenario (headless ScenarioWorld, synthetic). Acceptance for swapping it in: every
/// gating expectation passes, S5-c improves, S1-c and S6-b do not get worse, with the baseline
/// engines and with every merged GhostCore engine.
///
/// With two anchors 14 m apart, B walking away in S5 has a mirror twin, so the honest estimate is
/// ambiguous and its region centre moves in a direction B does not. A predictor that took that
/// centre's motion as B's velocity would suffer; the last test checks the region reading.
final class PositioningPeerLocatorTests: XCTestCase {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("contract/scenarios")

    private func scenarios() throws -> [Scenario] {
        try FileManager.default.contentsOfDirectory(atPath: Self.folder.path).filter { $0.hasSuffix(".json") }.sorted()
            .map { try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: Self.folder.appendingPathComponent($0))) }
    }

    /// "held 62% of 141 s" -> 0.62
    private func fraction(_ r: ScenarioWorld.Result) -> Double? {
        guard let range = r.detail.range(of: #"held (\d+)%"#, options: .regularExpression) else { return nil }
        return Double(r.detail[range].dropFirst(5).dropLast()).map { $0 / 100 }
    }

    private func world(_ scenario: Scenario, locator: Bool, ghostcore: Bool) -> ScenarioWorld {
        let positioning: ScenarioWorld.Factory<GhostPositioningEngine>? = locator
            ? { Positioning.PeerLocator(producerId: $0, frameId: $1) } : nil
        return ghostcore
            ? ScenarioWorld(scenario: scenario, integrity: { GNSSIntegrityMonitor(subjectId: $0, frameId: $1) },
                            positioning: positioning, prediction: { GhostPredictor(producerId: $0, frameId: $1) })
            : ScenarioWorld(scenario: scenario, positioning: positioning)
    }

    func testPeerLocatorAgainstTheEstimatorOnEveryScenario() throws {
        let compared: Set = ["S1-c", "S5-c", "S6-b"]
        for ghostcore in [false, true] {
            let label = ghostcore ? "ghostcore engines" : "baseline engines"
            var lines = ["", "### PeerLocator vs BluetoothEstimator, \(label) (synthetic)",
                         "| expectation | estimator | peer locator |", "|---|---|---|"]
            var before: [String: Double] = [:]
            var after: [String: Double] = [:]
            for scenario in try scenarios() {
                let old = world(scenario, locator: false, ghostcore: ghostcore).run()
                let new = world(scenario, locator: true, ghostcore: ghostcore).run()
                XCTAssertEqual(new.gateFailures, [], "\(label) \(scenario.id): \(new.gateFailures.map { "\($0.id) \($0.detail)" })")
                for (o, n) in zip(old.results, new.results) where compared.contains(o.id) || o.outcome != n.outcome {
                    lines.append("| \(o.id) | \(o.outcome.rawValue): \(o.detail) | \(n.outcome.rawValue): \(n.detail) |")
                    before[o.id] = fraction(o)
                    after[n.id] = fraction(n)
                }
            }
            print(lines.joined(separator: "\n"))
            XCTAssertGreaterThanOrEqual(after["S1-c"] ?? 0, before["S1-c"] ?? 1, "\(label): S1-c must not get worse")
            XCTAssertGreaterThanOrEqual(after["S6-b"] ?? 0, before["S6-b"] ?? 1, "\(label): S6-b must not get worse")
            XCTAssertGreaterThan(after["S5-c"] ?? 0, before["S5-c"] ?? 1, "\(label): S5-c must improve")
        }
    }

    private func gnssAnchor(_ id: String, _ x: Double, _ z: Double, at now: Double, contributors: [String]? = nil) -> PositionEstimate {
        PositionEstimate(subjectId: id, timestamp: now, frameId: "hervanta-v1", kind: .measured, method: .gnss,
                         position: Position(x: x, y: 0, z: z), uncertainty: PositionUncertainty(r95: 8.1), source: .gnss,
                         freshness: Freshness(maxAge: 30),
                         provenance: Provenance(producerId: id, algorithm: "gnss@1", contributors: contributors ?? [id], gnssDependent: true))
    }

    private func link(_ anchor: String, _ ax: Double, _ az: Double, to truth: PZ.Vec2) -> LinkMeasurement {
        LinkMeasurement(a: anchor, b: "phone-b",
                        rssi: PZ.PathLossModel.defaultOutdoor.expectedRSSI(distance: hypot(truth.x - ax, truth.z - az)))
    }

    func testKindsProvenanceAndRefusals() throws {
        let truth = PZ.Vec2(x: 14, z: 9)
        let spots = [("phone-a", 0.0, 0.0), ("phone-c", 30.0, 0.0), ("phone-d", 15.0, 26.0)]

        // One anchor: a disc, flagged ambiguous, never a point claim; listed with its id as GNSS.
        let one = Positioning.PeerLocator(producerId: "phone-a", frameId: "hervanta-v1")
        var e: PositionEstimate?
        for s in 0..<10 {
            let now = 1_793_000_000 + Double(s)
            e = one.place(anchors: [gnssAnchor("phone-a", 0, 0, at: now)], lost: ["phone-b"],
                          links: [link("phone-a", 0, 0, to: truth)], observations: [], now: now).first
        }
        let disc = try XCTUnwrap(e)
        try disc.validate()
        XCTAssertEqual(disc.method, .proximity)
        XCTAssertTrue(disc.uncertainty.ambiguous)
        XCTAssertNil(disc.candidates)
        XCTAssertGreaterThanOrEqual(disc.uncertainty.r95, hypot(truth.x, truth.z))
        XCTAssertEqual(disc.provenance.producerId, "phone-a")
        XCTAssertTrue(disc.provenance.contains(device: "phone-b"), "the placed phone's own link readings count")
        XCTAssertTrue(disc.provenance.inputs.contains { $0.source == .gnss && $0.id == "phone-a" && $0.used })

        // Three well-placed anchors: a point.
        let three = Positioning.PeerLocator(producerId: "phone-a", frameId: "hervanta-v1")
        for s in 0..<10 {
            let now = 1_793_000_000 + Double(s)
            e = three.place(anchors: spots.map { gnssAnchor($0.0, $0.1, $0.2, at: now) }, lost: ["phone-b"],
                            links: spots.map { link($0.0, $0.1, $0.2, to: truth) }, observations: [], now: now).first
        }
        let point = try XCTUnwrap(e)
        XCTAssertEqual(point.method, .multilateration)
        XCTAssertFalse(point.uncertainty.ambiguous)
        XCTAssertLessThan(hypot(point.position!.x - truth.x, point.position!.z - truth.z), point.uncertainty.r95)
        XCTAssertEqual(Set(point.provenance.inputs.filter { $0.source == .gnss }.compactMap(\.id)), ["phone-a", "phone-c", "phone-d"])

        // An anchor whose own position rests on the lost phone is not used.
        let loop = Positioning.PeerLocator(producerId: "phone-a", frameId: "hervanta-v1")
        let out = loop.place(anchors: [gnssAnchor("phone-c", 30, 0, at: 1_793_000_000, contributors: ["phone-c", "phone-b"])],
                             lost: ["phone-b"], links: [link("phone-c", 30, 0, to: truth)], observations: [], now: 1_793_000_000)
        XCTAssertTrue(out.isEmpty)
    }

    func testRememberedFixIsNeverReportedAsMeasured() throws {
        let locator = Positioning.PeerLocator(producerId: "phone-a", frameId: "hervanta-v1")
        let t0 = 1_793_000_000.0
        _ = locator.place(anchors: [gnssAnchor("phone-a", 0, 0, at: t0), gnssAnchor("phone-b", 15, 10, at: t0)], lost: [],
                          links: [], observations: [], now: t0)
        let lost = try XCTUnwrap(locator.place(anchors: [gnssAnchor("phone-a", 0, 0, at: t0 + 1)], lost: ["phone-b"],
                                               links: [link("phone-a", 0, 0, to: PZ.Vec2(x: 15, z: 10))], observations: [], now: t0 + 1).first)
        XCTAssertEqual(lost.kind, .estimated)
        XCTAssertNotEqual(lost.source, .gnss)
        XCTAssertLessThan(hypot(lost.position!.x - 15, lost.position!.z - 10), lost.uncertainty.r95)
    }

    /// What S5-c is when Ghost Mode takes an ambiguous estimate as a region (no velocity from its
    /// moving centre) instead of a point. Test-only wrapper; the predictor itself is not changed.
    func testS5WithAPredictorThatRespectsAmbiguity() throws {
        final class AmbiguityAware: GhostPredictionEngine {
            let ghost: GhostPredictor
            let circle: WalkingCirclePrediction
            var lastAmbiguous: [String: Bool] = [:]
            init(_ id: String, _ frame: String) {
                ghost = GhostPredictor(producerId: id, frameId: frame)
                circle = WalkingCirclePrediction(producerId: id)
            }
            func observe(_ e: PositionEstimate, receivedAt: Double) {
                guard e.kind != .predicted, e.kind != .unavailable else { return }
                lastAmbiguous[e.subjectId] = e.uncertainty.ambiguous
                circle.observe(e, receivedAt: receivedAt)
                if !e.uncertainty.ambiguous { ghost.observe(e, receivedAt: receivedAt) }
            }
            func observe(_ m: MotionObservation) { ghost.observe(m) }
            func predict(subjectId: String, at now: Double) -> Prediction? {
                lastAmbiguous[subjectId] == true ? circle.predict(subjectId: subjectId, at: now)
                    : ghost.predict(subjectId: subjectId, at: now)
            }
        }
        let scenario = try scenarios().first { $0.id == "S5" }!
        var lines = ["", "### S5 with a predictor that treats ambiguous estimates as regions (synthetic, informational)",
                     "| positioning | S5-a | S5-b | S5-c |", "|---|---|---|---|"]
        var held: [Bool: Double] = [:]
        for locator in [false, true] {
            let report = ScenarioWorld(scenario: scenario, integrity: { GNSSIntegrityMonitor(subjectId: $0, frameId: $1) },
                                       positioning: locator ? { Positioning.PeerLocator(producerId: $0, frameId: $1) } : nil,
                                       prediction: { AmbiguityAware($0, $1) }).run()
            XCTAssertEqual(report.gateFailures, [])
            held[locator] = report.results.first { $0.id == "S5-c" }.flatMap(fraction)
            let cells = report.results.map { "\($0.outcome.rawValue): \($0.detail)" }
            lines.append("| \(locator ? "peer locator" : "estimator") | " + cells.joined(separator: " | ") + " |")
        }
        print(lines.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(held[true] ?? 0, 0.9)
        XCTAssertGreaterThan(held[true] ?? 0, held[false] ?? 1)
    }
}
