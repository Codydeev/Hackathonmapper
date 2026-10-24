import Foundation
import XCTest
@testable import MeshCore

final class PositioningTests: XCTestCase {
    /// Deterministic noise so the simulated walks are repeatable.
    private struct Noise {
        var state: UInt64

        mutating func uniform() -> Double {
            state = (state &* 6364136223846793005) &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }

        mutating func gaussian() -> Double {
            (-2 * log(uniform() + 1e-12)).squareRoot() * cos(2 * Double.pi * uniform())
        }
    }

    private let flat = Vector3(x: 0, y: 0, z: -1)
    private let upright = Vector3(x: 0, y: -1, z: 0)
    private let still = Vector3(x: 0, y: 0, z: 0)

    func testLinearSystemSolvesAndDetectsSingularity() throws {
        let x = try XCTUnwrap(solveLinearSystem([[2, 1], [1, 3]], [3, 5]))
        XCTAssertEqual(x[0], 0.8, accuracy: 1e-9)
        XCTAssertEqual(x[1], 1.4, accuracy: 1e-9)
        XCTAssertNil(solveLinearSystem([[1, 2], [2, 4]], [1, 2]))
    }

    /// 10 s of walking at 1.8 steps/s, vertical swing ±0.25 g, in both common holding poses.
    func testStepsAndStrideFromSyntheticWalk() {
        for gravity in [flat, upright] {
            var pdr = PedestrianDeadReckoning()
            var steps: [Step] = []
            for k in 0...500 {
                let t = Double(k) / 50
                let swing = 0.25 * sin(2 * Double.pi * 1.8 * t)
                // Upward acceleration is opposite to gravity.
                let acceleration = Vector3(x: -gravity.x * swing, y: -gravity.y * swing, z: -gravity.z * swing)
                if let step = pdr.process(MotionSample(time: t, gravity: gravity, userAcceleration: acceleration, rotationRate: still)) {
                    steps.append(step)
                }
            }
            XCTAssertTrue((16...19).contains(steps.count), "steps: \(steps.count)")
            XCTAssertEqual(pdr.stepCount, steps.count)
            for step in steps {
                XCTAssertTrue((0.5...0.8).contains(step.length), "stride: \(step.length)")
                XCTAssertEqual(step.heading, 0, accuracy: 1e-9)
            }
        }
    }

    func testHandJitterIsNotAStep() {
        var pdr = PedestrianDeadReckoning()
        for k in 0...500 {
            let t = Double(k) / 50
            let jitter = Vector3(x: 0, y: 0, z: -0.05 * sin(2 * Double.pi * 4 * t))
            XCTAssertNil(pdr.process(MotionSample(time: t, gravity: flat, userAcceleration: jitter, rotationRate: still)))
        }
    }

    /// A clockwise (right) turn seen from above increases the heading toward +x, in either pose.
    func testHeadingIntegratesGyroAboutGravity() {
        let rightTurns = [
            (flat, Vector3(x: 0, y: 0, z: -Double.pi / 2)),
            (upright, Vector3(x: 0, y: -Double.pi / 2, z: 0)),
        ]
        for (gravity, rate) in rightTurns {
            var pdr = PedestrianDeadReckoning()
            for k in 0...50 {
                _ = pdr.process(MotionSample(time: Double(k) / 50, gravity: gravity, userAcceleration: still, rotationRate: rate))
            }
            XCTAssertEqual(pdr.heading, Double.pi / 2, accuracy: 0.02)
        }
        let step = Step(time: 0, length: 1, heading: Double.pi / 2)
        XCTAssertEqual(step.dx, 1, accuracy: 1e-9)
        XCTAssertEqual(step.dz, 0, accuracy: 1e-9)
    }

    func testPathLossModelRoundTrip() {
        let model = PathLossModel.default
        XCTAssertEqual(model.predictedRSSI(at: 1), model.referenceRSSI, accuracy: 1e-9)
        XCTAssertEqual(model.distance(for: model.predictedRSSI(at: 7)), 7, accuracy: 1e-9)
        XCTAssertEqual(model.predictedRSSI(at: 0.1), model.predictedRSSI(at: PathLossModel.minDistance))
    }

