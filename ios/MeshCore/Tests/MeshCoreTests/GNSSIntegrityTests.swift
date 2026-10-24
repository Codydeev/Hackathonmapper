import Foundation
import XCTest
@testable import MeshCore

/// One check at a time on hand-made inputs, then the contract monitor end to end.
final class GNSSIntegrityTests: XCTestCase {
    private func fix(_ time: Double, _ x: Double, _ z: Double, accuracy: Double = 5, speed: Double? = nil,
                     course: Double? = nil, speedAccuracy: Double? = nil) -> GNSSFix {
        GNSSFix(time: time, position: FloorPoint(x: x, z: z), accuracy: accuracy, speed: speed, course: course,
                speedAccuracy: speedAccuracy)
    }

    private func still(_ engine: GNSSIntegrityEngine, at time: Double) {
        engine.addMotion(InertialDisplacement(start: time - 1, end: time, dx: 0, dz: 0, sigma: 0.02, stationary: true))
    }

    /// A phone lying still with motion data and steady fixes, for `seconds` seconds.
    private func trustedStillPhone(seconds: Int = 20) -> GNSSIntegrityEngine {
        let engine = GNSSIntegrityEngine()
        for t in 1...seconds {
            still(engine, at: Double(t))
            engine.assess(fix(Double(t), t.isMultiple(of: 2) ? 1 : -1, 0))
        }
        return engine
    }

    func testGNSSAloneIsNeverTrusted() {
        let engine = GNSSIntegrityEngine()
        var last: GNSSIntegrityAssessment?
        for t in 1...60 {
            last = engine.assess(fix(Double(t), 1.4 * Double(t), 0, speed: 1.4, course: 90))
            XCTAssertNotEqual(last?.status, .trusted)
        }
        XCTAssertEqual(last?.status, .insufficientEvidence)
        XCTAssertEqual(last?.reasons, [.insufficientEvidence])
        XCTAssertNil(last?.uncertainty.minimumDetectableOffset, "nothing independent bounds the error")
        XCTAssertEqual(last?.uncertainty.trustLower, 0)
        XCTAssertTrue(last?.usableAsPosition ?? false)
    }

    func testInertialAgreementMakesTrusted() {
        let engine = trustedStillPhone()
        let last = engine.latest!
        XCTAssertEqual(last.status, .trusted)
        XCTAssertEqual(last.summary, "GPS agrees with steps and compass")
        XCTAssertTrue(last.evidence.contains { $0.check == .inertial && $0.independent })
        XCTAssertLessThanOrEqual(last.uncertainty.minimumDetectableOffset ?? .infinity, 50)
        XCTAssertNotNil(last.uncertainty.minimumDetectableDriftRate)
    }

    func testJumpIsRejectedAtOnceAndNotCalledAnAttack() {
        let engine = trustedStillPhone()
        still(engine, at: 21)
        let jumped = engine.assess(fix(21, 400, 0))
        XCTAssertEqual(jumped.status, .rejected)
        XCTAssertTrue(jumped.reasons.contains(.impossibleSpeed))
        XCTAssertTrue(jumped.reasons.contains(.positionJump))
        XCTAssertTrue(jumped.reasons.contains(.inertialDisagreement))
        XCTAssertFalse(jumped.spoofingConfirmed)
        XCTAssertTrue(jumped.summary.hasSuffix("not proof of an attack"), jumped.summary)
        XCTAssertTrue(jumped.possibleCauses.contains(.multipath))
        XCTAssertTrue(jumped.possibleCauses.contains(.receiverFault))
        XCTAssertNil(jumped.uncertainty.recommendedSigma)
        XCTAssertFalse(jumped.usableAsPosition)
        // The fix stays out of the reference, so the next one at the same place is still rejected.
        still(engine, at: 22)
        XCTAssertTrue(engine.assess(fix(22, 400, 0)).isAnomaly)
    }

    func testFixesThatStopGoStaleThenUnavailable() {
        let engine = trustedStillPhone()
        still(engine, at: 21)
        XCTAssertEqual(engine.assess(at: 21).status, .trusted)
        let aging = engine.assess(at: 26)
        XCTAssertEqual(aging.status, .degraded)
        XCTAssertEqual(aging.reasons, [.staleFix])
        XCTAssertGreaterThan(aging.uncertainty.recommendedSigma!, 2 * 5 / 1.515, "uncertainty grows with age")
        let gone = engine.assess(at: 51)
        XCTAssertEqual(gone.status, .unavailable)
        XCTAssertEqual(gone.reasons, [.staleFix])
    }

