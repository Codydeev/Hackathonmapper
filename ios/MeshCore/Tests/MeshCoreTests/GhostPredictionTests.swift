import Foundation
import XCTest
import MeshCore

final class GhostPredictionTests: XCTestCase {
    private func bluetooth(_ t: Double, _ x: Double, _ z: Double, sigma: Double = 8) -> GhostObservation {
        GhostObservation(t: t, x: x, z: z, sigma: sigma, source: .bluetooth)
    }

    /// A walk east at `speed`, observed every second from 0 to `until`.
    private func walk(_ tracker: GhostTracker, id: String = "B", speed: Double = 1.3, until: Int = 60) {
        for t in 0...until { tracker.observe(id, bluetooth(Double(t), speed * Double(t), 0)) }
    }

    // MARK: Gaussian math

    func testIsotropicRegionsMatchClosedForm() {
        let g = GhostGaussian.isotropic(x: 3, z: -4, sigma: 10)
        let k95 = (-2 * log(0.05)).squareRoot()
        XCTAssertEqual(g.circleRadius(level: 0.95), 10 * k95, accuracy: 1e-3)
        XCTAssertEqual(g.mass(within: 15), 1 - exp(-225.0 / 200), accuracy: 1e-9)
        XCTAssertEqual(g.area(level: 0.9), 2 * Double.pi * 100 * -log(0.1), accuracy: 1e-6)
        XCTAssertEqual(g.level(x: 3, z: -4), 0, accuracy: 1e-12)
        XCTAssertEqual(g.level(x: 3 + 10 * k95, z: -4), 0.95, accuracy: 1e-9)
    }

    func testCircleRadiusHoldsItsMassForElongatedBeliefs() {
        let g = GhostGaussian(x: 0, z: 0, xx: 400, xz: 150, zz: 100)
        let r = g.circleRadius(level: 0.95)
        let points = g.samples(40_000, seed: 7)
        let inside = Double(points.filter { hypot($0.x, $0.z) <= r }.count) / Double(points.count)
        XCTAssertEqual(inside, 0.95, accuracy: 0.005)
        XCTAssertLessThan(r, g.ellipse(level: 0.95).semiMajor + 1e-9)
    }

    func testEllipseAxesAndOrientation() {
        let e = GhostGaussian(x: 0, z: 0, xx: 100, zz: 25).ellipse(level: 0.9)
        let k = (-2 * log(0.1)).squareRoot()
        XCTAssertEqual(e.semiMajor, 10 * k, accuracy: 1e-9)
        XCTAssertEqual(e.semiMinor, 5 * k, accuracy: 1e-9)
        XCTAssertEqual(e.angle, 0, accuracy: 1e-12)
        let diagonal = GhostGaussian(x: 0, z: 0, xx: 50, xz: 40, zz: 50).principal
        XCTAssertEqual(diagonal.angle, Double.pi / 4, accuracy: 1e-9)
        XCTAssertEqual(diagonal.major, 90, accuracy: 1e-9)
        XCTAssertEqual(diagonal.minor, 10, accuracy: 1e-9)
    }

    func testSamplesAreDeterministic() {
        let g = GhostGaussian(x: 1, z: 2, xx: 30, xz: 5, zz: 20)
        XCTAssertEqual(g.samples(16, seed: 3).map(\.x), g.samples(16, seed: 3).map(\.x))
        XCTAssertNotEqual(g.samples(16, seed: 3).map(\.x), g.samples(16, seed: 4).map(\.x))
    }

    func testScaleMixtureRegionsAreExact() {
        let core = GhostGaussian.isotropic(x: 0, z: 0, sigma: 5)
        let b = GhostBelief(core: core, scales: [.init(weight: 0.8, variance: 1), .init(weight: 0.2, variance: 9)])
        let r = b.circleRadius(level: 0.9)
        XCTAssertEqual(b.mass(within: r), 0.9, accuracy: 1e-4)
        let d2 = b.radius2(level: 0.9)
        XCTAssertEqual(b.level(x: (d2 * 25).squareRoot(), z: 0), 0.9, accuracy: 1e-6)
        XCTAssertEqual(GhostBelief(core: core).circleRadius(level: 0.95), core.circleRadius(level: 0.95), accuracy: 1e-3)
    }

