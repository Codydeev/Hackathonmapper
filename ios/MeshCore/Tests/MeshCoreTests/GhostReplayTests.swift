import Foundation
import XCTest
import MeshCore

/// Runs every scenario in ghost/fixtures/ through the tracker (regenerate them with
/// `python3 -I ghost/fixtures/make_fixtures.py`).
final class GhostReplayTests: XCTestCase {
    private var fixtures: [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("ghost/fixtures")
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testAllScenariosMeetTheirChecks() throws {
        XCTAssertGreaterThanOrEqual(fixtures.count, 10, "ghost/fixtures/ not found next to the package")
        for url in fixtures {
            let result = GhostReplay.run(try GhostReplay.load(Data(contentsOf: url)))
            XCTAssertEqual(result.failures, [], url.lastPathComponent)
        }
    }

    /// While a phone stays out of sight, its area may only grow, and ages never run backwards.
    func testGhostAreasOnlyGrow() throws {
        for url in fixtures {
            let result = GhostReplay.run(try GhostReplay.load(Data(contentsOf: url)))
            for id in Set(result.samples.map(\.id)) {
                var previous: GhostReplayResult.Sample?
                for s in result.samples where s.id == id {
                    XCTAssertGreaterThanOrEqual(s.age, 0)
                    if let p = previous, p.status == .ghost, s.status == .ghost, s.age > p.age, let a = p.r95, let b = s.r95,
                       !url.lastPathComponent.contains("dead-reckoning"), !url.lastPathComponent.contains("standing") {
                        XCTAssertGreaterThanOrEqual(b, a - 1e-6, "\(url.lastPathComponent) \(id) t=\(s.t)")
                    }
                    previous = s
                }
            }
        }
    }

    func testDemoScenarioKeepsTheTruthInsideMostOfTheTime() throws {
        let url = try XCTUnwrap(fixtures.first { $0.lastPathComponent == "walk-out-of-range.json" })
        let result = GhostReplay.run(try GhostReplay.load(Data(contentsOf: url)))
        XCTAssertGreaterThanOrEqual(result.ghostSeconds, 80)
        XCTAssertGreaterThanOrEqual(result.ghostCoverageR95 ?? 0, 0.95)
    }
}
