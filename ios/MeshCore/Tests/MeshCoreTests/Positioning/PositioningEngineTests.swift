import XCTest
@testable import MeshCore

final class PositioningEngineTests: XCTestCase {
    private func engine() -> PZ.Engine { PZ.Engine(selfId: "phone-b", frameId: "hervanta-v1") }

    private func fix(_ t: Double, _ p: PZ.Vec2 = .zero, accuracy: Double = 5, trusted: Bool = true) -> PZ.GNSSFix {
        PZ.GNSSFix(t: t, position: p, horizontalAccuracy: accuracy, trusted: trusted)
    }

    private func anchor(_ id: String, _ p: PZ.Vec2, at t: Double, kind: PZ.Anchor.Kind = .surveyed, sigma: Double = 1,
                        dependsOn: [String] = []) -> PZ.Anchor {
        PZ.Anchor(id: id, position: p, sigma: sigma, kind: kind, measuredAt: t, speedBound: kind == .surveyed ? 0 : 1.5,
                  dependsOn: dependsOn)
    }

    /// Exact RSSI for the true distance, 5 Hz, from `t0` to `t1`.
    private func rssi(_ e: PZ.Engine, from id: String, anchor: PZ.Vec2, truth: PZ.Vec2, _ t0: Double, _ t1: Double,
                      offset: Double = 0) {
        let value = PZ.PathLossModel.defaultOutdoor.expectedRSSI(distance: anchor.distance(to: truth)) + offset
        var t = t0
        while t <= t1 {
            e.ingest(rssi: PZ.RSSISample(peerId: id, rssi: value, t: t, channel: .advertisement))
            t += 0.2
        }
    }

    /// Phone lying still: zero user acceleration, gravity straight down.
    private func still(_ e: PZ.Engine, _ t0: Double, _ t1: Double, bias: Double = 0) {
        var t = t0
        while t <= t1 {
            e.ingest(motion: PZ.MotionSample(t: t, gravity: PZ.Vec3(0, 0, -1), userAcceleration: PZ.Vec3(0, 0, 0),
                                             rotationRate: PZ.Vec3(0, 0, -bias)))
            t += 0.02
        }
    }

    func testTrustedFixIsGNSSAndUntrustedFixIsNeverUsed() {
        let e = engine()
        e.ingest(gnss: fix(1, PZ.Vec2(x: 5, z: 5), trusted: false))
        let before = e.estimate(at: 1)
        XCTAssertEqual(before.method, .unavailable)
        XCTAssertNil(before.position)
        XCTAssertTrue(before.provenance.contains { $0.source == .gnss && !$0.used && ($0.reason ?? "").contains("integrity") })

        e.ingest(gnss: fix(2, PZ.Vec2(x: 5, z: 5)))
        let after = e.estimate(at: 2)
        XCTAssertEqual(after.method, .gnss)
        XCTAssertEqual(after.position!.distance(to: PZ.Vec2(x: 5, z: 5)), 0, accuracy: 1e-9)
        XCTAssertEqual(after.r95!, PositionUncertainty.r95(fromRadius68: 5), accuracy: 0.05)
        XCTAssertTrue(after.gnssDependent)
    }

    func testOutageWithoutMotionDataWidensAtWalkingPaceAndAges() {
        let e = engine()
        for t in 0...10 { e.ingest(gnss: fix(Double(t))) }
        let lost = e.estimate(at: 40)
        XCTAssertEqual(lost.method, .deadReckoning)
        XCTAssertEqual(lost.age!, 30, accuracy: 1e-9)
        XCTAssertTrue(lost.flags.contains(.motionUnavailable))
        XCTAssertGreaterThan(lost.r95!, 1.4 * 30, "nobody counted steps: it may have walked 42 m in any direction")
        XCTAssertEqual(lost.lastTrustedGNSS?.t, 10)
    }

    func testStaleFixIsDroppedAndLateFixWithinLagIsUsed() {
        let e = engine()
        e.ingest(gnss: fix(10))
        _ = e.estimate(at: 20)
        e.ingest(gnss: fix(15))
        XCTAssertEqual(e.diagnostics.staleDropped, 1, "5 s behind the filter clock is stale")
        e.ingest(gnss: fix(19))
        XCTAssertEqual(e.estimate(at: 20.5).method, .gnss, "1 s late is used")
    }