    // MARK: Kalman filter

    func testMeanRevertingNoiseMatchesConstantVelocityForShortGaps() {
        // Ornstein-Uhlenbeck with tau >> dt behaves like white acceleration with q = 2 s^2 / tau.
        let o = bluetooth(0, 0, 0, sigma: 3)
        let tau = 1e5, s = 300.0
        var ou = GhostKalman(first: o, params: GhostMotionParams(kind: .meanReverting, motionNoise: s, persistence: tau,
                                                                 gpsSigmaScale: 1, radioSigmaScale: 1, initialSpeedSigma: 1))
        var cv = GhostKalman(first: o, params: GhostMotionParams(kind: .constantVelocity, motionNoise: (2 * s * s / tau).squareRoot(),
                                                                 persistence: .infinity, gpsSigmaScale: 1, radioSigmaScale: 1,
                                                                 initialSpeedSigma: 1))
        ou.advance(to: 10)
        cv.advance(to: 10)
        XCTAssertEqual(ou.positionNow.xx, cv.positionNow.xx, accuracy: cv.positionNow.xx * 1e-3)
    }

    func testFilterLearnsVelocityAndGapsGrowSubQuadratically() {
        var f = GhostKalman(first: bluetooth(0, 0, 0, sigma: 3), params: .walking)
        for t in 1...60 { f.update(bluetooth(Double(t), 1.3 * Double(t), 0, sigma: 3)) }
        XCTAssertEqual(f.velocityNow.vx, 1.3, accuracy: 0.15)
        XCTAssertEqual(f.velocityNow.vz, 0, accuracy: 0.15)
        let radii = [5.0, 10, 30, 60, 120, 300, 600].map { f.belief(at: 60 + $0).circleRadius(level: 0.95) }
        XCTAssertEqual(radii, radii.sorted(), "the area only grows while nothing is heard")
        // Constant velocity would grow 2.8x from 5 to 10 min (h^1.5); people turn and stop.
        XCTAssertLessThan(radii[6] / radii[5], 2)
        // The mean keeps going for a while, then slows down instead of running off forever.
        let far = f.belief(at: 660)
        XCTAssertGreaterThan(far.x, 78 + 30)
        XCTAssertLessThan(far.x, 78 + 1.3 * 600)
    }

    func testCovarianceStaysSymmetricAndPositive() {
        var f = GhostKalman(first: bluetooth(0, 0, 0), params: .walking)
        for t in 1...500 {
            f.update(bluetooth(Double(t), sin(Double(t) / 10) * 30, Double(t) * 0.5, sigma: 5 + Double(t % 7)))
            if t % 3 == 0 {
                f.apply(GhostMotionHint(t: Double(t) + 0.5, stationary: false,
                                        velocity: GhostVelocity(vx: 1, vz: 0.5, sigma: 0.3)))
            }
        }
        let g = f.positionNow
        XCTAssertGreaterThan(g.xx, 0)
        XCTAssertGreaterThan(g.zz, 0)
        XCTAssertGreaterThan(g.xx * g.zz - g.xz * g.xz, 0)
    }

    func testStationaryHintsHoldTheAreaSmall() {
        var still = GhostKalman(first: bluetooth(0, 0, 0, sigma: 4), params: .walking)
        var unknown = still
        for t in 1...30 {
            still.update(bluetooth(Double(t), 0, 0, sigma: 4))
            unknown.update(bluetooth(Double(t), 0, 0, sigma: 4))
        }
        for t in 31...150 { still.apply(GhostMotionHint(t: Double(t), stationary: true)) }
        XCTAssertLessThan(still.belief(at: 150).circleRadius(level: 0.95), 0.5 * unknown.belief(at: 150).circleRadius(level: 0.95))
    }

