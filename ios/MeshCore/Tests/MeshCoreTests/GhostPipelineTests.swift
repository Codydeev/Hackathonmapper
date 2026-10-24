import Foundation
import XCTest
import MeshCore

/// Ghost Mode plugged into the integration pipeline, on the contract scenarios (synthetic).
final class GhostPipelineTests: XCTestCase {
    func testContractScenariosHoldWithGhostPrediction() throws {
        let folder = ScenarioTests.folder
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertFalse(names.isEmpty)
        for name in names {
            let scenario = try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: folder.appendingPathComponent(name)))
            let report = ScenarioWorld(scenario: scenario, prediction: { id, frame in
                GhostPredictor(producerId: id, frameId: frame)
            }).run()
            print(report.table)
            XCTAssertEqual(report.gateFailures, [], "\(scenario.id): \(report.gateFailures.map(\.id))")
        }
    }
}
