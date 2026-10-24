import Foundation
import XCTest
import MeshCore

/// The map's numbers: measured UWB distances hold between the drawn points, an unknown direction
/// is reported as a ring instead of a dot, and Bluetooth-only phones are placed as before.
final class MeshLocatorTests: XCTestCase {
    /// mulberry32, as in BluetoothEstimatorTests, for repeatable noise.
    private struct Noise {
        var state: UInt32
        mutating func next() -> Double {
            state = state &+ 0x6d2b_79f5
            var t = state
            t = (t ^ (t >> 15)) &* (t | 1)
            t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }
        mutating func gauss() -> Double {
            (-2 * log(max(next(), 1e-12))).squareRoot() * cos(2 * Double.pi * next())
        }
    }

    private func distance(_ p: FloorPoint, _ q: FloorPoint) -> Double { hypot(p.x - q.x, p.z - q.z) }

    private func locator(seed: UInt32) -> MeshLocator {
        var options = BluetoothEstimator.Options()
        options.seed = seed
        return MeshLocator(options: options)
    }

    func testOneGPSNeighbourLeavesARingOfTheMeasuredRadius() throws {
        for seed in UInt32(1)...4 {
            var noise = Noise(state: seed)
            let locator = locator(seed: seed + 1)
            var fixes: [String: PhoneFix] = [:]
            var measured = 0.0
            for _ in 0..<20 {
                measured = 4 + 0.05 * noise.gauss()
                let gps = EstimatorAnchor(id: "g", x: 3 * noise.gauss(), z: 3 * noise.gauss(), accuracy: 10, source: .gps)
                fixes = locator.update(BluetoothEstimator.Input(
                    anchors: [gps], lost: ["x"],
                    measurements: [LinkMeasurement(a: "g", b: "x", uwbDistance: measured)]))
            }
            let x = try XCTUnwrap(fixes["x"])
            let g = try XCTUnwrap(fixes["g"])
            XCTAssertEqual(distance(x.point, g.point), 4, accuracy: 0.2)
            XCTAssertTrue(x.ambiguous)
            let ring = try XCTUnwrap(x.ring)
            XCTAssertEqual(ring.around, "g")
            XCTAssertEqual(ring.radius, measured, accuracy: 1e-9)
            XCTAssertEqual(distance(ring.center, g.point), 0, accuracy: 1e-9)
            XCTAssertEqual(x.basis, .uwbRanged)
            XCTAssertEqual(g.basis, .gpsRefined)
            XCTAssertEqual(x.hops, 1)
        }
    }

    func testThreePlacedPhonesAndUWBPinThePhoneDown() throws {
        let placed = ["a": FloorPoint(x: 0, z: 0), "b": FloorPoint(x: 10, z: 0), "c": FloorPoint(x: 5, z: 8)]
        let truth = FloorPoint(x: 4, z: 3)
        for seed in UInt32(1)...4 {
            var noise = Noise(state: seed)
            let locator = locator(seed: seed + 1)
            var fixes: [String: PhoneFix] = [:]
            for _ in 0..<10 {
                let anchors = placed.keys.sorted().map { EstimatorAnchor(id: $0, x: placed[$0]!.x, z: placed[$0]!.z, accuracy: nil) }
                let measurements = placed.keys.sorted().map {
                    LinkMeasurement(a: $0, b: "x", rssi: -60, uwbDistance: distance(placed[$0]!, truth) + 0.05 * noise.gauss())
                }
                fixes = locator.update(BluetoothEstimator.Input(anchors: anchors, lost: ["x"], measurements: measurements))
            }
            let x = try XCTUnwrap(fixes["x"])
            XCTAssertLessThan(distance(x.point, truth), 0.5)
            XCTAssertFalse(x.ambiguous)
            XCTAssertNil(x.ring)
            XCTAssertEqual(x.basis, .uwbRanged)
            XCTAssertEqual(fixes["a"]?.basis, .reported(.manual))
        }
    }