    func testDeadReckoningDriftGrowsWithDistanceWalked() {
        var f = GhostKalman(first: GhostObservation(t: 0, x: 0, z: 0, sigma: 3, source: .gps), params: .walking)
        for t in 1...20 { f.update(GhostObservation(t: Double(t), x: 0, z: 1.4 * Double(t), sigma: 3, source: .gps)) }
        let hint = { (t: Double) in GhostMotionHint(t: t, stationary: false, velocity: GhostVelocity(vx: 0, vz: 1.4, sigma: 0.05)) }
        for t in 21...80 { f.apply(hint(Double(t))) }
        XCTAssertEqual(f.deadReckoned, 1.4 * 60, accuracy: 1e-6)
        // Very confident step readings still leave a drift of 15% of the distance per axis.
        XCTAssertGreaterThan(f.positionNow.xx.squareRoot(), 0.15 * 84 - 1e-6)
        f.update(GhostObservation(t: 81, x: 0, z: 113, sigma: 3, source: .gps))
        XCTAssertEqual(f.deadReckoned, 0)
    }

    func testPredictionIsNeverSharperThanItsLastObservation() {
        let f = GhostKalman(first: GhostObservation(t: 0, x: 0, z: 0, sigma: 6, source: .gps), params: .walking)
        let b = f.belief(at: 0.5)
        XCTAssertGreaterThanOrEqual(b.core.xx, 36 - 1e-9)
        XCTAssertGreaterThanOrEqual(b.core.zz, 36 - 1e-9)
    }

    func testConstantVelocityBaseline() {
        let track = (0...20).map { GhostObservation(t: Double($0), x: Double($0), z: 2 * Double($0), sigma: 4, source: .gps) }
        let cv = GhostConstantVelocity(window: 10, startScale: 1, velocitySigma: 0.5, diffusion: 1)
        let p = cv.predict(track: track, at: 30)!
        XCTAssertEqual(p.x, 30, accuracy: 1e-9)
        XCTAssertEqual(p.z, 60, accuracy: 1e-9)
        XCTAssertEqual(p.xx, 16 + 0.25 * 100 + 10, accuracy: 1e-9)
        XCTAssertNil(cv.predict(track: [], at: 1))
    }

    // MARK: Tracker

    func testStatusGoesLiveGhostLostAndKeepsTheLastObservation() {
        let tracker = GhostTracker()
        walk(tracker)
        let live = tracker.estimate("B", at: 62)!
        XCTAssertEqual(live.status, .live)
        XCTAssertFalse(live.isPrediction)
        let ghost = tracker.estimate("B", at: 90)!
        XCTAssertEqual(ghost.status, .ghost)
        XCTAssertEqual(ghost.basis, .extrapolated)
        XCTAssertTrue(ghost.isPrediction)
        XCTAssertEqual(ghost.lastObserved, bluetooth(60, 78, 0))
        XCTAssertEqual(ghost.age, 30, accuracy: 1e-9)
        XCTAssertGreaterThan(ghost.belief!.x, 78, "the prediction moves on; the last observation stays put")
        XCTAssertTrue(ghost.summary.hasPrefix("Predicted: last seen 30 s ago (Bluetooth), 95% within "), ghost.summary)
        let later = tracker.estimate("B", at: 200)!
        XCTAssertGreaterThan(later.r95!, ghost.r95!)
        XCTAssertLessThan(later.confidence, ghost.confidence)
        let lost = tracker.estimate("B", at: 700)!
        XCTAssertEqual(lost.status, .lost)
        XCTAssertNil(lost.belief)
        XCTAssertNil(lost.r95)
        XCTAssertEqual(lost.confidence, 0)
        XCTAssertEqual(lost.lastObserved.t, 60)
        XCTAssertEqual(lost.summary, "Lost: last seen 10 min 40 s ago (Bluetooth)")
        XCTAssertNil(tracker.estimate("nobody", at: 10))
    }

