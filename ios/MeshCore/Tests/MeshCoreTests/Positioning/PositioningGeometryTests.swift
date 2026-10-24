import XCTest
@testable import MeshCore

final class PositioningGeometryTests: XCTestCase {
    private let model = PZ.PathLossModel.defaultOutdoor

    private func observation(_ id: String, at anchor: PZ.Vec2, truth: PZ.Vec2, offset: Double = 0,
                             sigma: Double = 1, t: Double = 10) -> PZ.RangeObservation {
        let rssi = model.expectedRSSI(distance: anchor.distance(to: truth)) + offset
        let window = PZ.RSSIWindow(peerId: id, channel: .advertisement, median: rssi, spread: 2, count: 20, rejected: 0,
                                   start: t - 4, end: t, t: t - 2)
        let a = PZ.Anchor(id: id, position: anchor, sigma: sigma, kind: .surveyed, measuredAt: t, speedBound: 0)
        return PZ.RangeObservation(anchor: a, window: window, model: model)
    }

    func testOneAnchorIsADiscAroundTheAnchorNeverAPoint() throws {
        let anchor = PZ.Vec2(x: 0, z: 0)
        let truth = PZ.Vec2(x: 12, z: 5)
        for offset in [0.0, -10, 6] {
            let s = try XCTUnwrap(PZ.RangeGeometry.solve([observation("phone-a", at: anchor, truth: truth, offset: offset)]))
            XCTAssertEqual(s.kind, .proximity)
            XCTAssertEqual(s.center, anchor, "the region is centred on the anchor; the anchor's coordinate is not our position")
            XCTAssertTrue(s.candidates.isEmpty)
            XCTAssertGreaterThanOrEqual(s.r95, truth.distance(to: anchor), "disc must hold the truth (offset \(offset) dB)")
        }
    }

    func testTwoAnchorsLeaveTwoMirrorCandidates() throws {
        let truth = PZ.Vec2(x: 10, z: 8)
        let s = try XCTUnwrap(PZ.RangeGeometry.solve([
            observation("phone-a", at: PZ.Vec2(x: 0, z: 0), truth: truth),
            observation("phone-c", at: PZ.Vec2(x: 20, z: 0), truth: truth),
        ]))
        XCTAssertEqual(s.kind, .ambiguous)
        XCTAssertEqual(s.candidates.count, 2)
        XCTAssertLessThan(s.candidates.map { $0.distance(to: truth) }.min()!, 1)
        XCTAssertLessThan(s.candidates.map { $0.distance(to: PZ.Vec2(x: 10, z: -8)) }.min()!, 1, "the mirror spot fits equally well")
        XCTAssertGreaterThanOrEqual(s.r95, s.center.distance(to: truth))
    }

    func testThreeWellPlacedAnchorsMultilaterate() throws {
        let truth = PZ.Vec2(x: 14, z: 9)
        let s = try XCTUnwrap(PZ.RangeGeometry.solve([
            observation("phone-a", at: PZ.Vec2(x: 0, z: 0), truth: truth),
            observation("phone-c", at: PZ.Vec2(x: 30, z: 0), truth: truth),
            observation("phone-d", at: PZ.Vec2(x: 15, z: 26), truth: truth),
        ]))
        XCTAssertEqual(s.kind, .multilateration)
        XCTAssertLessThan(s.center.distance(to: truth), 0.5)
        XCTAssertLessThan(try XCTUnwrap(s.hdop), PZ.RangeGeometry.maxHDOP)
        XCTAssertGreaterThan(s.r95, 3, "RSSI ranges cannot give metre-level precision")
    }

    func testCollinearAnchorsDoNotClaimAPoint() throws {
        let truth = PZ.Vec2(x: 12, z: 10)
        let s = try XCTUnwrap(PZ.RangeGeometry.solve([
            observation("phone-a", at: PZ.Vec2(x: 0, z: 0), truth: truth),
            observation("phone-c", at: PZ.Vec2(x: 15, z: 0), truth: truth),
            observation("phone-d", at: PZ.Vec2(x: 30, z: 0), truth: truth),
        ]))
        XCTAssertNotEqual(s.kind, .multilateration, "a mirror solution across the anchor line fits as well")
        XCTAssertGreaterThanOrEqual(s.r95, s.center.distance(to: truth))
    }