    func testRememberedFixSeedsWithWalkingPaceUncertainty() {
        let e = engine()
        _ = e.estimate(at: 100)
        e.ingest(gnss: fix(40, PZ.Vec2(x: 3, z: 4)))
        let est = e.estimate(at: 100)
        XCTAssertEqual(est.position!, PZ.Vec2(x: 3, z: 4))
        XCTAssertGreaterThan(est.r95!, 1.4 * 60 * 2, "60 s unaccounted for")
    }

    func testOneAnchorGivesAProximityRegionNotAPoint() {
        let e = engine()
        let a = PZ.Vec2(x: 0, z: 0)
        let truth = PZ.Vec2(x: 9, z: 8)
        e.ingest(anchor: anchor("phone-a", a, at: 0, kind: .gnss, sigma: 3.3))
        rssi(e, from: "phone-a", anchor: a, truth: truth, 0, 9)
        let est = e.estimate(at: 9)
        XCTAssertEqual(est.method, .proximity)
        XCTAssertNil(est.position, "a neighbour's coordinate is not our position")
        XCTAssertEqual(est.regionCenter, a)
        XCTAssertGreaterThanOrEqual(est.r95!, truth.distance(to: a))
        XCTAssertEqual(est.anchorIds, ["phone-a"])
        XCTAssertTrue(est.gnssDependent)
    }

    func testTwoAnchorsAreAmbiguous() {
        let e = engine()
        let truth = PZ.Vec2(x: 10, z: 8)
        for (id, p) in [("phone-a", PZ.Vec2(x: 0, z: 0)), ("phone-c", PZ.Vec2(x: 20, z: 0))] {
            e.ingest(anchor: anchor(id, p, at: 0))
            rssi(e, from: id, anchor: p, truth: truth, 0, 9)
        }
        let est = e.estimate(at: 9)
        XCTAssertEqual(est.method, .ambiguous)
        XCTAssertNil(est.position)
        XCTAssertEqual(est.candidates.count, 2)
        XCTAssertLessThan(est.candidates.map { $0.distance(to: truth) }.min()!, 1.5)
    }

    func testThreeAnchorsMultilaterate() {
        let e = engine()
        let truth = PZ.Vec2(x: 14, z: 9)
        for (id, p) in [("phone-a", PZ.Vec2(x: 0, z: 0)), ("phone-c", PZ.Vec2(x: 30, z: 0)), ("phone-d", PZ.Vec2(x: 15, z: 26))] {
            e.ingest(anchor: anchor(id, p, at: 0))
            rssi(e, from: id, anchor: p, truth: truth, 0, 9)
        }
        let est = e.estimate(at: 9)
        XCTAssertEqual(est.method, .multilateration)
        XCTAssertLessThan(est.position!.distance(to: truth), est.r95!)
        XCTAssertEqual(Set(est.anchorIds), ["phone-a", "phone-c", "phone-d"])
    }

    func testStaleAnchorIsIgnored() {
        let e = engine()
        e.ingest(anchor: anchor("phone-a", .zero, at: 0, kind: .gnss))
        rssi(e, from: "phone-a", anchor: .zero, truth: PZ.Vec2(x: 5, z: 0), 40, 50)
        XCTAssertEqual(e.estimate(at: 50).method, .unavailable, "an anchor position 50 s old is not used")
    }

    func testEstimatedAnchorThatDependsOnThisPhoneIsRefused() {
        let e = engine()
        e.ingest(anchor: anchor("phone-c", .zero, at: 0, kind: .estimated, sigma: 4, dependsOn: ["phone-c", "phone-b"]))
        rssi(e, from: "phone-c", anchor: .zero, truth: PZ.Vec2(x: 5, z: 0), 0, 9)
        XCTAssertEqual(e.diagnostics.anchorsRefused, 1)
        XCTAssertEqual(e.estimate(at: 9).method, .unavailable)
    }