    func testLateAndDuplicateObservationsAreIgnored() {
        let tracker = GhostTracker()
        walk(tracker, until: 30)
        XCTAssertNil(tracker.observe("B", bluetooth(30, 500, 500)))
        XCTAssertNil(tracker.observe("B", bluetooth(12, 500, 500)))
        XCTAssertEqual(tracker.lastObservation(of: "B"), bluetooth(30, 39, 0))
        XCTAssertNil(tracker.observe("B", GhostObservation(t: 31, x: .nan, z: 0, sigma: 8, source: .bluetooth)))
        XCTAssertEqual(tracker.lastObservation(of: "B")?.t, 30)
    }

    func testRecoveryInsideThePredictionIsFused() {
        let tracker = GhostTracker()
        walk(tracker)
        let r = tracker.observe("B", bluetooth(120, 1.3 * 120, 0))!
        XCTAssertEqual(r.action, .fused)
        XCTAssertEqual(r.gap, 60)
        XCTAssertEqual(r.insideR95, true)
        XCTAssertLessThan(r.level!, 0.9)
        XCTAssertEqual(tracker.estimate("B", at: 121)?.status, .live, "a fresh observation drops the prediction at once")
        XCTAssertEqual(tracker.recoveries.count, 1)
        XCTAssertEqual(tracker.calibration.count, 1)
    }

    func testRecoveryFarFromThePredictionRestartsTheTrack() {
        let tracker = GhostTracker()
        walk(tracker, until: 40)
        let r = tracker.observe("B", GhostObservation(t: 60, x: 400, z: -300, sigma: 5, source: .gps))!
        XCTAssertEqual(r.action, .restarted)
        XCTAssertEqual(r.insideR95, false)
        let e = tracker.estimate("B", at: 60)!
        XCTAssertEqual(e.belief!.x, 400, accuracy: 1e-6)
        XCTAssertEqual(e.belief!.z, -300, accuracy: 1e-6)
    }

    func testRecoveryAfterMaxHorizonHasNoPredictionToCheck() {
        let tracker = GhostTracker()
        walk(tracker, until: 10)
        let r = tracker.observe("B", bluetooth(900, 20, 20))!
        XCTAssertEqual(r.action, .restarted)
        XCTAssertNil(r.level)
        XCTAssertNil(r.insideR95)
        XCTAssertEqual(tracker.calibration.count, 0)
    }

    func testClockAheadOfOursNeverGivesNegativeAges() {
        let tracker = GhostTracker()
        tracker.observe("B", bluetooth(101.5, 0, 0))
        let e = tracker.estimate("B", at: 100)!
        XCTAssertEqual(e.age, 0)
        XCTAssertEqual(e.status, .live)
    }

    func testMotionHintsMakeItDeadReckoning() {
        let tracker = GhostTracker()
        for t in 0...30 { tracker.observe("A", GhostObservation(t: Double(t), x: 0, z: 1.4 * Double(t), sigma: 5, source: .gps)) }
        for t in 31...60 {
            tracker.motion("A", GhostMotionHint(t: Double(t), stationary: false,
                                                velocity: .fromHeading(speed: 1.4, heading: 0, speedSigma: 0.2, headingSigma: 0.2)))
        }
        let e = tracker.estimate("A", at: 60)!
        XCTAssertEqual(e.status, .ghost)
        XCTAssertEqual(e.basis, .deadReckoned)
        XCTAssertEqual(e.belief!.z, 1.4 * 60, accuracy: 6)
        XCTAssertTrue(e.summary.hasPrefix("Dead reckoning:"), e.summary)
        XCTAssertEqual(tracker.estimate("A", at: 70)?.basis, .extrapolated, "hints went quiet")
    }

