import Foundation
import XCTest
@testable import MeshCore

/// The runtime feature switches (Start → Features): stored settings always load, and the switches
/// change what the engines in GhostCore's slots do. Numbers from website/shared/signalmap.ts on the
/// same geometry (Bluetooth only: 8.0000 m; calibration off keeps p0 -59, n 2.5; on gives -62.4, 3.52).
final class FeatureFlagsTests: XCTestCase {
    private let t0 = 1_793_000_000.0
    private let radio = RadioModel.standard

    func testDefaultsKeepEveryFeatureOn() {
        let f = FeatureFlags()
        XCTAssertTrue(f.motion)
        XCTAssertTrue(f.compass)
        XCTAssertEqual(f.peerPlacement, .signalMap)
        XCTAssertEqual(f.mainMapRanges, .all)
        XCTAssertTrue(f.calibrateRadio)
        XCTAssertEqual(f.prediction, .model)
        XCTAssertTrue(f.likelyPaths)
        XCTAssertTrue(f.fastUpdates)
        XCTAssertTrue(f.relayIntegrity)
    }

    func testMissingOrUnreadableStorageGivesDefaults() {
        XCTAssertEqual(FeatureFlags.decode(nil), FeatureFlags())
        XCTAssertEqual(FeatureFlags.decode(Data("{}".utf8)), FeatureFlags())
        XCTAssertEqual(FeatureFlags.decode(Data("not json".utf8)), FeatureFlags())
        XCTAssertEqual(FeatureFlags.decode(Data("[]".utf8)), FeatureFlags())
    }

    /// Settings saved by another build: unknown keys are ignored, and an unknown case or a wrong type
    /// falls back to that one switch's default without losing the others.
    func testOtherBuildsSettingsLoadKeyByKey() {
        let json = #"{"motion":"yes","compass":false,"peerPlacement":"quantum","mainMapRanges":"uwbOnly","prediction":"off","newSwitch":true}"#
        let f = FeatureFlags.decode(Data(json.utf8))
        XCTAssertTrue(f.motion)
        XCTAssertFalse(f.compass)
        XCTAssertEqual(f.peerPlacement, .signalMap)
        XCTAssertEqual(f.mainMapRanges, .uwbOnly)
        XCTAssertEqual(f.prediction, .off)
        XCTAssertTrue(f.fastUpdates)
    }

    func testRoundTrip() throws {
        var f = FeatureFlags()
        f.motion = false
        f.peerPlacement = .particleFilter
        f.mainMapRanges = .bluetoothOnly
        f.calibrateRadio = false
        f.prediction = .walkingCircle
        f.likelyPaths = false
        f.fastUpdates = false
        f.relayIntegrity = false
        let data = try XCTUnwrap(f.encoded())
        XCTAssertEqual(FeatureFlags.decode(data), f)
    }

    func testEveryChoiceHasATitle() {
        for c in SignalRanges.allCases { XCTAssertFalse(c.title.isEmpty) }
        for c in PeerPlacement.allCases { XCTAssertFalse(c.title.isEmpty) }
        for c in PredictionMode.allCases { XCTAssertFalse(c.title.isEmpty) }
    }

    func testSignalRangesKeepTheChosenDistances() {
        let links = [LinkMeasurement(a: "a", b: "b", rssi: -60, uwb: 2), LinkMeasurement(a: "a", b: "c", rssi: -70)]
        XCTAssertEqual(SignalRanges.all.apply(links).map(\.uwb), [2, nil])
        let bluetooth = SignalRanges.bluetoothOnly.apply(links)
        XCTAssertEqual(bluetooth.map(\.b), ["b", "c"])
        XCTAssertEqual(bluetooth.map(\.rssi), [-60, -70])
        XCTAssertTrue(bluetooth.allSatisfy { $0.uwb == nil })
        let uwb = SignalRanges.uwbOnly.apply(links)
        XCTAssertEqual(uwb.map(\.b), ["b"])
        XCTAssertEqual(uwb.first?.uwb, 2)
    }

    // MARK: Engines

    private func anchor() -> PositionEstimate {
        PositionEstimate(subjectId: "gps", timestamp: t0, frameId: "hervanta-v1", kind: .measured, method: .gnss,
                         position: Position(x: 10, y: 0, z: 20), uncertainty: PositionUncertainty(r95: 15), source: .gnss,
                         freshness: Freshness(maxAge: 15),
                         provenance: Provenance(producerId: "gps", algorithm: "mesh-report@1", gnssDependent: true))
    }

    /// A UWB link of 3 m whose RSSI reads 8 m (as in SignalMapPositioningTests).
    private func place(ranges: SignalRanges, calibrate: Bool = true) -> (SignalMapPositioning, [PositionEstimate]) {
        let engine = SignalMapPositioning(producerId: "phone-me", frameId: "hervanta-v1")
        engine.ranges = ranges
        engine.calibrate = calibrate
        let placed = engine.place(anchors: [anchor()], lost: ["lost"],
                                  links: [LinkMeasurement(a: "gps", b: "lost", rssi: radio.expectedRSSI(atDistance: 8), uwb: 3)],
                                  observations: [], now: t0)
        return (engine, placed)
    }

    func testBluetoothOnlyIgnoresTheUWBDistance() throws {
        let estimate = try XCTUnwrap(place(ranges: .bluetoothOnly).1.first)
        XCTAssertEqual(estimate.source, .bluetooth)
        let p = try XCTUnwrap(estimate.position)
        XCTAssertEqual(hypot(p.x - 10, p.z - 20), 8, accuracy: 0.01)
    }

    func testUWBOnlyUsesTheUWBDistance() throws {
        let estimate = try XCTUnwrap(place(ranges: .uwbOnly).1.first)
        XCTAssertEqual(estimate.source, .uwb)
        let p = try XCTUnwrap(estimate.position)
        XCTAssertEqual(hypot(p.x - 10, p.z - 20), 3, accuracy: 0.01)
    }

    /// UWB only drops a link without a UWB distance, so a phone linked by Bluetooth alone isn't placed.
    func testUWBOnlyLeavesBluetoothOnlyPhonesUnplaced() {
        let engine = SignalMapPositioning(producerId: "phone-me", frameId: "hervanta-v1")
        engine.ranges = .uwbOnly
        let placed = engine.place(anchors: [anchor()], lost: ["lost"],
                                  links: [LinkMeasurement(a: "gps", b: "lost", rssi: -70)], observations: [], now: t0)
        XCTAssertTrue(placed.isEmpty)
    }

    func testCalibrationSwitch() {
        XCTAssertEqual(place(ranges: .all, calibrate: false).0.calibratedRadio, radio)
        let calibrated = place(ranges: .all, calibrate: true).0.calibratedRadio
        XCTAssertEqual(calibrated.p0, -62.4, accuracy: 0.1)
        XCTAssertEqual(calibrated.n, 3.52, accuracy: 0.01)
    }

    func testNoPredictionNeverPredicts() {
        let engine = NoPrediction()
        engine.observe(anchor(), receivedAt: t0)
        XCTAssertNil(engine.predict(subjectId: "gps", at: t0 + 30))
    }
}