    func testWithdrawnAnchorStopsAnchoringAtOnce() {
        let e = engine()
        let truth = PZ.Vec2(x: 14, z: 9)
        let spots = [("phone-a", PZ.Vec2(x: 0, z: 0)), ("phone-c", PZ.Vec2(x: 30, z: 0)), ("phone-d", PZ.Vec2(x: 15, z: 26))]
        for (id, p) in spots {
            e.ingest(anchor: anchor(id, p, at: 0))
            rssi(e, from: id, anchor: p, truth: truth, 0, 9)
        }
        XCTAssertTrue(e.estimate(at: 9).anchorIds.contains("phone-c"))
        e.removeAnchor("phone-c", at: 9.5, reason: "GNSS rejected: positionJump")
        let est = e.estimate(at: 10)
        XCTAssertFalse(est.anchorIds.contains("phone-c"))
        let c = est.provenance.filter { $0.peerId == "phone-c" }
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.first?.used, false)
        XCTAssertEqual(c.first?.reason, "GNSS rejected: positionJump")
    }

    func testGyroBiasIsLearnedWhileStill() {
        let e = engine()
        e.ingest(compass: PZ.CompassSample(t: 0, heading: 0, sigma: PZ.degrees(5)))
        still(e, 0.02, 20, bias: 0.004)
        XCTAssertEqual(e.gyroBiasEstimate, 0.004, accuracy: 0.0005)
        XCTAssertEqual(e.estimate(at: 20).heading!, 0, accuracy: PZ.degrees(1), "a still phone's heading does not drift")
    }

    func testHeadingUncertaintyGrowsWithoutCompass() {
        let e = engine()
        e.declare(position: .zero, sigma: 1, at: 0)
        e.ingest(compass: PZ.CompassSample(t: 0, heading: 0, sigma: PZ.degrees(3)))
        let start = e.estimate(at: 0.01).headingSigma!
        var t = 0.02
        while t < 300 {
            let a = 0.3 * sin(2 * .pi * 1.8 * t)
            e.ingest(motion: PZ.MotionSample(t: t, gravity: PZ.Vec3(0, 0, -1), userAcceleration: PZ.Vec3(0, 0, a),
                                             rotationRate: PZ.Vec3(0, 0, 0)))
            t += 0.02
        }
        XCTAssertGreaterThan(e.estimate(at: t).headingSigma!, 1.5 * start, "gyro-only heading drifts and says so")
    }

    func testRepeatedRSSIFromAStaticLinkDoesNotCollapseTheUncertainty() {
        // A phone lying still 12 m from an anchor in a spot whose shadowing reads 5 dB weak. Ten
        // minutes of identical evidence must not shrink the circle to the biased range.
        let e = engine()
        let truth = PZ.Vec2(x: 12, z: 0)
        e.declare(position: PZ.Vec2(x: 13, z: 1), sigma: 2.5, at: 0)
        e.ingest(anchor: anchor("marker", .zero, at: 0, sigma: 0.3))
        var rng = SimRandom(seed: 9)
        var t = 0.0
        var r95s: [Double] = []
        var contained = 0
        var checks = 0
        while t < 600 {
            still(e, t + 0.02, t + 1)
            let value = PZ.PathLossModel.defaultOutdoor.expectedRSSI(distance: 12) - 5
            for k in 0..<5 {
                e.ingest(rssi: PZ.RSSISample(peerId: "marker", rssi: (value + 2.5 * rng.gauss()).rounded(),
                                             t: t + 0.2 * Double(k + 1), channel: .advertisement))
            }
            e.ingest(anchor: anchor("marker", .zero, at: t + 1, sigma: 0.3))
            t += 1
            let est = e.estimate(at: t)
            if let p = est.position, let r = est.r95 {
                r95s.append(r)
                checks += 1
                if p.distance(to: truth) <= r { contained += 1 }
            }
        }
        XCTAssertGreaterThan(e.diagnostics.rangeUpdates, 50)
        XCTAssertGreaterThan(r95s.last!, 2, "shadowing is a state: static evidence cannot make it metre-precise")
        XCTAssertGreaterThanOrEqual(Double(contained) / Double(checks), 0.95)
    }
}
