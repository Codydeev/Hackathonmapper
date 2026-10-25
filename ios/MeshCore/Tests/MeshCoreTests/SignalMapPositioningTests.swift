import Foundation
import XCTest
@testable import MeshCore

/// The signal map in GhostCore's positioning slot: the app's main map places lost phones the way
/// the dashboard and the Track tab do, UWB distances included (docs/AUDIT.md §1.1).
final class SignalMapPositioningTests: XCTestCase {
    private let t0 = 1_793_000_000.0
    private let radio = RadioModel.standard

    private func anchor(_ id: String, x: Double, z: Double, r95: Double, kind: PositionEstimate.Kind = .declared) -> PositionEstimate {
        let measured = kind == .measured
        return PositionEstimate(subjectId: id, timestamp: t0, frameId: "hervanta-v1", kind: kind,
                                method: measured ? .gnss : .manual, position: Position(x: x, y: 0, z: z),
                                uncertainty: PositionUncertainty(r95: r95), source: measured ? .gnss : .manual,
                                freshness: Freshness(maxAge: 15),
                                provenance: Provenance(producerId: id, algorithm: "mesh-report@1", gnssDependent: measured))
    }

    private func engine() -> SignalMapPositioning {
        SignalMapPositioning(producerId: "phone-me", frameId: "hervanta-v1")
    }

