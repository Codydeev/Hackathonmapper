import XCTest
@testable import MeshCore

final class PositioningRSSITests: XCTestCase {
    private func sample(_ rssi: Double, _ t: Double, peer: String = "phone-a",
                        channel: PZ.RSSIChannel = .advertisement) -> PZ.RSSISample {
        PZ.RSSISample(peerId: peer, rssi: rssi, t: t, channel: channel)
    }

    func testMedianIgnoresDeepFadeAndSpike() {
        var filter = PZ.RSSIMedianFilter(window: 4)
        let values: [Double] = [-70, -71, -69, -70, -95, -72, -93, -70, -71, -69]
        for (i, v) in values.enumerated() { XCTAssertTrue(filter.add(sample(v, Double(i) * 0.4))) }
        let w = try! XCTUnwrap(filter.current(peerId: "phone-a", channel: .advertisement, now: 3.9))
        XCTAssertEqual(w.median, -70, accuracy: 0.01)
        XCTAssertEqual(w.rejected, 2, "the two deep fades are Hampel outliers")
        XCTAssertEqual(w.count, 8)
        let mean = values.reduce(0, +) / Double(values.count)
        XCTAssertGreaterThan(abs(mean + 70), 2, "a mean would have been pulled by several dB")
    }

    func testInvalidReadingsAreDropped() {
        var filter = PZ.RSSIMedianFilter()
        XCTAssertFalse(filter.add(sample(127, 0)), "iOS reports 127 when it has no reading")
        XCTAssertFalse(filter.add(sample(-128, 0)))
        XCTAssertFalse(filter.add(sample(21, 0)))
        XCTAssertFalse(filter.add(sample(.nan, 0)))
        XCTAssertTrue(filter.add(sample(-60, 0)))
    }

    func testWindowsDoNotOverlapAndUseEachSampleOnce() {
        var filter = PZ.RSSIMedianFilter(window: 4)
        for i in 0...50 { filter.add(sample(-70, Double(i) * 0.2)) }
        XCTAssertTrue(filter.takeWindows(now: 3.9).isEmpty, "less than one window of samples yet")
        let first = filter.takeWindows(now: 4.0)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.count, 21)
        XCTAssertTrue(filter.takeWindows(now: 5).isEmpty)
        let second = filter.takeWindows(now: 8.3)
        XCTAssertEqual(second.first?.count, 21)
        XCTAssertGreaterThan(second.first?.start ?? 0, first.first?.end ?? .infinity)
        XCTAssertFalse(filter.add(sample(-70, 3.0)), "older than samples already handed out")
    }

    func testStaleSamplesAreDroppedUnused() {
        var filter = PZ.RSSIMedianFilter(window: 4)
        for i in 0..<10 { filter.add(sample(-70, Double(i) * 0.1)) }
        XCTAssertTrue(filter.takeWindows(now: 20).isEmpty)
    }

    func testLateSampleKeepsTimeOrder() {
        var filter = PZ.RSSIMedianFilter(window: 4, minSamples: 1)
        filter.add(sample(-70, 1.0))
        filter.add(sample(-72, 0.5))
        XCTAssertEqual(filter.current(peerId: "phone-a", channel: .advertisement, now: 1.0)?.start, 0.5)
    }

    func testRelayedSmoothedValueIsOneWindow() {
        var filter = PZ.RSSIMedianFilter(window: 4)
        filter.add(sample(-66, 1.0, channel: .relayedSmoothed))
        let windows = filter.takeWindows(now: 1.0)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.median, -66)
    }

    func testDistanceIntervalIsWideAndHonest() {
        let model = PZ.PathLossModel.defaultOutdoor
        let rssi = model.expectedRSSI(distance: 10)
        XCTAssertEqual(model.medianDistance(rssi: rssi), 10, accuracy: 1e-6)
        let interval = model.distanceInterval(rssi: rssi)
        XCTAssertTrue(interval.contains(10))
        XCTAssertLessThan(interval.lowerBound, 4, "5.6 dB of spread is a factor ~2.7 in distance at 95 %")
        XCTAssertGreaterThan(interval.upperBound, 25)
    }

    // MARK: - Calibration

    private func calibrationSession(p0: Double, n: Double, distances: [Double], seed: UInt64) -> PZ.CalibrationSession {
        var rng = SimRandom(seed: seed)
        var session = PZ.CalibrationSession(peerId: "phone-a", channel: .advertisement, observerModel: "iPhone17,1",
                                            peerModel: "iPhone16,1", environment: "Hervanta field")
        var t = 0.0
        for d in distances {
            session.begin(distance: d, label: "in hand, facing")
            let spot = 2 * rng.gauss()
            for _ in 0..<150 {
                t += 0.2
                var rssi = p0 - 10 * n * log10(d) + spot + 3 * rng.gauss()
                if rng.next() < 0.05 { rssi -= 15 }
                session.record(sample(rssi.rounded(), t))
            }
            XCTAssertTrue(session.isStepComplete)
            session.end()
            t += 30
        }
        return session
    }

    func testCalibrationRecoversPathLoss() throws {
        let session = calibrationSession(p0: -61, n: 2.2, distances: PZ.CalibrationSession.suggestedDistances, seed: 7)
        let result = try session.fit(window: 4, date: "2026-10-24")
        XCTAssertEqual(result.model.p0, -61, accuracy: 3)
        XCTAssertEqual(result.model.n, 2.2, accuracy: 0.4)
        XCTAssertEqual(result.distances.count, 7)
        XCTAssertGreaterThanOrEqual(result.model.sigmaShadow, 3, "one walk cannot measure shadowing below 3 dB")
        XCTAssertLessThan(result.model.sigmaFast, 4)
        XCTAssertLessThan(result.leaveOneOutRangeError, 0.5)
        XCTAssertTrue(result.model.source.contains("calibrated 2026-10-24"))
    }

    func testCalibrationAtTheFieldTestDistances() throws {
        // ARCHITECTURE.md T2 records 2, 5, 10 and 20 m.
        let session = calibrationSession(p0: -58, n: 2.5, distances: [2, 5, 10, 20], seed: 11)
        let result = try session.fit()
        XCTAssertEqual(result.model.n, 2.5, accuracy: 0.6)
        XCTAssertTrue(result.warnings.contains { $0.contains("Fewer than 5 distances") })
    }

    func testCalibrationRefusesTooFewDistances() {
        let session = calibrationSession(p0: -60, n: 2, distances: [1, 8], seed: 3)
        XCTAssertThrowsError(try session.fit()) { XCTAssertEqual($0 as? PZ.CalibrationError, .tooFewDistances(found: 2)) }
    }

    func testCalibrationRefusesNarrowSpan() {
        let session = calibrationSession(p0: -60, n: 2, distances: [2, 3, 4], seed: 3)
        XCTAssertThrowsError(try session.fit()) {
            guard case .distanceSpanTooSmall = $0 as? PZ.CalibrationError else { return XCTFail("\($0)") }
        }
    }

    func testCalibrationOnlyRecordsThePeerDuringAStep() {
        var session = PZ.CalibrationSession(peerId: "phone-a", channel: .advertisement, observerModel: "a", peerModel: "b",
                                            environment: "")
        XCTAssertFalse(session.record(sample(-60, 0)), "no step active")
        session.begin(distance: 2)
        XCTAssertFalse(session.record(sample(-60, 1, peer: "phone-c")))
        XCTAssertFalse(session.record(sample(-60, 1, channel: .connection)))
        XCTAssertTrue(session.record(sample(-60, 1)))
    }
}