    func testLateFixIsStale() {
        let engine = trustedStillPhone()
        still(engine, at: 30)
        let late = engine.assess(fix(20.5, 0, 0), at: 30)
        XCTAssertEqual(late.status, .degraded)
        XCTAssertTrue(late.reasons.contains(.staleFix))
    }

    func testPoorAccuracyDegradesAndHopelessAccuracyIsUnavailable() {
        let engine = trustedStillPhone()
        still(engine, at: 21)
        let coarse = engine.assess(fix(21, 0, 0, accuracy: 40))
        XCTAssertEqual(coarse.status, .degraded)
        XCTAssertEqual(coarse.reasons, [.degradedAccuracy])
        XCTAssertEqual(coarse.summary, "GPS accuracy 40 m")
        still(engine, at: 22)
        let hopeless = engine.assess(fix(22, 0, 0, accuracy: 150))
        XCTAssertEqual(hopeless.status, .unavailable)
        XCTAssertEqual(hopeless.reasons, [.degradedAccuracy])
    }

    func testInvalidFixIsIgnored() {
        let engine = GNSSIntegrityEngine()
        let first = engine.assess(fix(1, 0, 0, accuracy: -1))
        XCTAssertEqual(first.status, .unavailable)
        XCTAssertEqual(first.reasons, [.invalidFix])
    }

    func testTimestampGoingBackIsRejected() {
        let engine = trustedStillPhone()
        still(engine, at: 21)
        let replayed = engine.assess(fix(15, 0, 0), at: 21)
        XCTAssertEqual(replayed.status, .rejected)
        XCTAssertTrue(replayed.reasons.contains(.timestampInconsistent))
    }

    func testImpossibleAccelerationFromReportedVelocity() {
        let engine = GNSSIntegrityEngine()
        for t in 1...10 {
            engine.assess(fix(Double(t), 0, 1.4 * Double(t), speed: 1.4, course: 0, speedAccuracy: 0.3))
        }
        // 1.4 to 6.5 m/s in half a second: fast, but not too fast; the change is what is impossible.
        let burst = engine.assess(fix(10.5, 0, 14.7, speed: 6.5, course: 0, speedAccuracy: 0.3))
        XCTAssertTrue(burst.reasons.contains(.impossibleAcceleration), "\(burst.reasons)")
        XCTAssertFalse(burst.reasons.contains(.impossibleSpeed))
        XCTAssertTrue(burst.isAnomaly)
    }

    func testStillPhoneWhoseGPSWandersOff() {
        let engine = trustedStillPhone()
        var flagged: GNSSIntegrityAssessment?
        for t in 21...120 where flagged == nil {
            still(engine, at: Double(t))
            let assessment = engine.assess(fix(Double(t), 0.5 * Double(t - 20), 0))
            if assessment.isAnomaly { flagged = assessment }
        }
        let caught = try! XCTUnwrap(flagged)
        XCTAssertTrue(caught.reasons.contains(.inertialDisagreement) || caught.reasons.contains(.slowDrift)
                      || caught.reasons.contains(.positionJump), "\(caught.reasons)")
        XCTAssertLessThan(caught.fix!.position.x, 30, "0.5 m/s drift on a still phone is caught before 30 m")
    }

    func testPeersPlacedByGPSCanObjectButNeverVerify() {
        let engine = GNSSIntegrityEngine()
        func hear(_ time: Double) {
            for (id, x) in [("a", 10.0), ("b", -8.0), ("c", 0.0)] {
                engine.addPeer(PeerProximity(time: time, peerId: id, peerPosition: FloorPoint(x: x, z: 5), peerSigma: 3,
                                             origin: .gnssDerived, maxRange: 30))
            }
        }
        for t in 1...30 {
            hear(Double(t))
            let assessment = engine.assess(fix(Double(t), 0, 0))
            XCTAssertNotEqual(assessment.status, .trusted)
        }
        let agreeing = engine.latest!
        XCTAssertEqual(agreeing.status, .insufficientEvidence)
        XCTAssertTrue(agreeing.reasons.contains(.peerEvidenceNotIndependent))
        XCTAssertEqual(agreeing.summary, "GPS unchecked: peers agree, but they use GPS too")

        let fresh = GNSSIntegrityEngine()
        for (id, x) in [("a", 10.0), ("b", -8.0), ("c", 0.0)] {
            fresh.addPeer(PeerProximity(time: 1, peerId: id, peerPosition: FloorPoint(x: x, z: 5), peerSigma: 3,
                                        origin: .gnssDerived, maxRange: 30))
        }
        let far = fresh.assess(fix(1, 300, 0))
        XCTAssertTrue(far.isAnomaly)
        XCTAssertEqual(far.reasons.first, .peerDisagreement)
        XCTAssertTrue(far.possibleCauses.contains(.peerOrAnchorError))
    }