    /// Anchor-to-anchor links with known distances recover the room's model and which radios read hot.
    func testCalibrationRecoversModelAndDeviceOffsets() throws {
        let anchors: [String: (Double, Double)] = ["a": (0, 0), "b": (2, 0), "c": (10, 0), "d": (0, 6), "e": (10, 8)]
        let offsets: [String: Double] = ["a": 4, "b": -2, "c": 0, "d": -2, "e": 0]
        var links: [AnchorLinkObservation] = []
        for (observer, p) in anchors {
            for (target, q) in anchors where observer != target {
                let distance = hypot(p.0 - q.0, p.1 - q.1)
                let rssi = -62 - 25 * log10(distance) + (offsets[observer]! + offsets[target]!) / 2
                links.append(AnchorLinkObservation(observer: observer, target: target, distance: distance, rssi: rssi))
            }
        }
        let fit = PathLossCalibration.fit(links, prior: PathLossModel(referenceRSSI: -59, exponent: 2.2, sigmaDB: 2),
                                          referenceSigmaDB: 20, exponentSigma: 2)
        XCTAssertEqual(fit.linkCount, 20)
        XCTAssertEqual(fit.model.referenceRSSI, -62, accuracy: 1)
        XCTAssertEqual(fit.model.exponent, 2.5, accuracy: 0.1)
        XCTAssertEqual(fit.deviceOffsets["a"]! - fit.deviceOffsets["b"]!, 6, accuracy: 1.2)
        XCTAssertEqual(fit.linkOffset(of: "unknown"), 0)

        XCTAssertEqual(PathLossCalibration.fit([]), PathLossCalibration.uncalibrated)
    }

    func testRangeSolverFindsPositionFromFourAnchors() throws {
        let model = PathLossModel.default
        let inputs = [(0.0, 0.0), (10, 0), (10, 8), (0, 8)].map { anchor in
            RangeInput(anchorX: anchor.0, anchorZ: anchor.1, verticalOffset: 0,
                       rssi: model.predictedRSSI(at: hypot(3 - anchor.0, 5 - anchor.1)), sigmaDB: 6)
        }
        let fix = try XCTUnwrap(RangeSolver.solve(inputs, model: model))
        XCTAssertEqual(fix.x, 3, accuracy: 0.05)
        XCTAssertEqual(fix.z, 5, accuracy: 0.05)
        XCTAssertEqual(fix.anchorCount, 4)
        XCTAssertLessThan(fix.accuracy, 10)
        XCTAssertNil(RangeSolver.solve(Array(inputs.prefix(2)), model: model))
    }

    /// Standing still, a reading claiming the anchor is 1 m away instead of 5 m is impossible.
    func testFilterGateRejectsRangeTheStepsCannotExplain() {
        var filter = PositionFilter(x: 0, z: 0, positionSigma: 0.3, offsetSigmaDB: 1)
        let model = PathLossModel.default
        let result = filter.update(rssi: model.predictedRSSI(at: 1), sigmaDB: 3, anchorX: 5, anchorZ: 0,
                                   verticalOffset: 0, anchorSigma: 0.1, model: model)
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(filter.x, 0)
        XCTAssertEqual(filter.z, 0)
    }