    func testUWBHoldsBetweenTwoNoisyGPSPhones() {
        for seed in UInt32(1)...4 {
            var noise = Noise(state: seed)
            let locator = locator(seed: seed + 1)
            for second in 0..<30 {
                let a = EstimatorAnchor(id: "a", x: 8 * noise.gauss(), z: 8 * noise.gauss(), accuracy: 8, source: .gps)
                let b = EstimatorAnchor(id: "b", x: 3 + 8 * noise.gauss(), z: 8 * noise.gauss(), accuracy: 8, source: .gps)
                let fixes = locator.update(BluetoothEstimator.Input(
                    anchors: [a, b], lost: [],
                    measurements: [LinkMeasurement(a: "a", b: "b", rssi: -62, uwbDistance: 3 + 0.03 * noise.gauss())]))
                guard let pa = fixes["a"], let pb = fixes["b"] else { return XCTFail("missing fix at \(second) s") }
                XCTAssertEqual(distance(pa.point, pb.point), 3, accuracy: 0.2)
                XCTAssertEqual(pa.basis, .gpsRefined)
                XCTAssertFalse(pa.ambiguous)
            }
        }
    }

    func testBearingBreaksTheRing() throws {
        let truth = FloorPoint(x: 3, z: 4)
        let direction = atan2(truth.x, truth.z) * 180 / Double.pi
        for seed in UInt32(1)...4 {
            var noise = Noise(state: seed)
            let locator = locator(seed: seed + 1)
            var fixes: [String: PhoneFix] = [:]
            for _ in 0..<10 {
                let bearing = LinkBearing(degrees: direction + 5 * noise.gauss(), errorDegrees: 15)
                fixes = locator.update(BluetoothEstimator.Input(
                    anchors: [EstimatorAnchor(id: "a", x: 0, z: 0, accuracy: nil)], lost: ["x"],
                    measurements: [LinkMeasurement(a: "a", b: "x", uwbDistance: 5 + 0.05 * noise.gauss(), bearing: bearing)]))
            }
            let x = try XCTUnwrap(fixes["x"])
            XCTAssertFalse(x.ambiguous)
            XCTAssertLessThan(distance(x.point, truth), 1.5)
        }
    }

    func testBluetoothOnlyIsTheParticleFilter() throws {
        // Without UWB the locator is the particle filter it wraps: same input, same seed, same answer.
        let placed = ["a": FloorPoint(x: 0, z: 0), "b": FloorPoint(x: 50, z: 0), "c": FloorPoint(x: 25, z: 45)]
        let truth = FloorPoint(x: 22, z: 15)
        let radio = RadioModel.outdoors
        var noise = Noise(state: 3)
        var options = BluetoothEstimator.Options()
        options.seed = 4
        let estimator = BluetoothEstimator(options: options)
        let locator = MeshLocator(options: options)
        var estimate: BluetoothEstimate?
        var fix: PhoneFix?
        for _ in 0..<40 {
            let anchors = placed.keys.sorted().map { EstimatorAnchor(id: $0, x: placed[$0]!.x, z: placed[$0]!.z, accuracy: 5) }
            let measurements = placed.keys.sorted().map {
                LinkMeasurement(a: $0, b: "x", rssi: radio.expectedRSSI(atDistance: distance(placed[$0]!, truth)) + 4 * noise.gauss())
            }
            estimate = estimator.update(anchors: anchors, lost: ["x"], measurements: measurements)["x"]
            fix = locator.update(BluetoothEstimator.Input(anchors: anchors, lost: ["x"], measurements: measurements))["x"]
        }
        let e = try XCTUnwrap(estimate)
        let f = try XCTUnwrap(fix)
        XCTAssertEqual(f.basis, .bluetooth)
        XCTAssertEqual(f.hops, 1)
        XCTAssertEqual(f.r95, e.r95)
        XCTAssertEqual(f.ambiguous, e.ambiguous)
        if !e.ambiguous {
            XCTAssertEqual(f.point, FloorPoint(x: e.x, z: e.z))
        }
        XCTAssertLessThan(distance(FloorPoint(x: e.x, z: e.z), truth), 15)
    }

    func testTypedSpotsMoveAtMostTheirSigma() {
        // Typed 10 m apart, but UWB says 6 m: the typed spots win.
        let locator = locator(seed: 1)
        var fixes: [String: PhoneFix] = [:]
        for _ in 0..<5 {
            fixes = locator.update(BluetoothEstimator.Input(
                anchors: [EstimatorAnchor(id: "a", x: 0, z: 0, accuracy: nil),
                          EstimatorAnchor(id: "b", x: 10, z: 0, accuracy: nil, source: .uwb)],
                lost: [], measurements: [LinkMeasurement(a: "a", b: "b", uwbDistance: 6)]))
        }
        XCTAssertLessThanOrEqual(distance(fixes["a"]!.point, FloorPoint(x: 0, z: 0)), 0.3 + 1e-9)
        XCTAssertLessThanOrEqual(distance(fixes["b"]!.point, FloorPoint(x: 10, z: 0)), 0.3 + 1e-9)
        XCTAssertEqual(fixes["a"]?.basis, .reported(.manual))
        XCTAssertEqual(fixes["b"]?.basis, .reported(.uwb))
    }