    /// One GPS phone and a lost phone 3 m away by UWB whose RSSI reads 8 m: the lost phone is on a
    /// ring of the UWB radius around it, shown as ambiguous, never as a confident spot.
    func testUWBDistanceGivesARingAroundOneAnchor() throws {
        let placed = engine().place(
            anchors: [anchor("gps", x: 10, z: 20, r95: 15, kind: .measured)], lost: ["lost"],
            links: [LinkMeasurement(a: "gps", b: "lost", rssi: radio.expectedRSSI(atDistance: 8), uwb: 3)],
            observations: [], now: t0)
        let estimate = try XCTUnwrap(placed.first)
        XCTAssertEqual(estimate.subjectId, "lost")
        XCTAssertNoThrow(try estimate.validate())
        XCTAssertEqual(estimate.kind, .estimated)
        XCTAssertEqual(estimate.method, .multilateration)
        XCTAssertEqual(estimate.source, .uwb)
        XCTAssertTrue(estimate.uncertainty.ambiguous)
        let p = try XCTUnwrap(estimate.position)
        XCTAssertEqual(hypot(p.x - 10, p.z - 20), 3, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(estimate.uncertainty.r95, 3)
        XCTAssertTrue(estimate.provenance.contributors.contains("gps"))
    }

    /// Two typed anchors 10 m apart fix the group in the world: a point, not a ring.
    func testTwoAnchorsPlaceAPointFromRSSI() throws {
        let truth: [String: (Double, Double)] = ["a1": (0, 0), "a2": (10, 0), "p": (4, 3)]
        func measured(_ a: String, _ b: String) -> LinkMeasurement {
            LinkMeasurement(a: a, b: b, rssi: radio.expectedRSSI(atDistance: hypot(truth[a]!.0 - truth[b]!.0, truth[a]!.1 - truth[b]!.1)))
        }
        let placed = engine().place(anchors: [anchor("a1", x: 0, z: 0, r95: 0.5), anchor("a2", x: 10, z: 0, r95: 0.5)],
                                    lost: ["p"], links: [measured("a1", "p"), measured("a2", "p")], observations: [], now: t0)
        let estimate = try XCTUnwrap(placed.first)
        XCTAssertEqual(estimate.source, .bluetooth)
        XCTAssertFalse(estimate.uncertainty.ambiguous)
        let p = try XCTUnwrap(estimate.position)
        // Two anchors leave a mirror image across their line; either is a correct reading.
        XCTAssertEqual(min(hypot(p.x - 4, p.z - 3), hypot(p.x - 4, p.z + 3)), 0, accuracy: 0.2)
    }

    /// No estimate without a way to an anchor: unlinked, or linked only to other lost phones.
    func testNoEstimateWithoutAPathToAnAnchor() {
        let placed = engine().place(anchors: [anchor("a", x: 0, z: 0, r95: 1)], lost: ["alone", "p", "q"],
                                    links: [LinkMeasurement(a: "p", b: "q", rssi: -65, uwb: 2)], observations: [], now: t0)
        XCTAssertTrue(placed.isEmpty)
    }

    /// Wire v5 reports through the whole pipeline: the UWB distances in `neighbors` reach the
    /// engine, and the lost phone is selected on its ring.
    func testPipelineCarriesUWBDistancesFromReports() throws {
        let p = GhostCorePipeline(configuration: .init(selfId: "phone-me", frameId: "hervanta-v1"),
                                  positioning: engine())
        func report(_ id: String, _ source: PositionSource, x: Double, neighbors: [NeighborObservation]) -> DeviceUpdate {
            DeviceUpdate(id: id, epochId: UUID().uuidString, sequence: 1, role: "mobile",
                         position: Position(x: x, y: 0, z: 0), positionMode: "floor", accuracyMeters: 5,
                         neighbors: neighbors, positionSource: source)
        }
        p.ingest(report: report("phone-g", .gps, x: 20, neighbors: [NeighborObservation(id: "phone-l", rssi: -82, ageMs: 0, uwbDistanceM: 3.02)]),
                 receivedAt: t0)
        p.ingest(report: report("phone-l", .none, x: 0, neighbors: [NeighborObservation(id: "phone-g", rssi: -82, ageMs: 0, uwbDistanceM: 2.98)]),
                 receivedAt: t0)
        let output = p.step(now: t0 + 1)
        let link = try XCTUnwrap(output.links.first)
        XCTAssertEqual(link.uwb ?? 0, 3, accuracy: 1e-9)
        let lost = try XCTUnwrap(output.phones.first { $0.id == "phone-l" }?.selected)
        XCTAssertEqual(lost.method, .multilateration)
        XCTAssertEqual(lost.source, .uwb)
        let position = try XCTUnwrap(lost.position)
        XCTAssertEqual(hypot(position.x - 20, position.z), 3, accuracy: 0.01)
    }

    /// A fused phone is an estimate, never an anchor, so a phone hearing only it stays unplaced.
    func testFusedPhoneDoesNotAnchor() {
        let p = GhostCorePipeline(configuration: .init(selfId: "phone-me", frameId: "hervanta-v1"),
                                  positioning: engine())
        p.ingest(report: DeviceUpdate(id: "phone-f", epochId: UUID().uuidString, sequence: 1, role: "mobile",
                                      position: Position(x: 5, y: 0, z: 0), positionMode: "floor", accuracyMeters: 4,
                                      positionSource: .fused), receivedAt: t0)
        p.ingest(report: DeviceUpdate(id: "phone-l", epochId: UUID().uuidString, sequence: 1, role: "mobile",
                                      position: Position(x: 0, y: 0, z: 0), positionMode: "floor",
                                      neighbors: [NeighborObservation(id: "phone-f", rssi: -65, ageMs: 0)],
                                      positionSource: PositionSource.none), receivedAt: t0)
        XCTAssertNil(p.step(now: t0 + 1).phones.first { $0.id == "phone-l" }?.estimate)
    }

    /// Both ends' UWB distances average into the pair's link; RSSI-only reports leave it nil.
    func testEstimatorInputAveragesUWBPerPair() {
        func report(_ id: String, _ neighbors: [NeighborObservation]) -> DeviceUpdate {
            DeviceUpdate(id: id, epochId: UUID().uuidString, sequence: 1, role: "mobile",
                         position: Position(x: 0, y: 0, z: 0), positionMode: "floor", neighbors: neighbors,
                         positionSource: PositionSource.none)
        }
        let now = Date(timeIntervalSince1970: t0)
        let input = BluetoothEstimator.input(
            reports: [report("a", [NeighborObservation(id: "b", rssi: -60, uwbDistanceM: 2.0),
                                   NeighborObservation(id: "c", rssi: -70)]),
                      report("b", [NeighborObservation(id: "a", rssi: -62, uwbDistanceM: 2.2)])],
            receivedAt: ["a": now, "b": now], now: now, reportMaxAge: 15, linkMaxAge: 6)
        let ab = input.measurements.first { $0.a == "a" && $0.b == "b" }
        XCTAssertEqual(ab?.rssi ?? 0, -61, accuracy: 1e-9)
        XCTAssertEqual(ab?.uwb ?? 0, 2.1, accuracy: 1e-9)
        XCTAssertNil(input.measurements.first { $0.a == "a" && $0.b == "c" }?.uwb)
    }
}
