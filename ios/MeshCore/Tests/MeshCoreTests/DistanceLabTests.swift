import Foundation
import XCTest
@testable import MeshCore

/// The Track tab's distance comparison: each method's reading of one link, and a tape-measure trial.
final class DistanceLabTests: XCTestCase {
    private let radio = RadioModel.standard

    func testEachMethodReadsItsOwnInput() throws {
        var lab = DistanceLab()
        lab.calibratedRadio = RadioModel(p0: -63, n: 2.2, sigma: 5, range: 60, soft: 8)
        let inputs = DistanceInputs(uwb: 3, smoothedRSSI: radio.expectedRSSI(atDistance: 5), peerRSSI: -62, signalMap: 4.2,
                                    ownGPS: FloorPoint(x: 0, z: 0), ownGPSR95: 3, peerGPS: FloorPoint(x: 3, z: 4), peerGPSR95: 4)
        let readings = lab.readings(for: "peer", inputs: inputs, now: 100)
        func reading(_ method: DistanceMethod) throws -> DistanceReading { try XCTUnwrap(readings.first { $0.method == method }) }

        XCTAssertEqual(readings.map(\.method), [.uwb, .signalMap, .rssiCalibrated, .rssiDefault, .gps])
        let uwb = try reading(.uwb)
        XCTAssertEqual(uwb.meters, 3)
        XCTAssertEqual(uwb.low ?? 0, 3 - 1.96 * SignalMap.uwbSigma, accuracy: 1e-9)
        XCTAssertEqual(try reading(.signalMap).meters, 4.2)
        XCTAssertNil(try reading(.signalMap).low)
        let defaultModel = try reading(.rssiDefault)
        XCTAssertEqual(defaultModel.meters, 5, accuracy: 1e-9)
        XCTAssertLessThan(defaultModel.low ?? 99, 5)
        XCTAssertGreaterThan(defaultModel.high ?? 0, 5)
        // Both ends averaged, through the calibrated model.
        let mean = (radio.expectedRSSI(atDistance: 5) + -62) / 2
        XCTAssertEqual(try reading(.rssiCalibrated).meters, lab.calibratedRadio.distance(forRSSI: mean), accuracy: 1e-9)
        let gps = try reading(.gps)
        XCTAssertEqual(gps.meters, 5, accuracy: 1e-9)
        XCTAssertEqual(gps.low ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(gps.high ?? 0, 10, accuracy: 1e-9)
    }

    func testNothingMeasuredMeansNoReadings() {
        XCTAssertTrue(DistanceLab().readings(for: "peer", inputs: DistanceInputs(), now: 0).isEmpty)
    }

    /// GhostCore's median filter: three raw samples in 4 s, a deep fade dropped as an outlier, and
    /// samples resent by the next second's list counted once.
    func testMedianFilterNeedsThreeSamplesDropsOutliersAndDeduplicates() throws {
        var lab = DistanceLab()
        lab.add(rawRSSI: [(rssi: -60, t: 10), (rssi: -61, t: 11)], from: "peer")
        lab.add(rawRSSI: [(rssi: -60, t: 10), (rssi: -61, t: 11)], from: "peer")
        XCTAssertNil(lab.readings(for: "peer", inputs: DistanceInputs(), now: 11.5).first { $0.method == .rssiMedian })

        lab.add(rawRSSI: [(rssi: -61, t: 11), (rssi: -60, t: 12), (rssi: -90, t: 12.5)], from: "peer")
        let median = try XCTUnwrap(lab.readings(for: "peer", inputs: DistanceInputs(), now: 13).first { $0.method == .rssiMedian })
        XCTAssertEqual(median.meters, Positioning.PathLossModel.defaultOutdoor.medianDistance(rssi: -60), accuracy: 1e-9)
        XCTAssertNotNil(median.low)

        // Outside the 4 s window the samples no longer count.
        XCTAssertNil(lab.readings(for: "peer", inputs: DistanceInputs(), now: 30).first { $0.method == .rssiMedian })
    }

    func testTrialScoresEachMethodAgainstTheTapeMeasure() throws {
        var trial = DistanceTrial(peerId: "peer", peerLabel: "Otter 12", trueDistance: 4, startedAt: 100)
        trial.record([DistanceReading(method: .uwb, meters: 4.1, low: 3.5, high: 4.7),
                      DistanceReading(method: .rssiDefault, meters: 6, low: 3, high: 12)], at: 101)
        trial.record([DistanceReading(method: .uwb, meters: 3.9, low: 3.3, high: 4.5),
                      DistanceReading(method: .rssiDefault, meters: 2, low: 1, high: 3.9)], at: 102)
        trial.record([], at: 103)
        XCTAssertEqual(trial.samples.count, 2)

        let scores = trial.scores
        XCTAssertEqual(scores.map(\.method), [.uwb, .rssiDefault])
        let uwb = try XCTUnwrap(scores.first { $0.method == .uwb })
        XCTAssertEqual(uwb.count, 2)
        XCTAssertEqual(uwb.bias, 0, accuracy: 1e-9)
        XCTAssertEqual(uwb.meanAbsoluteError, 0.1, accuracy: 1e-9)
        XCTAssertEqual(uwb.rmse, 0.1, accuracy: 1e-9)
        XCTAssertEqual(uwb.coverage ?? 0, 1, accuracy: 1e-9)
        let rssi = try XCTUnwrap(scores.first { $0.method == .rssiDefault })
        XCTAssertEqual(rssi.meanAbsoluteError, 2, accuracy: 1e-9)
        XCTAssertEqual(rssi.rmse, 2, accuracy: 1e-9)
        XCTAssertEqual(rssi.coverage ?? 0, 0.5, accuracy: 1e-9)
    }

    func testTrialCSVHasOneColumnPerMethod() {
        var trial = DistanceTrial(peerId: "peer", peerLabel: "Otter, 12", trueDistance: 4, startedAt: 100)
        trial.record([DistanceReading(method: .uwb, meters: 4.1), DistanceReading(method: .rssiDefault, meters: 6)], at: 101)
        XCTAssertEqual(trial.csv(), """
        t_s,peer,true_m,uwb,signalMap,rssiCalibrated,rssiDefault,rssiMedian,gps
        1.0,"Otter, 12",4.00,4.10,,,6.00,,

        """)
    }
}
