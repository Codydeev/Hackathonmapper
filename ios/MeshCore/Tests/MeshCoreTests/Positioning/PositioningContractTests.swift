import XCTest
@testable import MeshCore

/// The engine's output must be valid GhostCore records, and relayed records must only anchor
/// this phone when the contract allows it.
final class PositioningContractTests: XCTestCase {
    private let clock = PZ.Clock(unixMinusMonotonic: 1_793_000_000)
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("contract/fixtures")

    private func map(_ e: PZ.Estimate, upstream: [Provenance] = []) throws -> PositionEstimate {
        let record = PZ.ContractMapping.positionEstimate(e, subjectId: "phone-b", clock: clock, upstream: upstream)
        try record.validate()
        let decoded = try JSONDecoder().decode(PositionEstimate.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
        return record
    }

    private func anchorRSSI(_ e: PZ.Engine, _ spots: [(String, PZ.Vec2)], truth: PZ.Vec2, until: Double) {
        for (id, p) in spots {
            e.ingest(anchor: PZ.Anchor(id: id, position: p, sigma: 3.3, kind: .gnss, measuredAt: 0))
            let value = PZ.PathLossModel.defaultOutdoor.expectedRSSI(distance: p.distance(to: truth))
            var t = 0.0
            while t <= until {
                e.ingest(rssi: PZ.RSSISample(peerId: id, rssi: value, t: t, channel: .advertisement))
                t += 0.2
            }
        }
    }

    func testEveryMethodMapsToAValidRecord() throws {
        let gnss = PZ.Engine(selfId: "phone-b", frameId: "hervanta-v1")
        gnss.ingest(gnss: PZ.GNSSFix(t: 5, position: PZ.Vec2(x: 3, z: 4), horizontalAccuracy: 5, trusted: true))
        let measured = try map(gnss.estimate(at: 5))
        XCTAssertEqual(measured.kind, .measured)
        XCTAssertEqual(measured.method, .gnss)
        XCTAssertEqual(measured.dashboardSource, .gps)
        XCTAssertTrue(measured.provenance.gnssDependent)
        XCTAssertEqual(measured.timestamp, 1_793_000_005)

        let dr = try map(gnss.estimate(at: 30))
        XCTAssertEqual(dr.kind, .estimated)
        XCTAssertEqual(dr.method, .deadReckoning)
        XCTAssertEqual(dr.dashboardSource, .none, "an estimate is never shown as a GPS fix")
        XCTAssertEqual(dr.lastAbsoluteAt, 1_793_000_005)

        let one = PZ.Engine(selfId: "phone-b", frameId: "hervanta-v1")
        anchorRSSI(one, [("phone-a", .zero)], truth: PZ.Vec2(x: 9, z: 8), until: 9)
        let proximity = try map(one.estimate(at: 9))
        XCTAssertEqual(proximity.method, .proximity)
        XCTAssertTrue(proximity.uncertainty.ambiguous, "a disc is not a point claim")
        XCTAssertNil(proximity.candidates)
        XCTAssertEqual(proximity.source, .bluetooth)

        let two = PZ.Engine(selfId: "phone-b", frameId: "hervanta-v1")
        anchorRSSI(two, [("phone-a", .zero), ("phone-c", PZ.Vec2(x: 20, z: 0))], truth: PZ.Vec2(x: 10, z: 8), until: 9)
        let ambiguous = try map(two.estimate(at: 9))
        XCTAssertTrue(ambiguous.uncertainty.ambiguous)
        XCTAssertEqual(ambiguous.candidates?.count, 2)

        let three = PZ.Engine(selfId: "phone-b", frameId: "hervanta-v1")
        anchorRSSI(three, [("phone-a", .zero), ("phone-c", PZ.Vec2(x: 30, z: 0)), ("phone-d", PZ.Vec2(x: 15, z: 26))],
                   truth: PZ.Vec2(x: 14, z: 9), until: 9)
        let upstream = ["phone-a", "phone-c", "phone-d"].map {
            Provenance(producerId: $0, algorithm: "gnss-integrity@1", gnssDependent: true)
        }
        let multi = try map(three.estimate(at: 9), upstream: upstream)
        XCTAssertEqual(multi.method, .multilateration)
        XCTAssertFalse(multi.uncertainty.ambiguous)
        XCTAssertEqual(Set(multi.provenance.contributors), ["phone-b", "phone-a", "phone-c", "phone-d"])
        XCTAssertTrue(multi.provenance.gnssDependent)

        let nothing = PZ.Engine(selfId: "phone-b", frameId: "hervanta-v1")
        let unavailable = try map(nothing.estimate(at: 1))
        XCTAssertEqual(unavailable.kind, .unavailable)
        XCTAssertNil(unavailable.position)

        let declared = PZ.Engine(selfId: "phone-b", frameId: "hervanta-v1")
        declared.declare(position: PZ.Vec2(x: 1, z: 2), sigma: 1, at: 1)
        XCTAssertEqual(try map(declared.estimate(at: 1)).kind, .declared)
    }

    func testMotionSummaryMapsToAValidMotionObservation() throws {
        let e = PZ.Engine(selfId: "phone-b", frameId: "hervanta-v1")
        e.declare(position: .zero, sigma: 1, at: 0)
        e.ingest(compass: PZ.CompassSample(t: 0, heading: 0, sigma: PZ.degrees(5)))
        var t = 0.02
        while t < 10 {
            e.ingest(motion: PZ.MotionSample(t: t, gravity: PZ.Vec3(0, 0, -1),
                                             userAcceleration: PZ.Vec3(0, 0, 0.3 * sin(2 * .pi * 1.8 * t)), rotationRate: PZ.Vec3(0, 0, 0)))
            t += 0.02
        }
        let record = PZ.ContractMapping.motionObservation(e.motionSummary(at: t, window: 5), subjectId: "phone-b",
                                                          frameId: "hervanta-v1", clock: clock)
        try record.validate()
        XCTAssertEqual(record.steps ?? 0, 9, accuracy: 1)
        XCTAssertGreaterThan(record.displacement!.z, 5, "walking north")
        XCTAssertFalse(record.stationary)
    }

    private func relayed(_ id: String, kind: PositionEstimate.Kind = .measured, method: PositionEstimate.Method = .gnss,
                         contributors: [String]? = nil, ambiguous: Bool = false, age: Double = 1) -> PositionEstimate {
        let source: EvidenceSource = kind == .measured ? .gnss : .fusion
        return PositionEstimate(subjectId: id, timestamp: 1_793_000_100, frameId: "hervanta-v1", kind: kind, method: method,
                                position: Position(x: 10, y: 0, z: 5), uncertainty: PositionUncertainty(r95: 8.1, ambiguous: ambiguous),
                                source: source, freshness: Freshness(ageAtHandoff: age, maxAge: 10),
                                provenance: Provenance(producerId: id, algorithm: "test@1", contributors: contributors ?? [id],
                                                       gnssDependent: true))
    }

    private func integrity(_ id: String, _ status: IntegrityAssessment.Status) -> IntegrityAssessment {
        IntegrityAssessment(subjectId: id, timestamp: 1_793_000_100, frameId: "hervanta-v1", status: status, trustScore: 0.9,
                            uncertainty: .init(lower: 0.8, upper: 0.95), reasons: status == .trusted ? [] : [.positionJump],
                            freshness: Freshness(maxAge: 5), provenance: Provenance(producerId: id, algorithm: "gnss-integrity@1", gnssDependent: true))
    }

    func testGNSSAnchorNeedsATrustedIntegrityAssessment() {
        let p = relayed("phone-a")
        XCTAssertEqual(PZ.ContractMapping.anchor(from: p, integrity: nil, selfId: "phone-b", receivedAt: 50),
                       .refused("no integrity assessment"))
        XCTAssertEqual(PZ.ContractMapping.anchor(from: p, integrity: integrity("phone-a", .suspect), selfId: "phone-b", receivedAt: 50),
                       .refused("GNSS not trusted: suspect"))
        XCTAssertEqual(PZ.ContractMapping.anchor(from: p, integrity: integrity("phone-c", .trusted), selfId: "phone-b", receivedAt: 50),
                       .refused("no integrity assessment"), "an assessment about another phone does not count")
        guard case .anchor(let a) = PZ.ContractMapping.anchor(from: p, integrity: integrity("phone-a", .trusted),
                                                              selfId: "phone-b", receivedAt: 50) else { return XCTFail() }
        XCTAssertEqual(a.kind, .gnss)
        XCTAssertEqual(a.measuredAt, 49, "receipt time minus the age it already had, never the sender's clock")
        XCTAssertEqual(a.sigma, 8.1 / PositionUncertainty.sigmaTo95, accuracy: 1e-9)
        XCTAssertTrue(a.gnssDependent)
    }

    func testLoopsRegionsAndPredictionsNeverAnchor() {
        let loop = relayed("phone-c", kind: .estimated, method: .fusion, contributors: ["phone-c", "phone-b"])
        XCTAssertEqual(PZ.ContractMapping.anchor(from: loop, integrity: nil, selfId: "phone-b", receivedAt: 50),
                       .refused("depends on this phone"))
        let ring = relayed("phone-c", kind: .estimated, method: .proximity, ambiguous: true)
        XCTAssertEqual(PZ.ContractMapping.anchor(from: ring, integrity: nil, selfId: "phone-b", receivedAt: 50),
                       .refused("no single position"))
        let estimated = relayed("phone-c", kind: .estimated, method: .fusion, contributors: ["phone-c", "phone-a"])
        guard case .anchor(let a) = PZ.ContractMapping.anchor(from: estimated, integrity: nil, selfId: "phone-b", receivedAt: 50)
        else { return XCTFail() }
        XCTAssertEqual(a.kind, .estimated)
        XCTAssertEqual(a.dependsOn, ["phone-c", "phone-a"])
    }

    func testPeerObservationSamplesAreTimedOnTheRightClock() throws {
        let fixture = try JSONDecoder().decode(PeerObservation.self,
                                               from: Data(contentsOf: Self.fixtures.appendingPathComponent("peer-observation.json")))
        // Our own snapshot (observer phone-b): spread over its window, ending at its timestamp.
        let own = PZ.ContractMapping.rssiSamples(from: fixture, selfId: "phone-b", receivedAt: 0, clock: clock)
        XCTAssertEqual(own.map(\.rssi), [-71, -74, -69])
        XCTAssertEqual(own.map(\.peerId), ["phone-a", "phone-a", "phone-a"])
        XCTAssertEqual(own.last!.t, clock.monotonic(fixture.timestamp), accuracy: 1e-9)
        XCTAssertEqual(own.last!.t - own.first!.t, fixture.window, accuracy: 1e-9)
        XCTAssertEqual(own.first?.channel, .connection)

        // The same snapshot received by phone-a is phone-b hearing phone-a's signal: reciprocal.
        let reciprocal = PZ.ContractMapping.rssiSamples(from: fixture, selfId: "phone-a", receivedAt: 200, clock: clock)
        XCTAssertEqual(reciprocal.map(\.peerId), ["phone-b", "phone-b", "phone-b"])
        XCTAssertEqual(reciprocal.first?.channel, .reciprocal)
        XCTAssertEqual(reciprocal.last!.t, 200 - fixture.freshness.ageAtHandoff, accuracy: 1e-9)

        XCTAssertTrue(PZ.ContractMapping.rssiSamples(from: fixture, selfId: "phone-c", receivedAt: 0, clock: clock).isEmpty)
    }

    func testLogRecordsRoundTripAndReplayIdentically() throws {
        var walk = SyntheticWalk()
        walk.duration = 90
        walk.gnssUntil = 30
        walk.anchors = SyntheticWalk.fourCornerAnchors(seed: 1)
        let records = walk.generate().records
        let decoded = try PZ.LogRecord.decodeLines(PZ.LogRecord.encodeLines(records))
        XCTAssertEqual(decoded, records)
        let a = PZ.Replay.run(records, engine: PZ.Engine(selfId: "phone-b", frameId: "hervanta-v1"))
        let b = PZ.Replay.run(decoded, engine: PZ.Engine(selfId: "phone-b", frameId: "hervanta-v1"))
        XCTAssertEqual(a.map(\.estimate), b.map(\.estimate))
        XCTAssertGreaterThanOrEqual(a.count, 90, "one estimate a second")
    }
}