    func testClusteredAnchorsFallBackToADisc() throws {
        let truth = PZ.Vec2(x: 40, z: 30)
        let s = try XCTUnwrap(PZ.RangeGeometry.solve([
            observation("phone-a", at: PZ.Vec2(x: 0, z: 0), truth: truth),
            observation("phone-c", at: PZ.Vec2(x: 1, z: 0), truth: truth),
            observation("phone-d", at: PZ.Vec2(x: 0, z: 1), truth: truth),
        ]))
        XCTAssertNotEqual(s.kind, .multilateration)
        XCTAssertGreaterThanOrEqual(s.r95, s.center.distance(to: truth))
    }

    func testNoisyMultilaterationRadiusHoldsTheTruth() {
        // Readings scatter by the model's own spread; the reported r95 should hold the truth ~95 %.
        var rng = SimRandom(seed: 21)
        let anchors = [PZ.Vec2(x: 0, z: 0), PZ.Vec2(x: 40, z: 0), PZ.Vec2(x: 40, z: 40), PZ.Vec2(x: 0, z: 40)]
        var solved = 0
        var contained = 0
        for _ in 0..<300 {
            let truth = PZ.Vec2(x: rng.uniform(5, 35), z: rng.uniform(5, 35))
            let obs = anchors.enumerated().map { i, a in
                observation("phone-\(i)", at: a, truth: truth, offset: model.totalSigma * rng.gauss())
            }
            guard let s = PZ.RangeGeometry.solve(obs), s.kind == .multilateration else { continue }
            solved += 1
            if s.center.distance(to: truth) <= s.r95 { contained += 1 }
        }
        XCTAssertGreaterThan(solved, 200)
        XCTAssertGreaterThanOrEqual(Double(contained) / Double(solved), 0.85, "\(contained)/\(solved)")
    }

    func testWeakReadingNearSensitivityOnlySaysFar() throws {
        // At the edge of range only the fades up are heard, so the median reads too strong: a phone
        // 90 m away whose surviving samples read like 55 m. The disc must still hold it.
        let survivorRSSI = model.expectedRSSI(distance: 55)
        XCTAssertTrue(model.isCensored(rssi: survivorRSSI))
        XCTAssertEqual(model.distanceInterval(rssi: survivorRSSI).upperBound, model.maxRange)
        let truth = PZ.Vec2(x: 90, z: 0)
        let window = PZ.RSSIWindow(peerId: "phone-a", channel: .advertisement, median: survivorRSSI, spread: 2, count: 6,
                                   rejected: 0, start: 6, end: 10, t: 8)
        let a = PZ.Anchor(id: "phone-a", position: .zero, sigma: 3, kind: .gnss, measuredAt: 10, speedBound: 0)
        let s = try XCTUnwrap(PZ.RangeGeometry.solve([PZ.RangeObservation(anchor: a, window: window, model: model)]))
        XCTAssertGreaterThanOrEqual(s.r95, truth.distance(to: .zero))
        XCTAssertFalse(model.isCensored(rssi: model.expectedRSSI(distance: 30)), "a 30 m reading is well above the floor")
    }

    func testAnchorUncertaintyGrowsWithAge() {
        let a = PZ.Anchor(id: "phone-a", position: .zero, sigma: 3, kind: .gnss, measuredAt: 0, timeSigma: 0.5, speedBound: 1.5)
        XCTAssertEqual(a.sigma(at: 0), (9 + 0.5625).squareRoot(), accuracy: 1e-9)
        XCTAssertGreaterThan(a.sigma(at: 10), 15)
        let fixed = PZ.Anchor(id: "marker", position: .zero, sigma: 0.5, kind: .surveyed, measuredAt: 0, speedBound: 0)
        XCTAssertEqual(fixed.sigma(at: 100), 0.5)
    }
}