    func testOnePeerOutOfThreeCannotCondemnAFix() {
        let engine = GNSSIntegrityEngine()
        engine.addPeer(PeerProximity(time: 1, peerId: "a", peerPosition: FloorPoint(x: 5, z: 0), peerSigma: 3, origin: .gnssDerived, maxRange: 30))
        engine.addPeer(PeerProximity(time: 1, peerId: "b", peerPosition: FloorPoint(x: -5, z: 0), peerSigma: 3, origin: .gnssDerived, maxRange: 30))
        engine.addPeer(PeerProximity(time: 1, peerId: "c", peerPosition: FloorPoint(x: 900, z: 0), peerSigma: 3, origin: .gnssDerived, maxRange: 30))
        XCTAssertFalse(engine.assess(fix(1, 0, 0)).isAnomaly)
    }

    func testSurveyedBeaconIsIndependentEvidence() {
        let engine = GNSSIntegrityEngine()
        for t in 1...10 {
            engine.addPeer(PeerProximity(time: Double(t), peerId: "beacon", peerPosition: FloorPoint(x: 8, z: 0),
                                         peerSigma: 1, origin: .surveyed, maxRange: 25))
            engine.assess(fix(Double(t), 0, 0))
        }
        XCTAssertEqual(engine.latest?.status, .trusted)
        XCTAssertEqual(engine.latest?.summary, "GPS agrees with a surveyed beacon")
    }

    func testContinuityLostAfterLongRejectionUntilIndependentPositionAgrees() {
        let engine = GNSSIntegrityEngine()
        for t in 1...10 { engine.assess(fix(Double(t), 0, 0)) }
        XCTAssertEqual(engine.assess(fix(11, 400, 0)).status, .rejected)
        var back: GNSSIntegrityAssessment?
        for t in 12...600 where back == nil {
            let assessment = engine.assess(fix(Double(t), 400, 0))
            if !assessment.isAnomaly { back = assessment }
        }
        // Without motion the reference loosens until 400 m is reachable; GNSS is taken back, but
        // never as trusted.
        let returned = try! XCTUnwrap(back)
        XCTAssertEqual(returned.status, .insufficientEvidence)
        XCTAssertTrue(returned.reasons.contains(.continuityLost), "\(returned.reasons)")
        XCTAssertEqual(returned.summary, "GPS consistent again after an anomaly; not re-verified yet")

        let time = returned.time + 1
        engine.addPositionEvidence(PositionEvidence(time: time, position: FloorPoint(x: 402, z: 1), sigma: 2, origin: .surveyed))
        XCTAssertEqual(engine.assess(fix(time, 400, 0)).status, .trusted)
    }

    func testRecoveryIsNeverInstant() {
        let engine = trustedStillPhone()
        for t in 21...40 {
            still(engine, at: Double(t))
            engine.assess(fix(Double(t), 60, 0))
        }
        XCTAssertTrue(engine.latest!.isAnomaly)
        var statuses: [GNSSIntegrityStatus] = []
        var sawRecovering = false
        for t in 41...70 {
            still(engine, at: Double(t))
            let assessment = engine.assess(fix(Double(t), t.isMultiple(of: 2) ? 1 : -1, 0))
            statuses.append(assessment.status)
            sawRecovering = sawRecovering || assessment.reasons.contains(.recovering)
        }
        XCTAssertTrue(sawRecovering)
        XCTAssertFalse(statuses.prefix(5).contains(.trusted), "\(statuses)")
        XCTAssertEqual(statuses.last, .trusted)
    }

    func testIndependentPositionEstimateObjects() {
        let engine = GNSSIntegrityEngine()
        engine.addPositionEvidence(PositionEvidence(time: 1, position: FloorPoint(x: 120, z: 0), sigma: 5, origin: .surveyed))
        let assessment = engine.assess(fix(1, 0, 0))
        XCTAssertTrue(assessment.isAnomaly)
        XCTAssertTrue(assessment.reasons.contains(.independentEvidenceDisagreement))
    }