    func testPhoneWithoutLinksIsLeftOut() {
        let fixes = MeshLocator().update(BluetoothEstimator.Input(
            anchors: [EstimatorAnchor(id: "a", x: 1, z: 2, accuracy: 4, source: .gps)], lost: ["x"], measurements: []))
        XCTAssertNil(fixes["x"])
        XCTAssertEqual(fixes["a"]?.point, FloorPoint(x: 1, z: 2))
        XCTAssertEqual(fixes["a"]?.basis, .reported(.gps))
    }

    // MARK: Radio calibration

    func testCalibratorRecoversP0FromUWBPairs() {
        var noise = Noise(state: 11)
        var calibrator = RadioCalibrator()
        let truth = RadioModel(p0: -66, n: 2.5, sigma: 5, range: 60, soft: 8)
        for _ in 0..<200 {
            let d = 1 + 19 * noise.next()
            calibrator.add(rssi: truth.expectedRSSI(atDistance: d) + 4 * noise.gauss(), uwbDistance: d + 0.05 * noise.gauss())
        }
        XCTAssertEqual(calibrator.sampleCount, RadioCalibrator.window)
        XCTAssertEqual(calibrator.radio.p0, -66, accuracy: 2)
        XCTAssertEqual(calibrator.radio.n, RadioModel.outdoors.n)
    }

    func testCalibratorWaitsForSamplesAndClamps() {
        var calibrator = RadioCalibrator()
        for _ in 0..<(RadioCalibrator.minimumSamples - 1) { calibrator.add(rssi: -30, uwbDistance: 2) }
        XCTAssertEqual(calibrator.radio, RadioModel.outdoors)
        calibrator.add(rssi: -30, uwbDistance: 2)
        XCTAssertEqual(calibrator.radio.p0, -45)
    }

    func testLocatorUsesTheCalibratedRadio() {
        let truth = RadioModel(p0: -66, n: 2.5, sigma: 5, range: 60, soft: 8)
        let locator = MeshLocator()
        for _ in 0..<RadioCalibrator.minimumSamples {
            _ = locator.update(BluetoothEstimator.Input(
                anchors: [EstimatorAnchor(id: "a", x: 0, z: 0, accuracy: nil), EstimatorAnchor(id: "b", x: 3, z: 0, accuracy: nil)],
                lost: [], measurements: [LinkMeasurement(a: "a", b: "b", rssi: truth.expectedRSSI(atDistance: 3), uwbDistance: 3)]))
        }
        XCTAssertEqual(locator.radio.p0, -66, accuracy: 1e-9)
    }

    func testFifteenPhonesUpdateQuickly() {
        // 5 placed phones and 10 without a position in a 30 m square; UWB under 12 m, RSSI under 40 m.
        var noise = Noise(state: 9)
        var truth: [String: FloorPoint] = [:]
        for k in 0..<15 { truth[String(format: "p%02d", k)] = FloorPoint(x: 30 * noise.next(), z: 30 * noise.next()) }
        let ids = truth.keys.sorted()
        let anchors = ids.prefix(5).map { EstimatorAnchor(id: $0, x: truth[$0]!.x, z: truth[$0]!.z, accuracy: 4, source: .gps) }
        var measurements: [LinkMeasurement] = []
        for i in ids.indices {
            for j in (i + 1)..<ids.count {
                let d = distance(truth[ids[i]]!, truth[ids[j]]!)
                guard d < 40 else { continue }
                measurements.append(LinkMeasurement(a: ids[i], b: ids[j],
                                                    rssi: RadioModel.outdoors.expectedRSSI(atDistance: d) + 4 * noise.gauss(),
                                                    uwbDistance: d < 12 ? d + 0.05 * noise.gauss() : nil))
            }
        }
        let input = BluetoothEstimator.Input(anchors: Array(anchors), lost: Array(ids.dropFirst(5)), measurements: measurements)
        let locator = MeshLocator()
        for _ in 0..<5 { _ = locator.update(input) }
        XCTAssertEqual(locator.update(input).count, 15)
        measure { _ = locator.update(input) }
    }
}
