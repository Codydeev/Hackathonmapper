import Foundation
import XCTest
import MeshCore

/// Known-geometry checks matching website/scripts/estimator-check.ts: three placed neighbours pin
/// a phone down, one leaves only a ring, and uncertainty grows with every Bluetooth hop.
final class BluetoothEstimatorTests: XCTestCase {
    private struct Point {
        let x: Double
        let z: Double
    }

    private struct Outcome {
        let error: Double
        let r95: Double
        let hops: Int?
    }

    /// mulberry32, as in the check script, for repeatable RSSI noise.
    private struct Noise {
        var state: UInt32
        mutating func next() -> Double {
            state = state &+ 0x6d2b_79f5
            var t = state
            t = (t ^ (t >> 15)) &* (t | 1)
            t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }
        mutating func gauss() -> Double {
            (-2 * log(max(next(), 1e-12))).squareRoot() * cos(2 * Double.pi * next())
        }
    }

    /// Runs `seconds` of updates with realistic RSSI noise and returns the last estimate of `target`.
    /// With `gpsUntil`, the lost phones are anchors (had GPS) for that many seconds first.
    private func run(anchors: [String: Point], lost: [String: Point], target: String, seed: UInt32,
                     seconds: Int = 60, gpsUntil: Int = 0) throws -> Outcome {
        let radio = RadioModel.outdoors
        var noise = Noise(state: seed)
        var options = BluetoothEstimator.Options()
        options.seed = seed + 1
        let estimator = BluetoothEstimator(options: options)
        let all = anchors.merging(lost) { first, _ in first }
        let ids = all.keys.sorted()
        var last: BluetoothEstimate?
        for t in 0..<seconds {
            var measurements: [LinkMeasurement] = []
            for i in ids.indices {
                for j in (i + 1)..<ids.count {
                    let a = all[ids[i]]!, b = all[ids[j]]!
                    let d = hypot(a.x - b.x, a.z - b.z)
                    if noise.next() > radio.hearProbability(atDistance: d) { continue }
                    let rssi = radio.expectedRSSI(atDistance: d) + radio.sigma * 0.8 * noise.gauss()
                    measurements.append(LinkMeasurement(a: ids[i], b: ids[j], rssi: rssi))
                }
            }
            let placed = (t < gpsUntil ? all : anchors).keys.sorted().map { id in
                EstimatorAnchor(id: id, x: all[id]!.x, z: all[id]!.z, accuracy: 5)
            }
            let unplaced = t < gpsUntil ? [] : lost.keys.sorted()
            last = estimator.update(anchors: placed, lost: unplaced, measurements: measurements)[target]
        }
        let estimate = try XCTUnwrap(last, "no estimate for \(target)")
        let truth = all[target]!
        return Outcome(error: hypot(estimate.x - truth.x, estimate.z - truth.z), r95: estimate.r95, hops: estimate.hops)
    }

    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    private func scenario(anchors: [String: Point], lost: [String: Point], target: String,
                          seconds: Int = 60, gpsUntil: Int = 0) throws -> (error: Double, r95: Double, inside: Double, hops: [Int?]) {
        let results = try (1...8).map { seed in
            try run(anchors: anchors, lost: lost, target: target, seed: UInt32(seed), seconds: seconds, gpsUntil: gpsUntil)
        }
        let inside = Double(results.filter { $0.error <= $0.r95 }.count) / Double(results.count)
        return (median(results.map(\.error)), median(results.map(\.r95)), inside, results.map(\.hops))
    }

    private let triangle = ["a": Point(x: 0, z: 0), "b": Point(x: 50, z: 0), "c": Point(x: 25, z: 45)]
    private let chainAnchors = ["a": Point(x: 0, z: 0), "b": Point(x: 0, z: 40)]
    private let chainLost = ["m": Point(x: 40, z: 20), "x": Point(x: 80, z: 20)]

    func testThreeAnchorsPinThePhoneDown() throws {
        let three = try scenario(anchors: triangle, lost: ["x": Point(x: 22, z: 15)], target: "x")
        XCTAssertLessThan(three.error, 15)
        XCTAssertGreaterThanOrEqual(three.inside, 0.7)
        XCTAssertTrue(three.hops.allSatisfy { $0 == 1 })
    }