    func testDistanceOutsideHeadingAndStepBias() {
        let angle = 10 * Double.pi / 180
        // Inside the fan: 100 m north with a 5° heading error and 5 % scale error.
        let inside = GNSSIntegrityEngine.distanceOutsideBias(gx: 105 * sin(0.087), gz: 105 * cos(0.087), ix: 0, iz: 100,
                                                             maxAngle: angle, maxScale: 0.08)
        XCTAssertEqual(inside, 0, accuracy: 1e-9)
        // Straight ahead but 30 % too far: 22 m beyond the 8 % scale allowance.
        XCTAssertEqual(GNSSIntegrityEngine.distanceOutsideBias(gx: 0, gz: 130, ix: 0, iz: 100, maxAngle: angle, maxScale: 0.08),
                       22, accuracy: 1e-9)
        // 50 m sideways after 100 m: 26.57° off, so 16.57° beyond the 10° edge: 111.8 m · sin 16.57°.
        let sideways = GNSSIntegrityEngine.distanceOutsideBias(gx: 50, gz: 100, ix: 0, iz: 100, maxAngle: angle, maxScale: 0.08)
        XCTAssertEqual(sideways, hypot(50, 100) * sin(atan2(50, 100) - angle), accuracy: 1e-9)
        // No inertial motion: the whole GNSS displacement counts.
        XCTAssertEqual(GNSSIntegrityEngine.distanceOutsideBias(gx: 3, gz: 4, ix: 0, iz: 0, maxAngle: angle, maxScale: 0.08), 5)
    }

    func testNoWordingClaimsSpoofing() {
        for status in GNSSIntegrityStatus.allCases { XCTAssertFalse(status.rawValue.lowercased().contains("spoof")) }
        for reason in GNSSReasonCode.allCases { XCTAssertFalse(reason.rawValue.lowercased().contains("spoof")) }
        for scenario in GNSSScenario.library {
            let world = GNSSSimulatedWorld(scenario: scenario, seed: 1)
            for assessment in GNSSFaultHarness.run(world, config: .full).assessments {
                XCTAssertFalse(assessment.summary.lowercased().contains("spoof"), assessment.summary)
                XCTAssertLessThanOrEqual(assessment.summary.utf16.count, 160)
                XCTAssertFalse(assessment.spoofingConfirmed)
                if assessment.possibleCauses.contains(.spoofing) {
                    XCTAssertGreaterThan(assessment.possibleCauses.count, 1, "spoofing is never the only candidate")
                }
                if assessment.isAnomaly { XCTAssertFalse(assessment.reasons.isEmpty) }
            }
        }
    }

    // MARK: Contract monitor

    private let epoch = 1_793_000_000.0

    /// Feeds a simulated world through the monitor in the pipeline's order.
    private func replay(_ world: GNSSSimulatedWorld, monitor: GNSSIntegrityMonitor,
                        beacons: Bool = true) -> [IntegrityAssessment] {
        (1...world.scenario.duration).map { second in
            let inputs = world.contractInputs(second: second, subjectId: monitor.subjectId, epoch: epoch)
            if let motion = inputs.motion { monitor.ingest(motion: motion) }
            for peer in inputs.peers where beacons || peer.position.provenance.gnssDependent {
                monitor.ingest(peer: peer.observation, peerPosition: peer.position, peerStatus: .trusted)
            }
            let now = epoch + Double(second)
            return inputs.fix.map { monitor.assess(fix: $0, now: now) } ?? monitor.assess(now: now)
        }
    }

    func testMonitorRecordsAreValidAndMatchTheEngine() throws {
        let names = ["clean walk", "S2 jump 400 m", "S3 drift 1 m/s", "S4 drift removed", "jamming 60 s",
                     "fixes 15 s late", "dropout 60 s", "common-mode drift 0.5 m/s, anchor at 600 s", "clean walk, urban multipath"]
        for name in names {
            let scenario = try XCTUnwrap(GNSSScenario.named(name))
            let world = GNSSSimulatedWorld(scenario: scenario, seed: 2)
            let native = GNSSFaultHarness.run(world, config: .full).assessments
            let records = replay(world, monitor: GNSSIntegrityMonitor(subjectId: "phone-c"))
            var matches = 0
            for (index, record) in records.enumerated() {
                XCTAssertNoThrow(try record.validate(), "\(name) t=\(index + 1): \(record)")
                XCTAssertTrue(record.provenance.simulated)
                XCTAssertEqual(record.provenance.algorithm, "gnss-integrity@1")
                if record.status == .unavailable { XCTAssertNil(record.evaluatedFix) }
                if let fix = world.fixes[index + 1], record.status != .unavailable {
                    XCTAssertEqual(record.evaluatedFix?.position?.x ?? .nan, fix.position.x, accuracy: 1e-9)
                }
                if record.status.rawValue == native[index].status.rawValue { matches += 1 }
            }
            // The contract carries no speed accuracy, so the acceleration check is a little looser.
            XCTAssertGreaterThanOrEqual(Double(matches) / Double(records.count), 0.99, name)
        }
    }

