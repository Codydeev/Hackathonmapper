import Foundation
import XCTest
@testable import MeshCore

final class SignalMapTests: XCTestCase {
    /// Written by `website/scripts/signalmap-check.ts --write-golden` from the TypeScript solver.
    private struct GoldenCase: Decodable {
        struct Input: Decodable {
            let ids: [String]
            let links: [SignalLink]
            let priors: [SignalPrior]
            let radio: RadioModel
            let previous: [String: FloorPoint]?
            let calibrate: Bool
        }

        let name: String
        let input: Input
        let output: SignalMapResult
    }

    private func goldenCases() throws -> [GoldenCase] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("signalmap-golden.json")
        return try JSONDecoder().decode([GoldenCase].self, from: Data(contentsOf: url))
    }

    private let radio = RadioModel.standard

    private func link(_ a: String, _ b: String, meters: Double) -> SignalLink {
        SignalLink(a: a, b: b, rssi: radio.expectedRSSI(atDistance: meters))
    }

    /// The phone and the dashboard must draw the same map from the same reports.
    func testMatchesTypeScriptGoldenCases() throws {
        let cases = try goldenCases()
        XCTAssertGreaterThanOrEqual(cases.count, 8)
        for golden in cases {
            let input = golden.input
            let result = SignalMap.solve(ids: input.ids, links: input.links, priors: input.priors, radio: input.radio,
                                         previous: input.previous, calibrate: input.calibrate)
            let expected = golden.output
            XCTAssertEqual(result.nodes.map(\.id), expected.nodes.map(\.id), golden.name)
            XCTAssertEqual(result.radio.p0, expected.radio.p0, accuracy: 1e-9, golden.name)
            XCTAssertEqual(result.radio.n, expected.radio.n, accuracy: 1e-9, golden.name)
            for (node, want) in zip(result.nodes, expected.nodes) {
                let label = "\(golden.name) \(node.id)"
                XCTAssertEqual(node.x, want.x, accuracy: 1e-6, label)
                XCTAssertEqual(node.z, want.z, accuracy: 1e-6, label)
                XCTAssertEqual(node.r95, want.r95, accuracy: 1e-6, label)
                XCTAssertEqual(node.placed, want.placed, label)
                XCTAssertEqual(node.hasPrior, want.hasPrior, label)
                XCTAssertEqual(node.component, want.component, label)
                XCTAssertEqual(node.frame, want.frame, label)
                XCTAssertEqual(node.degree, want.degree, label)
                XCTAssertEqual(node.ringCenter, want.ringCenter, label)
                XCTAssertEqual(node.ringRadius ?? -1, want.ringRadius ?? -1, accuracy: 1e-6, label)
                XCTAssertEqual(node.hops, want.hops, label)
            }
            XCTAssertEqual(result.links.count, expected.links.count, golden.name)
            for (edge, want) in zip(result.links, expected.links) {
                XCTAssertEqual(edge.a, want.a, golden.name)
                XCTAssertEqual(edge.b, want.b, golden.name)
                XCTAssertEqual(edge.measured, want.measured, accuracy: 1e-9, golden.name)
                XCTAssertEqual(edge.layout, want.layout, accuracy: 1e-6, golden.name)
            }
        }
    }

    func testRadioModelDistanceRoundTrip() {
        for d in [1.0, 2.5, 10, 40] {
            XCTAssertEqual(radio.distance(forRSSI: radio.expectedRSSI(atDistance: d)), d, accuracy: 1e-9)
        }
        XCTAssertEqual(SignalMap.range(forRSSI: 20, radio: radio), SignalMap.minDistance)
        XCTAssertEqual(SignalMap.range(forRSSI: -200, radio: radio), SignalMap.maxDistance)
        XCTAssertEqual(PathLossModel.default.exponent, radio.n)
    }

    /// Measured triangle without any placed phone: the map keeps every measured distance.
    func testRelativeLayoutKeepsMeasuredDistances() {
        let result = SignalMap.solve(ids: ["a", "b", "c"],
                                     links: [link("a", "b", meters: 3), link("a", "c", meters: 4), link("b", "c", meters: 5)],
                                     priors: [], radio: radio)
        for edge in result.links { XCTAssertEqual(edge.layout, edge.measured, accuracy: 0.01) }
        XCTAssertTrue(result.nodes.allSatisfy { $0.frame == .relative && $0.placed })
        let nodes = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.id, $0) })
        XCTAssertNil(SignalMap.placeInWorld(nodes["a"]!, nodes: nodes), "a relative map has no place in the world")
    }

    /// A ±20 m GPS phone 2 m from a fixed anchor is drawn 2 m from it, not where GPS put it.
    func testPlacedPhonesAgreeWithTheirBluetoothRanges() throws {
        let result = SignalMap.solve(
            ids: ["anchor", "gps", "lost"],
            links: [link("anchor", "gps", meters: 2), link("anchor", "lost", meters: 3), link("gps", "lost", meters: 3.6)],
            priors: [SignalPrior(id: "anchor", x: 0, z: 0, r95: 0.5), SignalPrior(id: "gps", x: 12, z: 6, r95: 20)],
            radio: radio)
        let nodes = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.id, $0) })
        let anchor = try XCTUnwrap(SignalMap.placeInWorld(nodes["anchor"]!, nodes: nodes))
        let gps = try XCTUnwrap(SignalMap.placeInWorld(nodes["gps"]!, nodes: nodes))
        let lost = try XCTUnwrap(SignalMap.placeInWorld(nodes["lost"]!, nodes: nodes))
        XCTAssertEqual(hypot(gps.x - anchor.x, gps.z - anchor.z), 2, accuracy: 0.3)
        XCTAssertEqual(hypot(lost.x - anchor.x, lost.z - anchor.z), 3, accuracy: 0.3)
        // One precise phone and a GPS phone 2 m away don't fix the orientation: rings, honestly.
        XCTAssertEqual(nodes["gps"]!.frame, .pinned)
        XCTAssertTrue(lost.ambiguous)
        XCTAssertEqual(lost.ringRadius ?? 0, 3, accuracy: 0.3)
        XCTAssertEqual(SignalMap.ringPoints(lost).count, 24)
        XCTAssertFalse(anchor.ambiguous)
    }

    /// Two fixed anchors 10 m apart anchor the group in the world.
    func testTwoAnchorsPlaceTheGroupInTheWorld() throws {
        let truth: [String: (Double, Double)] = ["a1": (0, 0), "a2": (10, 0), "p": (4, 3)]
        func measured(_ a: String, _ b: String) -> SignalLink {
            link(a, b, meters: hypot(truth[a]!.0 - truth[b]!.0, truth[a]!.1 - truth[b]!.1))
        }
        let result = SignalMap.solve(ids: ["a1", "a2", "p"], links: [measured("a1", "p"), measured("a2", "p")],
                                     priors: [SignalPrior(id: "a1", x: 0, z: 0, r95: 0.5), SignalPrior(id: "a2", x: 10, z: 0, r95: 0.5)],
                                     radio: radio)
        let nodes = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.id, $0) })
        let p = try XCTUnwrap(nodes["p"])
        XCTAssertEqual(p.frame, .world)
        XCTAssertEqual(p.hops, 1)
        let placed = try XCTUnwrap(SignalMap.placeInWorld(p, nodes: nodes))
        XCTAssertFalse(placed.ambiguous)
        // Two anchors leave a mirror image across their line; either is a correct reading.
        XCTAssertEqual(min(hypot(placed.x - 4, placed.z - 3), hypot(placed.x - 4, placed.z + 3)), 0, accuracy: 0.2)
    }

    func testUnlinkedPhoneWithoutPositionIsUnplaced() {
        let result = SignalMap.solve(ids: ["alone", "a", "b"], links: [link("a", "b", meters: 2)], priors: [], radio: radio)
        let alone = result.nodes.first { $0.id == "alone" }!
        XCTAssertFalse(alone.placed)
        XCTAssertNil(SignalMap.placeInWorld(alone, nodes: [:]))
        // One link gives a distance, not a direction.
        XCTAssertEqual(result.nodes.first { $0.id == "b" }!.ringCenter, "a")
    }

    /// A room frame whose +z points east: walking east is +z, walking north is -x.
    func testGeoFrameBearingTurnsTheFrame() {
        let origin = GeoFrame.Origin(latitude: 61.4499, longitude: 23.8560, bearingDegrees: 90)
        let meter = 1 / (6_371_008.8 * Double.pi / 180)
        let east = GeoFrame.project(origin, latitude: origin.latitude, longitude: origin.longitude + 10 * meter / cos(origin.latitude * Double.pi / 180))
        XCTAssertEqual(east.x, 0, accuracy: 1e-6)
        XCTAssertEqual(east.z, 10, accuracy: 1e-6)
        let north = GeoFrame.project(origin, latitude: origin.latitude + 10 * meter, longitude: origin.longitude)
        XCTAssertEqual(north.x, -10, accuracy: 1e-6)
        XCTAssertEqual(north.z, 0, accuracy: 1e-6)
        let back = GeoFrame.unproject(origin, x: north.x, z: north.z)
        XCTAssertEqual(back.latitude, origin.latitude + 10 * meter, accuracy: 1e-12)
        XCTAssertEqual(back.longitude, origin.longitude, accuracy: 1e-12)
        XCTAssertEqual(GeoFrame.forwardName(frameId: GeoFrame.defaultFrameId), "north (+z)")
        XCTAssertEqual(GeoFrame.axisNames(frameId: "room-without-origin").x, "right")
    }

    func testWarmStartKeepsTheMapStill() {
        let links = [link("a", "b", meters: 3), link("a", "c", meters: 4), link("b", "c", meters: 5), link("c", "d", meters: 2),
                     link("b", "d", meters: 4.5)]
        let first = SignalMap.solve(ids: ["a", "b", "c", "d"], links: links, priors: [], radio: radio)
        let previous = Dictionary(uniqueKeysWithValues: first.nodes.map { ($0.id, FloorPoint(x: $0.x, z: $0.z)) })
        let second = SignalMap.solve(ids: ["a", "b", "c", "d"], links: links, priors: [], radio: radio, previous: previous)
        for (a, b) in zip(first.nodes, second.nodes) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.01)
            XCTAssertEqual(a.z, b.z, accuracy: 0.01)
        }
    }
}