    func testOnlineCalibrationWidensWhenRecoveriesMissTheArea() {
        var config = GhostTracker.Config()
        config.gate = 1_000   // keep fusing so every miss is counted
        let tracker = GhostTracker(config: config)
        for round in 0..<12 {
            let base = Double(round) * 100
            for t in 0...20 { tracker.observe("B", bluetooth(base + Double(t), 0, 0, sigma: 2)) }
            // Heard again 30 s later far beyond anything a walker does in 30 s.
            tracker.observe("B", bluetooth(base + 50, 150, 0, sigma: 2))
        }
        XCTAssertGreaterThan(tracker.inflation, 1)
        XCTAssertLessThan(tracker.calibration.coverage90!, 0.8)
    }

    func testWellCalibratedRecoveriesLeaveInflationAlone() {
        let tracker = GhostTracker()
        for round in 0..<12 {
            let base = Double(round) * 200
            for t in 0...30 { tracker.observe("B", bluetooth(base + Double(t), 1.3 * Double(t), 0)) }
            tracker.observe("B", bluetooth(base + 50, 1.3 * 50, 0))
        }
        XCTAssertEqual(tracker.inflation, 1)
    }

    // MARK: Contract adapter

    private let frame = GeoFrame.defaultFrameId

    private func estimate(_ id: String, t: Double, x: Double, z: Double, r95: Double = 20, kind: PositionEstimate.Kind = .estimated,
                          method: PositionEstimate.Method = .particle, source: EvidenceSource = .bluetooth,
                          age: Double = 0, simulated: Bool = false) -> PositionEstimate {
        PositionEstimate(subjectId: id, timestamp: t, frameId: frame, kind: kind, method: method,
                         position: Position(x: x, y: 0, z: z), uncertainty: PositionUncertainty(r95: r95),
                         source: source, freshness: Freshness(ageAtHandoff: age, maxAge: 30),
                         provenance: Provenance(producerId: "phone-c", algorithm: "bluetooth-estimator@1",
                                                gnssDependent: source == .gnss, simulated: simulated))
    }

    func testPredictorPublishesAValidPredictionOnlyWhileTheSubjectIsAGhost() throws {
        let ghost = GhostPredictor(producerId: "phone-a", frameId: frame)
        let t0 = 1_793_000_000.0
        for t in 0...60 { ghost.observe(estimate("phone-b", t: t0 + Double(t), x: 1.3 * Double(t), z: 0, simulated: true), receivedAt: t0 + Double(t)) }
        XCTAssertNil(ghost.predict(subjectId: "phone-b", at: t0 + 61), "live: no prediction")
        let p = try XCTUnwrap(ghost.predict(subjectId: "phone-b", at: t0 + 120))
        try p.validate()
        XCTAssertEqual(p.method, .kalman)
        XCTAssertEqual(p.source, .prediction)
        XCTAssertEqual(p.horizon, 60, accuracy: 1e-9)
        XCTAssertEqual(p.lastObservedPosition, Position(x: 78, y: 0, z: 0))
        XCTAssertGreaterThan(p.center.x, 78)
        XCTAssertEqual(p.provenance.algorithm, "kalman-ou@1")
        XCTAssertEqual(p.provenance.contributors, ["phone-a", "phone-c"])
        XCTAssertTrue(p.provenance.simulated, "simulated inputs stay flagged")
        XCTAssertFalse(p.provenance.gnssDependent)
        XCTAssertEqual(p.provenance.inputs.last?.reason, "last observation")
        XCTAssertEqual(p.cloud?.count, 64)
        let next = try XCTUnwrap(ghost.predict(subjectId: "phone-b", at: t0 + 121))
        XCTAssertGreaterThan(next.uncertainty.r95, p.uncertainty.r95)
        XCTAssertEqual(p.withoutCloud.cloud, nil)
        XCTAssertEqual(p.asPositionEstimate.kind, .predicted)
        // Heard again: the prediction is gone at once.
        ghost.observe(estimate("phone-b", t: t0 + 130, x: 160, z: 0), receivedAt: t0 + 130)
        XCTAssertNil(ghost.predict(subjectId: "phone-b", at: t0 + 130))
        XCTAssertNil(ghost.predict(subjectId: "phone-b", at: t0 + 131))
        XCTAssertNil(ghost.predict(subjectId: "phone-b", at: t0 + 2_000), "lost: no prediction")
    }