    func testMonitorUsesIndependenceFromProvenance() {
        func estimate(_ time: Double, gnssDependent: Bool) -> PositionEstimate {
            PositionEstimate(subjectId: "phone-b", timestamp: time, frameId: "hervanta-v1", kind: .estimated,
                             method: .particle, position: Position(x: 2, y: 0, z: 1),
                             uncertainty: PositionUncertainty(r95: 8), source: .bluetooth, freshness: Freshness(maxAge: 5),
                             provenance: Provenance(producerId: "phone-a", algorithm: "bluetooth-estimator@1",
                                                    contributors: ["phone-a", "phone-b"], gnssDependent: gnssDependent))
        }
        func raw(_ time: Double) -> PositionEstimate {
            PositionEstimate(subjectId: "phone-b", timestamp: time, frameId: "hervanta-v1", kind: .measured, method: .gnss,
                             position: Position(x: 0, y: 0, z: 0), uncertainty: PositionUncertainty(r95: 8),
                             source: .gnss, freshness: Freshness(maxAge: 30),
                             provenance: Provenance(producerId: "phone-b", algorithm: "corelocation@1", gnssDependent: true))
        }
        for gnssDependent in [true, false] {
            let monitor = GNSSIntegrityMonitor(subjectId: "phone-b")
            var record: IntegrityAssessment?
            for t in 1...10 {
                let now = epoch + Double(t)
                monitor.ingest(fix: raw(now))
                record = monitor.assess(subjectId: "phone-b", evidence: [estimate(now, gnssDependent: gnssDependent)], now: now)
            }
            XCTAssertNoThrow(try record!.validate())
            XCTAssertEqual(record!.status, gnssDependent ? .insufficientEvidence : .trusted)
            XCTAssertEqual(record!.mayAnchorOthers, !gnssDependent)
            XCTAssertEqual(record!.evidence.first { $0.check == "positionEvidence" }?.independent, !gnssDependent)
            if gnssDependent { XCTAssertTrue(record!.reasons.contains(.peerEvidenceNotIndependent)) }
            XCTAssertNotNil(monitor.displayR95)
        }
    }

    /// The pipeline's protocol on top of the monitor. The conformance itself belongs in the
    /// integration lead's files, so the test wraps instead of declaring it.
    private final class MonitorEngine: GhostIntegrityEngine {
        let monitor: GNSSIntegrityMonitor
        init(_ subjectId: String, _ frameId: String) { monitor = GNSSIntegrityMonitor(subjectId: subjectId, frameId: frameId) }
        func ingest(fix: PositionEstimate) { monitor.ingest(fix: fix) }
        func ingest(motion: MotionObservation) { monitor.ingest(motion: motion) }
        func assess(subjectId: String, evidence: [PositionEstimate], now: Double) -> IntegrityAssessment {
            monitor.assess(subjectId: subjectId, evidence: evidence, now: now)
        }
    }

    /// contract/scenarios through the real GhostCorePipeline with this engine as its integrity engine.
    func testContractScenariosWithThisEngine() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: ScenarioTests.folder.path)
            .filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertFalse(names.isEmpty)
        for name in names {
            let data = try Data(contentsOf: ScenarioTests.folder.appendingPathComponent(name))
            let scenario = try JSONDecoder().decode(Scenario.self, from: data)
            let report = ScenarioWorld(scenario: scenario, integrity: { MonitorEngine($0, $1) }).run()
            print(report.table)
            XCTAssertEqual(report.gateFailures, [], "\(scenario.id): \(report.gateFailures.map(\.id))")
            XCTAssertFalse(report.results.contains { $0.outcome == .pending && $0.detail.contains("integrity") })
        }
    }

    func testMonitorWithoutFixIsUnavailable() throws {
        let monitor = GNSSIntegrityMonitor(subjectId: "phone-b")
        let record = monitor.assess(now: epoch)
        XCTAssertNoThrow(try record.validate())
        XCTAssertEqual(record.status, .unavailable)
        XCTAssertEqual(record.reasons, [.noFix])
        XCTAssertNil(record.evaluatedFix)
        XCTAssertNil(monitor.displayR95)
    }
}