    func testFilterStepMovesAlongFrameHeadingAndGrowsUncertainty() {
        var filter = PositionFilter(x: 1, z: 1, positionSigma: 0.1)
        let before = filter.accuracy
        filter.predict(length: 2, heading: Double.pi / 2, alongSigma: 0.2, crossSigma: 0.1, headingDrift: 0)
        XCTAssertEqual(filter.x, 3, accuracy: 1e-9)
        XCTAssertEqual(filter.z, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(filter.accuracy, before)
        filter.observePosition(x: 3, z: 1, sigma: 0.05)
        XCTAssertLessThan(filter.accuracy, before)
    }

    func testMotionAwareRSSIAveragesWhileStillAndDropsImpossibleJumps() throws {
        let model = PathLossModel.default
        var rssi = MotionAwareRSSI()
        for k in 0..<16 {
            rssi.record(k.isMultiple(of: 2) ? -55 : -65, at: Double(k), moving: false, distance: 4, model: model)
        }
        var estimate = try XCTUnwrap(rssi.estimate(at: 15, speed: 0, distance: 4, model: model))
        XCTAssertEqual(estimate.rssi, -60, accuracy: 1e-9)
        XCTAssertLessThan(estimate.sigmaDB, 5)
        XCTAssertEqual(rssi.stillSampleCount, 16)

        // A 25 dB drop without moving is a body or door in the way, not a new range...
        XCTAssertFalse(rssi.record(-85, at: 16, moving: false, distance: 4, model: model))
        XCTAssertFalse(rssi.record(-85, at: 17, moving: false, distance: 4, model: model))
        XCTAssertEqual(rssi.droppedSamples, 2)
        // ...unless it persists: then the new level is accepted.
        XCTAssertTrue(rssi.record(-85, at: 18, moving: false, distance: 4, model: model))
        estimate = try XCTUnwrap(rssi.estimate(at: 18, speed: 0, distance: 4, model: model))
        XCTAssertEqual(estimate.rssi, -85, accuracy: 1e-9)

        // After walking 10 m the same jump is plausible.
        var walking = MotionAwareRSSI()
        walking.record(-60, at: 0, moving: true, distance: 4, model: model)
        XCTAssertTrue(walking.record(-80, at: 1, moving: true, walked: 10, distance: 4, model: model))
        XCTAssertNil(walking.estimate(at: 10, speed: 0, distance: 4, model: model), "stale sample")
    }

    /// About ten minutes of walking with a radio that reads 4 dB hot, a stride 8% long, a heading
    /// 4° off that drifts a further 0.1°/s, noisy RSSI with occasional 15 dB dropouts, and
    /// anchors whose radios differ. Dead reckoning alone drifts; the fused estimate stays bounded.
    func testFusionBoundsDeadReckoningDriftOnLongWalk() throws {
        var noise = Noise(state: 7919)
        let truth = PathLossModel(referenceRSSI: -60, exponent: 2.3, sigmaDB: 4)
        let anchors: [String: (Double, Double)] = ["n1": (0, 0), "n2": (12, 0), "n3": (12, 10), "n4": (0, 10)]
        let ids = anchors.keys.sorted()
        var anchorOffset: [String: Double] = [:]
        var shadowing: [String: Double] = [:]
        for id in ids {
            anchorOffset[id] = 3 * noise.gaussian()
            shadowing[id] = 2 * noise.gaussian()
        }
        let phoneOffset = 8.0

        var engine = FusionEngine()
        var links: [AnchorLinkObservation] = []
        for observer in ids {
            for target in ids where observer != target {
                let distance = hypot(anchors[observer]!.0 - anchors[target]!.0, anchors[observer]!.1 - anchors[target]!.1)
                let rssi = truth.predictedRSSI(at: distance) + (anchorOffset[observer]! + anchorOffset[target]!) / 2
                    + 3 * noise.gaussian()
                links.append(AnchorLinkObservation(observer: observer, target: target, distance: distance, rssi: rssi))
            }
        }
        engine.setCalibration(PathLossCalibration.fit(links))

        let lap: [(Double, Double)] = [(2, 2), (10, 2), (10, 8), (2, 8), (2, 4), (8, 4), (8, 6), (4, 6), (4, 9), (11, 9), (11, 2)]
        let route = Array(repeating: lap, count: 8).flatMap { $0 }
        var x = 2.0
        var z = 2.0
        var deadX = 2.0
        var deadZ = 2.0
        var time = 0.0
        var nextUpdate = 1.0
        var fusedErrors: [Double] = []
        var deadErrors: [Double] = []
        engine.start(x: 2, z: 2, heading: 0)

        func advance(to end: Double) {
            while nextUpdate <= end {
                let sightings = ids.map { id -> AnchorSighting in
                    let anchor = anchors[id]!
                    var rssi = truth.predictedRSSI(at: hypot(x - anchor.0, z - anchor.1))
                        + (phoneOffset + anchorOffset[id]!) / 2 + shadowing[id]! + 4 * noise.gaussian()
                    if noise.uniform() < 0.05 { rssi -= 15 }
                    return AnchorSighting(anchorId: id, position: Position(x: anchor.0, y: 0, z: anchor.1),
                                          positionAccuracy: nil, rssi: rssi.rounded(), sampleTime: nextUpdate)
                }
                engine.update(with: sightings, at: nextUpdate)
                if let filter = engine.filter {
                    fusedErrors.append(hypot(filter.x - x, filter.z - z))
                    deadErrors.append(hypot(deadX - x, deadZ - z))
                }
                nextUpdate += 1
            }
        }

        for index in 1..<route.count {
            let (fromX, fromZ) = route[index - 1]
            let (toX, toZ) = route[index]
            let length = hypot(toX - fromX, toZ - fromZ)
            guard length > 0 else { continue }
            let count = max(1, Int((length / 0.7).rounded()))
            let heading = atan2(toX - fromX, toZ - fromZ)
            for _ in 0..<count {
                time += 0.55
                x += (toX - fromX) / Double(count)
                z += (toZ - fromZ) / Double(count)
                let measuredHeading = heading + 4 * Double.pi / 180 + 0.1 * Double.pi / 180 * time + 0.03 * noise.gaussian()
                let measuredLength = length / Double(count) * 1.08
                let step = Step(time: time, length: measuredLength, heading: measuredHeading)
                engine.apply(step)
                deadX += step.dx
                deadZ += step.dz
                advance(to: time)
            }
            time += 8
            advance(to: time)
        }

        let fusedMean = fusedErrors.reduce(0, +) / Double(fusedErrors.count)
        let deadMean = deadErrors.reduce(0, +) / Double(deadErrors.count)
        let filter = try XCTUnwrap(engine.filter)
        XCTAssertLessThan(fusedMean, 3, "fused mean error \(fusedMean) m")
        XCTAssertLessThan(fusedMean, deadMean - 1, "fused \(fusedMean) m vs dead reckoning \(deadMean) m")
        XCTAssertLessThan(fusedErrors.last!, 4)
        XCTAssertGreaterThan(deadErrors.last!, fusedErrors.last!)
        XCTAssertEqual(filter.receiverOffsetDB, phoneOffset / 2, accuracy: 3)
        XCTAssertGreaterThan(engine.acceptedUpdates, 100)
    }
}
