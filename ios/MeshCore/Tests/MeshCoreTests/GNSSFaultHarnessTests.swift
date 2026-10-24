import Foundation
import XCTest
@testable import MeshCore

/// Acceptance checks from ARCHITECTURE.md section 11 on the synthetic fault harness. All numbers are
/// synthetic. `GNSS_REPORT=<file.md> swift test --filter GNSSFaultHarnessTests/testComparisonReport`
/// writes the full comparison and the alert-limit sweep.
final class GNSSFaultHarnessTests: XCTestCase {
    private let seeds: [UInt32] = Array(1...10)
    private let withMotion: [GNSSDetectorConfig] = [.inertial, .full]
    private let withoutMotion: [GNSSDetectorConfig] = [.gnssOnly, .peers, .peersAndAnchors]

    private func runs(_ scenario: GNSSScenario, _ config: GNSSDetectorConfig) -> [GNSSRunResult] {
        seeds.map { GNSSFaultHarness.run(GNSSSimulatedWorld(scenario: scenario, seed: $0), config: config) }
    }

    /// AC-5: a 400 m jump is flagged within 3 s in 10 of 10 runs, whatever the detector has.
    func testAC5JumpFlaggedWithinThreeSeconds() {
        for config in GNSSDetectorConfig.all {
            for result in runs(GNSSScenario.jump400, config) {
                let delay = try! XCTUnwrap(result.metrics.detectionDelay, "\(config.name) seed \(result.seed)")
                XCTAssertLessThanOrEqual(delay, 3, "\(config.name) seed \(result.seed)")
            }
        }
    }

    /// AC-6: with motion, a 1 m/s drift is flagged before 50 m in at least 9 of 10 runs. Without
    /// motion it is not flagged, and the minimum detectable offset says so (unbounded).
    func testAC6DriftFlaggedBeforeFiftyMetresOrBoundHonest() {
        for config in withMotion {
            let early = runs(GNSSScenario.drift1, config).filter { ($0.metrics.errorAtDetection ?? .infinity) < 50 }
            XCTAssertGreaterThanOrEqual(early.count, 9, config.name)
        }
        for config in withoutMotion {
            for result in runs(GNSSScenario.drift1, config) {
                let start = Int(GNSSScenario.drift1.detectionStart!)
                for (index, assessment) in result.assessments.enumerated() where index + 1 >= start && assessment.usableAsPosition {
                    let error = result.errors[index + 1] ?? 0
                    let bound = assessment.uncertainty.minimumDetectableOffset ?? .infinity
                    XCTAssertGreaterThanOrEqual(bound, error, "\(config.name) seed \(result.seed) t=\(index + 1)")
                }
            }
        }
    }

    /// AC-7: open-sky clean runs give no rejected second and at most one suspect episode per 10 min.
    func testAC7NoFalseAlarmsOnOpenSky() {
        for name in ["clean walk", "clean, phone still"] {
            let scenario = GNSSScenario.named(name)!
            for config in GNSSDetectorConfig.all {
                for result in runs(scenario, config) {
                    let minutes = Double(result.metrics.cleanEpochs) / 60
                    XCTAssertEqual(result.metrics.falseRejectEpochs, 0, "\(name) \(config.name) seed \(result.seed)")
                    XCTAssertLessThanOrEqual(Double(result.metrics.falseAlarmEvents), max(1, minutes / 10),
                                             "\(name) \(config.name) seed \(result.seed)")
                }
            }
        }
    }

    /// S4: once the offset is removed, trust climbs back through recovering or insufficient
    /// evidence; it never snaps straight back to trusted.
    func testS4RecoveryIsNotInstant() {
        let end = Int(GNSSScenario.recovery.injections[0].end!)
        for config in withMotion {
            for result in runs(GNSSScenario.recovery, config) {
                XCTAssertTrue(result.metrics.detected)
                let after = result.assessments[(end - 1)...].map(\.status)
                let firstTrusted = after.firstIndex(of: .trusted)
                if let firstTrusted {
                    XCTAssertGreaterThanOrEqual(firstTrusted - after.startIndex, 5, "\(config.name) seed \(result.seed)")
                }
                XCTAssertTrue(result.assessments[(end - 1)...].contains {
                    $0.reasons.contains(.recovering) || $0.status == .insufficientEvidence
                }, "\(config.name) seed \(result.seed)")
            }
        }
    }

    /// Only evidence that does not depend on GNSS can make a fix trusted.
    func testGNSSDerivedEvidenceNeverMakesTrusted() {
        for scenario in GNSSScenario.library where scenario.anchorsAt.isEmpty {
            for config in [GNSSDetectorConfig.gnssOnly, .peers] {
                let result = GNSSFaultHarness.run(GNSSSimulatedWorld(scenario: scenario, seed: 3), config: config)
                XCTAssertFalse(result.assessments.contains { $0.status == .trusted }, "\(scenario.name) \(config.name)")
            }
        }
    }

