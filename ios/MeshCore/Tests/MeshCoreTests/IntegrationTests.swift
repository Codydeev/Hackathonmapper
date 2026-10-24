import Foundation
import XCTest
@testable import MeshCore

/// GhostCorePipeline rules from ARCHITECTURE.md §6: only trusted GNSS is published and anchors
/// others, rejected fixes stay visible but are never selected, scenario faults mark what they touch.
final class IntegrationTests: XCTestCase {
    private let t0 = 1_793_000_000.0

    /// Returns whatever status the test sets, as a valid assessment of the latest fix.
    private final class StubIntegrity: GhostIntegrityEngine {
        var status: IntegrityAssessment.Status
        var fix: PositionEstimate?
        init(_ status: IntegrityAssessment.Status) { self.status = status }
        func ingest(fix: PositionEstimate) { self.fix = fix }
        func ingest(motion: MotionObservation) {}
        func assess(subjectId: String, evidence: [PositionEstimate], now: Double) -> IntegrityAssessment {
            let score = status == .trusted ? 0.9 : 0.1
            return IntegrityAssessment(
                subjectId: subjectId, timestamp: now, frameId: "hervanta-v1", status: status, trustScore: score,
                uncertainty: .init(lower: 0, upper: score),
                reasons: [.suspect, .rejected, .degraded].contains(status) ? [.positionJump] : [],
                evaluatedFix: status == .unavailable ? nil : fix, freshness: Freshness(maxAge: 5),
                provenance: Provenance(producerId: subjectId, algorithm: "stub@1", gnssDependent: true))
        }
    }

    private func fix(_ id: String, x: Double, z: Double, at t: Double) -> PositionEstimate {
        PositionEstimate(subjectId: id, timestamp: t, frameId: "hervanta-v1", kind: .measured, method: .gnss,
                         position: Position(x: x, y: 0, z: z), uncertainty: PositionUncertainty(r95: 8),
                         source: .gnss, freshness: Freshness(maxAge: 30),
                         provenance: Provenance(producerId: id, algorithm: "test@1", gnssDependent: true))
    }

    private func pipeline(_ integrity: GhostIntegrityEngine?) -> GhostCorePipeline {
        GhostCorePipeline(configuration: .init(selfId: "phone-a", frameId: "hervanta-v1"), integrity: integrity)
    }

    func testWithoutIntegrityEngineGPSIsSharedButUnchecked() {
        let p = pipeline(nil)
        p.ingest(fix: fix("phone-a", x: 3, z: 4, at: t0), receivedAt: t0)
        let out = p.step(now: t0 + 1)
        XCTAssertEqual(out.publication.source, .gps)
        XCTAssertFalse(out.integrityEngineActive)
        let me = out.phones.first { $0.isSelf }
        XCTAssertEqual(me?.selected?.method, .gnss)
        XCTAssertNil(me?.integrity, "never faked as trusted")
    }

    func testOnlyTrustedGPSIsPublished() {
        for (status, published, shownAsGNSS) in [(IntegrityAssessment.Status.trusted, PositionSource.gps, true),
                                                 (.insufficientEvidence, .none, true), (.degraded, .none, true),
                                                 (.suspect, .none, false), (.rejected, .none, false)] {
            let p = pipeline(StubIntegrity(status))
            p.ingest(fix: fix("phone-a", x: 3, z: 4, at: t0), receivedAt: t0)
            let out = p.step(now: t0 + 1)
            XCTAssertEqual(out.publication.source, published, "\(status)")
            let me = out.phones.first { $0.isSelf }
            XCTAssertEqual(me?.selected?.method == .gnss, shownAsGNSS, "\(status)")
            XCTAssertEqual(me?.gnssUnconfirmed, [.insufficientEvidence, .degraded].contains(status), "\(status)")
            XCTAssertNotNil(me?.rawFix, "the raw fix stays visible")
            XCTAssertEqual(me?.integrity?.status, status)
        }
    }

    func testTypedSpotWinsAndIsDeclared() {
        let p = pipeline(nil)
        p.declared = (Position(x: 1, y: 0, z: 2), 3)
        p.ingest(fix: fix("phone-a", x: 3, z: 4, at: t0), receivedAt: t0)
        let out = p.step(now: t0 + 1)
        XCTAssertEqual(out.publication.source, .manual)
        XCTAssertEqual(out.phones.first { $0.isSelf }?.selected?.kind, .declared)
    }

    func testFaultsShiftDriftAndDropFixesAndMarkThemSimulated() throws {
        var faults = GNSSFaults()
        let clean = fix("phone-a", x: 0, z: 0, at: t0 + 10)
        XCTAssertEqual(faults.apply(to: clean), clean)
        faults.apply(.gnssJump(subjectId: "phone-a", dx: 400, dz: 0), at: t0)
        let jumped = try XCTUnwrap(faults.apply(to: clean))
        XCTAssertEqual(jumped.position?.x, 400)
        XCTAssertTrue(jumped.provenance.simulated)
        XCTAssertNoThrow(try jumped.validate())
        faults.apply(.gnssClear(subjectId: "phone-a"), at: t0)
        faults.apply(.gnssDrift(subjectId: "phone-a", metersPerSecond: 1, bearingDegrees: 90), at: t0)
        XCTAssertEqual(try XCTUnwrap(faults.apply(to: clean)?.position?.x), 10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(faults.apply(to: clean)?.position?.z), 0, accuracy: 1e-9)
        faults.apply(.gnssOutage(subjectId: "phone-a", active: true), at: t0)
        XCTAssertNil(faults.apply(to: clean))
    }