    func testOneAnchorLeavesARing() throws {
        let three = try scenario(anchors: triangle, lost: ["x": Point(x: 22, z: 15)], target: "x")
        let one = try scenario(anchors: ["a": Point(x: 0, z: 0)], lost: ["x": Point(x: 35, z: 10)], target: "x")
        XCTAssertGreaterThanOrEqual(one.r95, 2 * three.r95)
    }

    func testSecondHopIsLessCertain() throws {
        let three = try scenario(anchors: triangle, lost: ["x": Point(x: 22, z: 15)], target: "x")
        let chain = try scenario(anchors: chainAnchors, lost: chainLost, target: "x")
        XCTAssertGreaterThan(chain.r95, three.r95)
        // X is 82 m from both anchors: some seconds it hears one directly, some seconds nobody.
        XCTAssertTrue(chain.hops.contains(2))
    }

    func testPhoneThatHadGPSStaysPlaced() throws {
        let lostLater = try scenario(anchors: chainAnchors, lost: chainLost, target: "x", seconds: 80, gpsUntil: 20)
        XCTAssertLessThan(lostLater.error, 20)
        XCTAssertGreaterThanOrEqual(lostLater.inside, 0.7)
    }

    func testPhoneWithoutAnyLinkGetsNoEstimate() {
        let estimator = BluetoothEstimator()
        let result = estimator.update(anchors: [EstimatorAnchor(id: "a", x: 0, z: 0, accuracy: 3)],
                                      lost: ["x"], measurements: [])
        XCTAssertNil(result["x"])
    }

    func testRadioModelDistanceRoundTrip() {
        let radio = RadioModel.outdoors
        for d in [1.0, 5, 20, 60] {
            XCTAssertEqual(radio.distance(forRSSI: radio.expectedRSSI(atDistance: d)), d, accuracy: 1e-9)
        }
        XCTAssertEqual(radio.hearProbability(atDistance: radio.range), 0.5, accuracy: 1e-12)
    }

    // MARK: Input from mesh reports

    private let epoch = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    private func report(_ id: String, source: PositionSource?, x: Double = 0, z: Double = 0,
                        accuracy: Double? = nil, neighbors: [NeighborObservation]) -> DeviceUpdate {
        DeviceUpdate(id: id, epochId: epoch, sequence: 1, role: "mobile", position: Position(x: x, y: 0, z: z),
                     positionMode: "floor", accuracyMeters: accuracy, neighbors: neighbors, positionSource: source)
    }

    func testInputSplitsPlacedAndLostPhones() {
        let now = Date()
        let reports = [
            report("gps", source: .gps, x: 3, z: 4, accuracy: 6, neighbors: []),
            report("old", source: nil, x: 1, z: 2, neighbors: []),
            report("lost", source: PositionSource.none, neighbors: []),
            report("gone", source: .gps, neighbors: []),
        ]
        let receivedAt = ["gps": now, "old": now, "lost": now, "gone": now.addingTimeInterval(-60)]
        let input = BluetoothEstimator.input(reports: reports, receivedAt: receivedAt, now: now,
                                             reportMaxAge: 15, linkMaxAge: 6)
        XCTAssertEqual(input.anchors, [
            EstimatorAnchor(id: "gps", x: 3, z: 4, accuracy: 6),
            EstimatorAnchor(id: "old", x: 1, z: 2, accuracy: nil),
        ])
        XCTAssertEqual(input.lost, ["lost"])
    }

    func testInputAveragesBothEndsAndDropsOldLinks() {
        let now = Date()
        let reports = [
            report("a", source: .gps, neighbors: [NeighborObservation(id: "b", rssi: -60, ageMs: 500),
                                                  NeighborObservation(id: "c", rssi: nil, ageMs: 0)]),
            report("b", source: PositionSource.none, neighbors: [NeighborObservation(id: "a", rssi: -70, ageMs: 0),
                                                                 NeighborObservation(id: "c", rssi: -80, ageMs: 5_000)]),
            report("c", source: .gps, neighbors: []),
        ]
        // b's report is 2 s old, so its 5 s old link to c is past the 6 s limit.
        let receivedAt = ["a": now, "b": now.addingTimeInterval(-2), "c": now]
        let input = BluetoothEstimator.input(reports: reports, receivedAt: receivedAt, now: now,
                                             reportMaxAge: 15, linkMaxAge: 6)
        XCTAssertEqual(input.measurements, [LinkMeasurement(a: "a", b: "b", rssi: -65)])
    }
}
