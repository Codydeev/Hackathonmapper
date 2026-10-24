import XCTest
import MeshCore

/// The map's pure rules: link labels, camera span and refit hysteresis, and the inconsistency flag.
final class MapPresentationTests: XCTestCase {
    func testLinkLabelPrefersUWBWithCentimetres() {
        XCTAssertEqual(MapPresentation.linkLabel(uwb: 3.4167, rssiDistance: 6), "3.42 m")
        XCTAssertEqual(MapPresentation.linkLabel(uwb: 0, rssiDistance: nil), "0.00 m")
    }

    func testLinkLabelRoundsBluetoothDistance() {
        XCTAssertEqual(MapPresentation.linkLabel(uwb: nil, rssiDistance: 4.3), "≈ 4 m")
        XCTAssertEqual(MapPresentation.linkLabel(uwb: nil, rssiDistance: 0.2), "≈ 1 m")
        XCTAssertEqual(MapPresentation.linkLabel(uwb: nil, rssiDistance: 1500), "≈ 1.5 km")
    }

    func testLinkLabelEmptyWithoutDistance() {
        XCTAssertEqual(MapPresentation.linkLabel(uwb: nil, rssiDistance: nil), "")
        XCTAssertEqual(MapPresentation.linkLabel(uwb: .nan, rssiDistance: .infinity), "")
    }

    func testCameraSpanHasMinimum() {
        let me = FloorPoint(x: 10, z: 10)
        XCTAssertEqual(MapPresentation.cameraSpan(selfPoint: me, neighbors: []), 25)
        XCTAssertEqual(MapPresentation.cameraSpan(selfPoint: me, neighbors: [FloorPoint(x: 13, z: 14)]), 25)
        XCTAssertEqual(MapPresentation.cameraSpan(selfPoint: nil, neighbors: [FloorPoint(x: 100, z: 0)]), 25)
    }

    func testCameraSpanFollowsFarthestNeighbor() {
        let me = FloorPoint(x: 0, z: 0)
        let span = MapPresentation.cameraSpan(selfPoint: me, neighbors: [FloorPoint(x: 3, z: 4), FloorPoint(x: 0, z: -20)])
        XCTAssertEqual(span, 50, accuracy: 1e-9)
        XCTAssertEqual(MapPresentation.cameraSpan(selfPoint: me, neighbors: [FloorPoint(x: 1e7, z: 0)]),
                       MapPresentation.maximumSpan)
    }

    func testRefitHysteresis() {
        XCTAssertTrue(MapPresentation.shouldRefit(current: nil, needed: 25))
        XCTAssertFalse(MapPresentation.shouldRefit(current: 25, needed: 25))
        XCTAssertFalse(MapPresentation.shouldRefit(current: 100, needed: 129))
        XCTAssertFalse(MapPresentation.shouldRefit(current: 100, needed: 71))
        XCTAssertTrue(MapPresentation.shouldRefit(current: 100, needed: 131))
        XCTAssertTrue(MapPresentation.shouldRefit(current: 100, needed: 69))
    }

    func testRecenter() {
        XCTAssertFalse(MapPresentation.shouldRecenter(moved: 5, span: 25))
        XCTAssertTrue(MapPresentation.shouldRecenter(moved: 7, span: 25))
    }

    func testInconsistencyThreshold() {
        // Short links: 1 m slack.
        XCTAssertFalse(MapPresentation.isInconsistent(drawn: 3.9, measured: 3))
        XCTAssertTrue(MapPresentation.isInconsistent(drawn: 4.1, measured: 3))
        XCTAssertTrue(MapPresentation.isInconsistent(drawn: 1.9, measured: 3))
        // Long links: 30 %.
        XCTAssertFalse(MapPresentation.isInconsistent(drawn: 12.9, measured: 10))
        XCTAssertTrue(MapPresentation.isInconsistent(drawn: 13.1, measured: 10))
        XCTAssertTrue(MapPresentation.isInconsistent(drawn: 6.9, measured: 10))
    }

    func testAngleDifferenceWraps() {
        XCTAssertEqual(MapPresentation.angleDifference(350, 10), 20, accuracy: 1e-9)
        XCTAssertEqual(MapPresentation.angleDifference(10, 350), 20, accuracy: 1e-9)
        XCTAssertEqual(MapPresentation.angleDifference(90, 270), 180, accuracy: 1e-9)
        XCTAssertFalse(MapPresentation.shouldRotate(current: 358, heading: 1))
        XCTAssertTrue(MapPresentation.shouldRotate(current: 0, heading: 10))
    }

    func testStatusTitlesAreHonest() {
        XCTAssertEqual(MapPresentation.statusTitle(basis: .uwbRanged, ambiguous: false), "UWB-ranged")
        XCTAssertEqual(MapPresentation.statusTitle(basis: .bluetooth, ambiguous: false), "Bluetooth estimate")
        XCTAssertEqual(MapPresentation.statusTitle(basis: .bluetooth, ambiguous: true), "Bluetooth estimate · direction unknown")
        XCTAssertEqual(MapPresentation.statusTitle(basis: .gpsRefined, ambiguous: false), "GPS + UWB")
        XCTAssertEqual(MapPresentation.statusTitle(basis: .reported(.gps), ambiguous: false), "GPS")
        let reported = PositionSource.allCases.map { PositionBasis.reported($0) }
        let all: [PositionBasis] = [PositionBasis.gpsRefined, .uwbRanged, .bluetooth] + reported
        for basis in all {
            for ambiguous in [false, true] {
                XCTAssertFalse(MapPresentation.statusTitle(basis: basis, ambiguous: ambiguous).lowercased().contains("measured"))
            }
        }
    }

    func testRingCaption() {
        XCTAssertEqual(MapPresentation.ringCaption(label: "Otter 42", radius: 4.08), "Otter 42 · 4.1 m · direction unknown")
    }
}