    func testScenarioInputsOnlyActOnTheirOwnPhone() {
        let p = pipeline(nil)
        p.apply(.gnssOutage(subjectId: "phone-b", active: true), at: t0)
        XCTAssertFalse(p.faults.isActive)
        p.apply(.gnssOutage(subjectId: "phone-a", active: true), at: t0)
        p.ingest(fix: fix("phone-a", x: 3, z: 4, at: t0), receivedAt: t0)
        XCTAssertNil(p.step(now: t0 + 1).phones.first { $0.isSelf }?.rawFix)
    }

    func testScenarioInputJSONRoundTrips() throws {
        let inputs: [ScenarioInput] = [
            .gnssOutage(subjectId: "a", active: true), .gnssJump(subjectId: "a", dx: 1, dz: -2),
            .gnssDrift(subjectId: "a", metersPerSecond: 1, bearingDegrees: 90), .gnssClear(subjectId: "a"),
            .peerLink(subjectId: "a", peerId: "b", up: false),
        ]
        let data = try JSONEncoder().encode(inputs)
        XCTAssertEqual(try JSONDecoder().decode([ScenarioInput].self, from: data), inputs)
    }

    func testPeerGPSReportAnchorsAndIsMeasured() {
        let p = pipeline(nil)
        let report = DeviceUpdate(id: "phone-b", label: "B", epochId: UUID().uuidString, sequence: 1, role: "mobile",
                                  position: Position(x: 10, y: 0, z: 0), positionMode: "floor", accuracyMeters: 5,
                                  positionSource: .gps)
        p.ingest(report: report, receivedAt: t0)
        let b = p.step(now: t0 + 1).phones.first { $0.id == "phone-b" }
        XCTAssertEqual(b?.selected?.kind, .measured)
        XCTAssertEqual(b?.selected?.uncertainty.r95 ?? 0, PositionUncertainty.r95(fromRadius68: 5), accuracy: 1e-9)
        XCTAssertNoThrow(try b?.selected?.validate())
    }

    func testPeerAssessmentArrivesOverTheMeshAndAges() throws {
        let p = pipeline(nil)
        let assessment = StubIntegrity(.rejected).assess(subjectId: "phone-c", evidence: [], now: t0)
        p.ingest(report: DeviceUpdate(id: "phone-c", epochId: UUID().uuidString, sequence: 1, role: "mobile",
                                      position: Position(x: 0, y: 0, z: 0), positionMode: "floor",
                                      positionSource: PositionSource.none), receivedAt: t0)
        let message = RelayMessage(originId: "phone-c", epochId: UUID().uuidString, sequence: 1, timestamp: t0,
                                   frameId: "hervanta-v1", hopsRemaining: 3, path: ["phone-b"],
                                   freshness: Freshness(ageAtHandoff: 2, maxAge: 5), payload: .integrity(assessment))
        p.ingest(record: message, receivedAt: t0 + 1)
        XCTAssertEqual(p.step(now: t0 + 2).phones.first { $0.id == "phone-c" }?.integrity?.status, .rejected)
        // 2 s old on arrival + 3 s here = 5 s: still current; one more second and it is stale.
        XCTAssertNotNil(p.step(now: t0 + 4).phones.first { $0.id == "phone-c" }?.integrity)
        XCTAssertNil(p.step(now: t0 + 4.5).phones.first { $0.id == "phone-c" }?.integrity)
        // The phone's own assessment goes out as a record.
        let q = pipeline(StubIntegrity(.trusted))
        q.ingest(fix: fix("phone-a", x: 1, z: 1, at: t0), receivedAt: t0)
        let out = q.step(now: t0 + 1)
        guard case .integrity(let own)? = out.records.first else { return XCTFail("no record") }
        XCTAssertEqual(own.subjectId, "phone-a")
    }

    func testLostPeerBecomesAGrowingPredictionThenRecovers() {
        let p = pipeline(nil)
        p.ingest(report: DeviceUpdate(id: "phone-b", epochId: UUID().uuidString, sequence: 1, role: "mobile",
                                      position: Position(x: 10, y: 0, z: 0), positionMode: "floor", accuracyMeters: 5,
                                      positionSource: .gps), receivedAt: t0)
        _ = p.step(now: t0 + 1)
        let lost = p.step(now: t0 + 40).phones.first { $0.id == "phone-b" }
        XCTAssertEqual(lost?.selected?.kind, .predicted)
        let later = p.step(now: t0 + 100).phones.first { $0.id == "phone-b" }
        XCTAssertGreaterThan(later?.selected?.uncertainty.r95 ?? 0, lost?.selected?.uncertainty.r95 ?? .infinity)
        XCTAssertNoThrow(try later?.prediction?.validate())
        p.ingest(report: DeviceUpdate(id: "phone-b", epochId: UUID().uuidString, sequence: 1, role: "mobile",
                                      position: Position(x: 12, y: 0, z: 0), positionMode: "floor", accuracyMeters: 5,
                                      positionSource: .gps), receivedAt: t0 + 101)
        XCTAssertEqual(p.step(now: t0 + 102).phones.first { $0.id == "phone-b" }?.selected?.kind, .measured)
    }
}

/// Every scenario in contract/scenarios/ runs headless through ScenarioWorld with today's engines.
/// Gating expectations must pass; the others are reported (contract/scenarios/run.sh prints them).
final class ScenarioTests: XCTestCase {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("contract/scenarios")

    func testScenariosRunAndGatingExpectationsHold() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.folder.path)
            .filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertFalse(names.isEmpty)
        for name in names {
            let scenario = try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: Self.folder.appendingPathComponent(name)))
            let report = ScenarioWorld(scenario: scenario).run()
            print(report.table)
            XCTAssertEqual(report.gateFailures, [], "\(scenario.id): \(report.gateFailures.map(\.id))")
        }
    }
}
