import Foundation
import XCTest
import MeshCore

/// Known geometry for the joint solver: exact ranges are met, a biased range is shrugged off, a
/// single range leaves the direction open, and a bearing closes it.
final class LayoutSolverTests: XCTestCase {
    private typealias Solver = LayoutSolver

    private func distance(_ p: FloorPoint?, _ q: FloorPoint?) -> Double {
        guard let p, let q else { return .infinity }
        return hypot(p.x - q.x, p.z - q.z)
    }

    private let triangle = ["a": FloorPoint(x: 0, z: 0), "b": FloorPoint(x: 10, z: 0), "c": FloorPoint(x: 5, z: 8)]

    private func pinned(_ points: [String: FloorPoint], sigma: Double) -> [Solver.Prior] {
        points.keys.sorted().map { Solver.Prior(id: $0, point: points[$0]!, sigma: sigma) }
    }

    func testExactRangesFindThePoint() {
        let truth = FloorPoint(x: 4, z: 3)
        var start = triangle
        start["x"] = FloorPoint(x: 1, z: 1)
        let ranges = triangle.keys.sorted().map { Solver.Range(a: $0, b: "x", distance: distance(triangle[$0], truth)) }
        let solution = Solver.solve(Solver.Problem(start: start, priors: pinned(triangle, sigma: 0.01), ranges: ranges))
        XCTAssertLessThan(distance(solution.points["x"], truth), 1e-3)
        XCTAssertLessThan(solution.sigma("x") ?? .infinity, 0.5)
    }

    func testBiasedRangeIsDownWeighted() {
        let square = ["a": FloorPoint(x: 0, z: 0), "b": FloorPoint(x: 10, z: 0),
                      "c": FloorPoint(x: 10, z: 10), "d": FloorPoint(x: 0, z: 10)]
        let truth = FloorPoint(x: 3, z: 4)
        var start = square
        start["x"] = FloorPoint(x: 5, z: 5)
        // c's signal goes through a body: 3 m too long.
        let ranges = square.keys.sorted().map { id in
            Solver.Range(a: id, b: "x", distance: distance(square[id], truth) + (id == "c" ? 3 : 0))
        }
        let solution = Solver.solve(Solver.Problem(start: start, priors: pinned(square, sigma: 0.01), ranges: ranges))
        XCTAssertLessThan(distance(solution.points["x"], truth), 0.5)
    }

    func testOneRangeLeavesTheDirectionOpen() {
        let solution = Solver.solve(Solver.Problem(
            start: ["a": FloorPoint(x: 0, z: 0), "x": FloorPoint(x: 1, z: 0.5)],
            priors: [Solver.Prior(id: "a", point: FloorPoint(x: 0, z: 0), sigma: 0.3)],
            ranges: [Solver.Range(a: "a", b: "x", distance: 4)]))
        XCTAssertEqual(distance(solution.points["x"], solution.points["a"]), 4, accuracy: 1e-3)
        XCTAssertGreaterThan(solution.relativeSigma("x", "a") ?? 0, 10)
    }

    func testBearingFixesTheDirection() {
        let truth = FloorPoint(x: 3, z: 4)
        // Start on the wrong side: the bearing has to swing the phone round.
        for start in [FloorPoint(x: 1, z: 0), FloorPoint(x: -3, z: -4)] {
            let solution = Solver.solve(Solver.Problem(
                start: ["a": FloorPoint(x: 0, z: 0), "x": start],
                priors: [Solver.Prior(id: "a", point: FloorPoint(x: 0, z: 0), sigma: 0.3)],
                ranges: [Solver.Range(a: "a", b: "x", distance: 5)],
                bearings: [Solver.Bearing(from: "a", to: "x",
                                          bearing: LinkBearing(degrees: atan2(3, 4) * 180 / Double.pi, errorDegrees: 5))]))
            XCTAssertLessThan(distance(solution.points["x"], truth), 0.01)
            XCTAssertLessThan(solution.relativeSigma("x", "a") ?? .infinity, 1)
        }
    }

    func testRSSIRangeInLogDistance() {
        let radio = RadioModel.outdoors
        let solution = Solver.solve(Solver.Problem(
            start: ["a": FloorPoint(x: 0, z: 0), "x": FloorPoint(x: 3, z: 0)],
            priors: [Solver.Prior(id: "a", point: FloorPoint(x: 0, z: 0), sigma: 0.3)],
            signals: [Solver.Signal(a: "a", b: "x", rssi: radio.expectedRSSI(atDistance: 10))],
            radio: radio))
        XCTAssertEqual(distance(solution.points["x"], solution.points["a"]), 10, accuracy: 0.01)
    }

    func testRangeHoldsBetweenTwoLooseGPSFixes() {
        // GPS puts two phones 16.8 m apart; UWB says 3 m.
        let a = FloorPoint(x: -6, z: 3), b = FloorPoint(x: 10, z: -2)
        let solution = Solver.solve(Solver.Problem(
            start: ["a": a, "b": b],
            priors: [Solver.Prior(id: "a", point: a, sigma: 8), Solver.Prior(id: "b", point: b, sigma: 8)],
            ranges: [Solver.Range(a: "a", b: "b", distance: 3)]))
        XCTAssertEqual(distance(solution.points["a"], solution.points["b"]), 3, accuracy: 0.05)
        // They meet in the middle; how the pair is turned is not known.
        let pa = solution.points["a"]!, pb = solution.points["b"]!
        XCTAssertEqual((pa.x + pb.x) / 2, 2, accuracy: 0.05)
        XCTAssertEqual((pa.z + pb.z) / 2, 0.5, accuracy: 0.05)
        XCTAssertGreaterThan(solution.relativeSigma("a", "b") ?? 0, 3)
    }

    func testEmptyProblem() {
        let solution = Solver.solve(Solver.Problem(start: [:]))
        XCTAssertTrue(solution.points.isEmpty)
        XCTAssertNil(solution.sigma("x"))
    }
}