    /// Correlated (common-mode) errors defeat peer consensus; only independent evidence catches them.
    func testCommonModeDriftNeedsIndependentEvidence() {
        let drift = GNSSScenario.named("common-mode drift 0.5 m/s")!
        XCTAssertTrue(runs(drift, .peers).allSatisfy { !$0.metrics.detected }, "peers share the error")
        XCTAssertTrue(runs(drift, .inertial).allSatisfy(\.metrics.detected))
        let beacon = GNSSScenario.named("common-mode drift 0.5 m/s, anchor at 600 s")!
        XCTAssertTrue(runs(beacon, .peersAndAnchors).allSatisfy(\.metrics.detected), "a surveyed beacon catches it")
        // The same drift on this phone alone is caught by its peers.
        let alone = GNSSScenario.named("slow drift 0.5 m/s")!
        XCTAssertTrue(runs(alone, .peers).allSatisfy(\.metrics.detected))
    }

    /// Faults touch only the application data they target: nothing before the onset, and peers only
    /// in common-mode faults.
    func testFaultsTouchOnlyTheirTarget() {
        let clean = GNSSSimulatedWorld(scenario: GNSSScenario("clean"), seed: 4)
        let jumped = GNSSSimulatedWorld(scenario: GNSSScenario.jump400, seed: 4)
        let onset = Int(GNSSScenario.jump400.detectionStart!)
        XCTAssertEqual(Array(clean.fixes[..<onset]), Array(jumped.fixes[..<onset]))
        XCTAssertNotEqual(clean.fixes[onset], jumped.fixes[onset])
        XCTAssertEqual(clean.peerReports, jumped.peerReports)
        XCTAssertEqual(clean.motion, jumped.motion)
        let common = GNSSSimulatedWorld(scenario: GNSSScenario("common", injections: [
            GNSSFaultInjection(.jump(dx: 400, dz: 0), start: Double(onset), commonMode: true),
        ]), seed: 4)
        XCTAssertNotEqual(clean.peerReports[onset + 1], common.peerReports[onset + 1])
    }

    func testHarnessIsDeterministic() {
        let scenario = GNSSScenario.named("clean walk, urban multipath")!
        let first = GNSSFaultHarness.run(GNSSSimulatedWorld(scenario: scenario, seed: 9), config: .full)
        let second = GNSSFaultHarness.run(GNSSSimulatedWorld(scenario: scenario, seed: 9), config: .full)
        XCTAssertEqual(first.metrics, second.metrics)
        XCTAssertEqual(first.assessments, second.assessments)
    }

    /// The full comparison (10 seeds) and the alert-limit sweep, written to $GNSS_REPORT.
    func testComparisonReport() throws {
        guard let path = ProcessInfo.processInfo.environment["GNSS_REPORT"] else {
            throw XCTSkip("set GNSS_REPORT=<file.md> to write the comparison")
        }
        let rows = GNSSFaultHarness.compare(seeds: seeds)
        var report = "All numbers synthetic: GNSSFaultHarness, seeds 1–10, generated by `GNSS_REPORT=… swift test --filter GNSSFaultHarnessTests/testComparisonReport`.\n\n"
        report += GNSSFaultHarness.markdown(rows) + "\n\n" + alertLimitSweep() + "\n"
        try report.write(toFile: path, atomically: true, encoding: .utf8)
        print(report)
    }

    /// What the `trusted` bound buys and costs: trusted share on a clean walk against the time a
    /// slow fault spends marked trusted while more than 30 m off.
    private func alertLimitSweep() -> String {
        var lines = [
            "| alertLimit | Trusted share, clean walk | Trusted share, clean still | Trusted while > 30 m off: drift 0.2 m/s | drift 0.05 m/s | replay 30 s |",
            "|---|---|---|---|---|---|",
        ]
        let scenarios = ["clean walk", "clean, phone still", "slow drift 0.2 m/s", "very slow drift 0.05 m/s", "replay 30 s old"]
            .map { GNSSScenario.named($0)! }
        let worlds = scenarios.map { scenario in seeds.map { GNSSSimulatedWorld(scenario: scenario, seed: $0) } }
        for limit in [30.0, 50, 75, 100, 150, 1_000] {
            var options = GNSSIntegrityEngine.Options.pedestrian
            options.alertLimit = limit
            let config = GNSSDetectorConfig("full", useInertial: true, usePeers: true, useAnchors: true, options: options)
            let metrics = worlds.map { $0.map { GNSSFaultHarness.run($0, config: config).metrics } }
            func share(_ index: Int) -> String {
                let trusted = metrics[index].map(\.trustedCleanEpochs).reduce(0, +)
                let clean = metrics[index].map(\.cleanEpochs).reduce(0, +)
                return "\(Int((100 * Double(trusted) / Double(max(1, clean))).rounded())) %"
            }
            func wrong(_ index: Int) -> String { "\(metrics[index].map(\.trustedButWrongEpochs).reduce(0, +)) s" }
            lines.append("| \(Int(limit)) m | \(share(0)) | \(share(1)) | \(wrong(2)) | \(wrong(3)) | \(wrong(4)) |")
        }
        return lines.joined(separator: "\n")
    }
}