    func testPredictorNeverLearnsFromPredictionsOrOtherFrames() {
        let ghost = GhostPredictor(producerId: "phone-a", frameId: frame)
        let t0 = 1_793_000_000.0
        ghost.observe(estimate("b", t: t0, x: 0, z: 0), receivedAt: t0)
        ghost.observe(estimate("b", t: t0 + 5, x: 50, z: 0, kind: .predicted, method: .prediction, source: .prediction), receivedAt: t0 + 5)
        ghost.observe(estimate("b", t: t0 + 6, x: 60, z: 0, method: .deadReckoning, source: .inertial), receivedAt: t0 + 6)
        let other = PositionEstimate(subjectId: "b", timestamp: t0 + 7, frameId: "elsewhere-v1", kind: .estimated, method: .particle,
                                     position: Position(x: 70, y: 0, z: 0), uncertainty: PositionUncertainty(r95: 10), source: .bluetooth,
                                     freshness: Freshness(maxAge: 30), provenance: Provenance(producerId: "c", algorithm: "x@1", gnssDependent: false))
        ghost.observe(other, receivedAt: t0 + 7)
        XCTAssertEqual(ghost.tracker.observations(of: "b").count, 1)
    }

    func testRelayedEstimatesAreTimedByAgeNotByTheSendersClock() {
        let ghost = GhostPredictor(producerId: "phone-a", frameId: frame)
        // The sender's clock is an hour off; only its age at handoff counts.
        ghost.observe(estimate("b", t: 5_000, x: 0, z: 0, age: 4), receivedAt: 1_793_000_100)
        XCTAssertEqual(ghost.tracker.lastObservation(of: "b")?.t, 1_793_000_096)
        XCTAssertEqual(ghost.tracker.lastObservation(of: "b")?.sigma ?? 0, 20 / PositionUncertainty.sigmaTo95, accuracy: 1e-9)
    }

    func testGNSSInputsMarkPredictionsGNSSDependent() throws {
        let ghost = GhostPredictor(producerId: "phone-a", frameId: frame)
        let t0 = 1_793_000_000.0
        for t in 0...10 {
            ghost.observe(estimate("phone-a", t: t0 + Double(t), x: 0, z: Double(t), r95: 8, kind: .measured, method: .gnss, source: .gnss),
                          receivedAt: t0 + Double(t))
        }
        let p = try XCTUnwrap(ghost.predict(subjectId: "phone-a", at: t0 + 30))
        try p.validate()
        XCTAssertTrue(p.provenance.gnssDependent)
        XCTAssertEqual(ghost.tracker.lastObservation(of: "phone-a")?.source, .gps)
    }

    func testMotionObservationBecomesAVelocityHint() {
        let m = MotionObservation(subjectId: "a", timestamp: 100, interval: 2, frameId: frame, method: .pedometer, steps: 4,
                                  displacement: FloorVector(x: 0, z: 2.8), heading: 0, stationary: false,
                                  uncertainty: .init(displacementR95: 0.7, headingSigma: 0.2),
                                  freshness: Freshness(maxAge: 5), provenance: Provenance(producerId: "a", algorithm: "pdr@1", gnssDependent: false))
        let hint = GhostMotionHint(m)
        XCTAssertEqual(hint.t, 100)
        XCTAssertFalse(hint.stationary)
        XCTAssertEqual(hint.velocity!.vz, 1.4, accuracy: 1e-9)
        XCTAssertEqual(hint.velocity!.sigma, 1.4 * 0.2, accuracy: 1e-9)
    }
}
