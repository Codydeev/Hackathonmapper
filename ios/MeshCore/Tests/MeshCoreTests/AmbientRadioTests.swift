import Foundation
import XCTest
@testable import MeshCore

/// Ambient radio fingerprinting: keys, recording, matching and its failure modes on a synthetic
/// site, plus the guard that keeps the module out of GNSS integrity and positioning. All numbers
/// are synthetic. `AMBIENT_REPORT=<file.md> swift test --filter AmbientRadioTests/testEvaluationReport`
/// writes the evaluation table.
final class AmbientRadioTests: XCTestCase {
    static let meshService = "F7A40001-5AB1-4E90-A989-21B5E52E2210"

    /// A deterministic UUID from text, standing in for the identifiers iOS hands out.
    static func uuid(_ text: String) -> UUID {
        let hex = Array(AmbientEmitterKey.digest(text) + AmbientEmitterKey.digest(text + "#"))
        func part(_ range: Range<Int>) -> String { String(hex[range]) }
        return UUID(uuidString: "\(part(0..<8))-\(part(8..<12))-\(part(12..<16))-\(part(16..<20))-\(part(20..<32))")!
    }

    /// A building full of advertisers, and a phone listening in it.
    struct Site {
        enum Kind: String, CaseIterable {
            case beacon, tv, printer, applePhone, appleLaptop, androidPhone, earbuds

            /// Address rotation, as phones, laptops and earbuds do.
            var rotates: Bool { [.applePhone, .appleLaptop, .androidPhone, .earbuds].contains(self) }

            var advertisementClass: String {
                switch self {
                case .beacon: AmbientEmitterKey.advertisementClass(manufacturerData: nil, serviceUUIDs: ["FEAA"], connectable: false)
                case .tv: AmbientEmitterKey.advertisementClass(manufacturerData: Data([0x75, 0x00, 0x42]), serviceUUIDs: [], connectable: true)
                case .printer: AmbientEmitterKey.advertisementClass(manufacturerData: Data([0x65, 0x00, 0x01]), serviceUUIDs: [], connectable: true)
                case .applePhone: AmbientEmitterKey.advertisementClass(manufacturerData: Data([0x4c, 0x00, 0x10]), serviceUUIDs: [], connectable: true)
                case .appleLaptop: AmbientEmitterKey.advertisementClass(manufacturerData: Data([0x4c, 0x00, 0x0c]), serviceUUIDs: [], connectable: true)
                case .androidPhone: AmbientEmitterKey.advertisementClass(manufacturerData: Data([0x06, 0x00, 0x01]), serviceUUIDs: [], connectable: false)
                case .earbuds: AmbientEmitterKey.advertisementClass(manufacturerData: Data([0x4c, 0x00, 0x07]), serviceUUIDs: [], connectable: false)
                }
            }
        }

        struct Emitter {
            let name: String
            let kind: Kind
            let x: Double
            let z: Double
            /// dBm at 1 m.
            let p0: Double
            /// Seconds into its 15-minute rotation cycle at time 0.
            let phase: Double
            let shadowA: Double
            let shadowB: Double
        }

        static let watchClass = AmbientEmitterKey.advertisementClass(manufacturerData: Data([0x4c, 0x00, 0x0f]),
                                                                     serviceUUIDs: [], connectable: true)
        let radio = RadioModel(p0: -59, n: 2.5, sigma: 4, range: 35, soft: 5)
        let name: String
        let emitters: [Emitter]

        /// `rotatingOnly`: no beacons and no fixed-address devices, only phones, laptops and earbuds.
        init(name: String, seed: UInt32, size: Double = 100, rotatingOnly: Bool = false) {
            self.name = name
            var random = DeterministicRandom(seed: seed)
            let fixed: [Kind] = rotatingOnly ? [] : [.beacon, .beacon, .beacon, .beacon] + Array(repeating: .tv, count: 4)
                + Array(repeating: .printer, count: 3)
            let mix: [Kind] = fixed + Array(repeating: .applePhone, count: rotatingOnly ? 12 : 8)
                + Array(repeating: .appleLaptop, count: rotatingOnly ? 8 : 5) + Array(repeating: .androidPhone, count: rotatingOnly ? 6 : 4)
                + Array(repeating: .earbuds, count: 4)
            emitters = mix.enumerated().map { index, kind in
                Emitter(name: "\(name)-\(kind.rawValue)-\(index)", kind: kind, x: random.uniform(0, size), z: random.uniform(0, size),
                        p0: random.uniform(-65, -55), phase: random.uniform(0, 900),
                        shadowA: random.uniform(0, 2 * Double.pi), shadowB: random.uniform(0, 2 * Double.pi))
            }
        }

        /// What `device` knows an emitter as at `time`: beacons by their Eddystone UID, everything
        /// else by iOS's per-phone identifier, which changes whenever the emitter rotates.
        func key(_ emitter: Emitter, device: String, time: Double) -> AmbientEmitterKey {
            if emitter.kind == .beacon { return AmbientEmitterKey(kind: .eddystoneUID, value: AmbientEmitterKey.digest(emitter.name)) }
            let epoch = emitter.kind.rotates ? Int((time + emitter.phase) / 900) : 0
            return .ios(AmbientRadioTests.uuid("\(device)|\(emitter.name)|\(epoch)"))
        }

        /// Slow spatial variation (walls, furniture), about ±5 dB, different for each emitter.
        func shadow(_ emitter: Emitter, x: Double, z: Double) -> Double {
            5 * sin(x / 6 + emitter.shadowA) * cos(z / 8 + emitter.shadowB)
        }

        /// `seconds` of listening at (x, z) from `start`, two advertisements a second per emitter in
        /// range; with the user's own watch, a few people walking past, and a GhostCore peer.
        func listen(device: String, x: Double, z: Double, start: Double, seconds: Int, seed: UInt32,
                    passersBy: Int = 2, watch: Bool = true) -> AmbientSnapshot {
            var random = DeterministicRandom(seed: seed)
            var recorder = AmbientRecorder(excludedServices: [AmbientRadioTests.meshService])
            let body = 3 * random.gauss()
            let visit = emitters.map { _ in 2 * random.gauss() }
            let walkers = (0..<passersBy).map { index -> (x: Double, z: Double, dx: Double, dz: Double, key: AmbientEmitterKey) in
                let angle = random.uniform(0, 2 * Double.pi), side = random.uniform(2, 8), back = random.uniform(10, 25)
                return (x - back * sin(angle) + side * cos(angle), z - back * cos(angle) - side * sin(angle),
                        1.4 * sin(angle), 1.4 * cos(angle), .ios(AmbientRadioTests.uuid("\(device)|walker|\(seed)|\(index)")))
            }
            let watchKey = AmbientEmitterKey.ios(AmbientRadioTests.uuid("\(device)|watch|\(Int(start / 900))"))
            for second in 0..<seconds {
                for half in 0..<2 {
                    let t = start + Double(second) + 0.5 * Double(half) + 0.2 * random.next()
                    for (index, emitter) in emitters.enumerated() {
                        let d = hypot(emitter.x - x, emitter.z - z)
                        guard random.next() <= radio.hearProbability(atDistance: d) else { continue }
                        let rssi = emitter.p0 - 10 * radio.n * log10(max(0.5, d)) + shadow(emitter, x: x, z: z)
                            + visit[index] + body + 3 * random.gauss()
                        recorder.add(AmbientAdvertisement(time: t, emitter: key(emitter, device: device, time: t), rssi: rssi,
                                                          advertisementClass: emitter.kind.advertisementClass))
                    }
                    if watch {
                        recorder.add(AmbientAdvertisement(time: t, emitter: watchKey, rssi: -47 + 2 * random.gauss(),
                                                          advertisementClass: Self.watchClass))
                    }
                    for walker in walkers {
                        let elapsed = t - start
                        let d = hypot(walker.x + walker.dx * elapsed - x, walker.z + walker.dz * elapsed - z)
                        guard random.next() <= radio.hearProbability(atDistance: d) else { continue }
                        recorder.add(AmbientAdvertisement(time: t, emitter: walker.key,
                                                          rssi: -59 - 25 * log10(max(0.5, d)) + 3 * random.gauss(),
                                                          advertisementClass: Kind.applePhone.advertisementClass))
                    }
                    recorder.add(AmbientAdvertisement(time: t, emitter: .ios(AmbientRadioTests.uuid("peer")), rssi: -60,
                                                      serviceUUIDs: [AmbientRadioTests.meshService.lowercased()]))
                }
            }
            return recorder.snapshot(from: start, to: start + Double(seconds))
        }

        /// Records a 4 × 4 grid of spots 25 m apart, 20 s each, one after another from time 0.
        func recordGrid(device: String, seed: UInt32) -> FingerprintDatabase {
            var database = FingerprintDatabase()
            for (index, spot) in Self.grid.enumerated() {
                let snapshot = listen(device: device, x: spot.x, z: spot.z, start: Double(index) * 30, seconds: 20,
                                      seed: seed &+ UInt32(index))
                if case let .success(fingerprint) = RadioFingerprint.record(
                    snapshot, id: "spot-\(index)", label: "Spot \(index)", frameId: "site", x: spot.x, z: spot.z,
                    positionSource: .declared, positionR95: 2, recordedBy: device) {
                    database.add(fingerprint)
                }
            }
            return database
        }

        static let grid: [(x: Double, z: Double)] = [12.5, 37.5, 62.5, 87.5].flatMap { x in [12.5, 37.5, 62.5, 87.5].map { (x, $0) } }
    }

    // MARK: Keys and recording

    func testKeysKeepNothingReadable() {
        let identifier = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
        let key = AmbientEmitterKey.ios(identifier)
        XCTAssertEqual(key, .ios(identifier), "the same identifier gives the same key")
        XCTAssertFalse(key.value.contains("1234567890"))
        XCTAssertFalse(key.isPortable)

        var frame = Data([0x00, 0xEE])
        frame += Data((0..<16).map { UInt8($0) })
        let beacon = AmbientEmitterKey.best(identifier: identifier, serviceData: ["FEAA": frame])
        XCTAssertEqual(beacon.kind, .eddystoneUID)
        XCTAssertTrue(beacon.isPortable)
        XCTAssertEqual(beacon, AmbientEmitterKey.best(identifier: UUID(), serviceData: ["feaa": frame]), "same beacon on any phone")
        XCTAssertNil(AmbientEmitterKey.eddystoneUID(serviceData: Data([0x10, 0xEE, 0x00])), "URL frames are not identities")
        XCTAssertEqual(AmbientEmitterKey.best(identifier: identifier, serviceData: ["FEAA": Data([0x20])]), key)
    }

    func testAdvertisementClassIgnoresWhichDeviceSentIt() {
        let a = AmbientEmitterKey.advertisementClass(manufacturerData: Data([0x4c, 0x00, 0x10, 0x05, 0xAB]), serviceUUIDs: [], connectable: true)
        let b = AmbientEmitterKey.advertisementClass(manufacturerData: Data([0x4c, 0x00, 0x10, 0x07, 0x01]), serviceUUIDs: [], connectable: true)
        let other = AmbientEmitterKey.advertisementClass(manufacturerData: Data([0x4c, 0x00, 0x07]), serviceUUIDs: [], connectable: true)
        XCTAssertEqual(a, b, "the payload after the type byte (per-device and rotating) is ignored")
        XCTAssertNotEqual(a, other)
        XCTAssertFalse(a.contains("4c"), "manufacturer data is not kept in clear")
    }

    func testRecorderDropsPeersAndSummarises() {
        var recorder = AmbientRecorder(excludedServices: [Self.meshService])
        let tv = AmbientEmitterKey.ios(UUID()), passing = AmbientEmitterKey.ios(UUID())
        XCTAssertFalse(recorder.add(AmbientAdvertisement(time: 0, emitter: .ios(UUID()), rssi: -50,
                                                         serviceUUIDs: [Self.meshService.lowercased()])), "a GhostCore peer")
        XCTAssertFalse(recorder.add(AmbientAdvertisement(time: 0, emitter: tv, rssi: 127)), "no RSSI")
        for second in 0..<20 {
            recorder.add(AmbientAdvertisement(time: Double(second), emitter: tv, rssi: second.isMultiple(of: 2) ? -70 : -72,
                                              advertisementClass: "tv"))
            recorder.add(AmbientAdvertisement(time: Double(second), emitter: passing, rssi: -90 + 2 * Double(second),
                                              advertisementClass: "phone"))
        }
        XCTAssertEqual(recorder.emitterCount, 2)
        let snapshot = recorder.snapshot(from: 0, to: 20)
        let steady = snapshot.emitters.first { $0.emitter == tv }!
        XCTAssertEqual(steady.presence, 1)
        XCTAssertEqual(steady.rssi, -71)
        XCTAssertEqual(steady.trend, 0, accuracy: 0.2)
        XCTAssertEqual(snapshot.emitters.first { $0.emitter == passing }!.trend, 2, accuracy: 0.01)
        XCTAssertTrue(snapshot.emitters.contains { $0.emitter == AmbientEmitterKey(kind: .classRank, value: "tv#1") })
        recorder.prune(now: 200)
        XCTAssertEqual(recorder.emitterCount, 0)
    }

    func testRecordingKeepsOnlySteadyDevices() {
        let site = Site(name: "a", seed: 1)
        let snapshot = site.listen(device: "p1", x: 50, z: 50, start: 0, seconds: 20, seed: 7, passersBy: 3)
        let fingerprint = try! RadioFingerprint.record(snapshot, label: "Hall", frameId: "site", x: 50, z: 50,
                                                       positionSource: .declared, positionR95: 2, recordedBy: "p1").get()
        XCTAssertGreaterThanOrEqual(fingerprint.emitters.filter(\.emitter.isIdentity).count, 3)
        XCTAssertGreaterThan(fingerprint.unsteadyCount, 0, "passers-by are left out")
        XCTAssertTrue(fingerprint.emitters.allSatisfy { abs($0.trend) <= 0.4 && $0.presence >= 0.5 })

        let short = site.listen(device: "p1", x: 50, z: 50, start: 0, seconds: 8, seed: 7)
        XCTAssertEqual(RadioFingerprint.record(short, label: "x", frameId: "site", x: 0, z: 0, positionSource: .declared,
                                               positionR95: 2, recordedBy: "p1"), .failure(.tooShort))
        let empty = AmbientSnapshot(start: 0, end: 20, emitters: [])
        XCTAssertEqual(RadioFingerprint.record(empty, label: "x", frameId: "site", x: 0, z: 0, positionSource: .declared,
                                               positionR95: 2, recordedBy: "p1"), .failure(.tooFewSteadyDevices))
        XCTAssertEqual(RadioFingerprint.record(snapshot, label: "x", frameId: "site", x: .nan, z: 0, positionSource: .declared,
                                               positionR95: 2, recordedBy: "p1"), .failure(.invalidPosition))
    }

    func testDatabaseRoundTripAndTravellingDevices() throws {
        let site = Site(name: "a", seed: 2)
        let database = site.recordGrid(device: "p1", seed: 30)
        XCTAssertEqual(database.fingerprints.count, 16)
        let data = try database.encoded()
        XCTAssertEqual(try FingerprintDatabase.decode(data), database)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(Self.uuid("p1|a-tv-4|0").uuidString), "no raw identifiers stored")

        // The user's watch is strong at every spot: carried along, so never evidence of place.
        let travelling = database.travellingEmitters()
        XCTAssertTrue(travelling.contains { $0.kind == .classRank && $0.value.hasPrefix(Site.watchClass) })
        XCTAssertFalse(travelling.contains { $0.kind == .eddystoneUID }, "fixed beacons do not travel")

        var edited = database
        edited.remove(id: "spot-0")
        XCTAssertEqual(edited.fingerprints.count, 15)
    }

    // MARK: Matching

    func testMatchesTheRecordedSpot() {
        let site = Site(name: "a", seed: 3)
        let database = site.recordGrid(device: "p1", seed: 40)
        let spot = Site.grid[5]
        let snapshot = site.listen(device: "p1", x: spot.x, z: spot.z, start: 600, seconds: 15, seed: 99)
        let result = FingerprintMatcher().match(snapshot, in: database, frameId: "site", deviceId: "p1")
        XCTAssertTrue(result.isMatch, result.summary)
        XCTAssertEqual(result.candidates.first?.fingerprintId, "spot-5")
        XCTAssertGreaterThanOrEqual(result.r95!, 20)
        XCTAssertLessThanOrEqual(hypot(result.x! - spot.x, result.z! - spot.z), result.r95!)
        XCTAssertEqual(result.positionSource, .declared)
        XCTAssertTrue(result.summary.hasPrefix("Sounds like \"Spot 5\""), result.summary)
    }

    func testInsufficientEvidenceStates() {
        let site = Site(name: "a", seed: 4)
        let database = site.recordGrid(device: "p1", seed: 50)
        let matcher = FingerprintMatcher()
        let spot = Site.grid[0]
        let short = site.listen(device: "p1", x: spot.x, z: spot.z, start: 600, seconds: 5, seed: 1)
        XCTAssertEqual(matcher.match(short, in: database, frameId: "site", deviceId: "p1").reasons, [.windowTooShort])
        let snapshot = site.listen(device: "p1", x: spot.x, z: spot.z, start: 600, seconds: 15, seed: 1)
        XCTAssertEqual(matcher.match(snapshot, in: FingerprintDatabase(), frameId: "site", deviceId: "p1").reasons, [.noFingerprints])
        XCTAssertEqual(matcher.match(snapshot, in: database, frameId: "elsewhere", deviceId: "p1").reasons, [.noFingerprints])
        let quiet = AmbientSnapshot(start: 0, end: 15, emitters: Array(snapshot.emitters.filter(\.emitter.isIdentity).prefix(1)))
        XCTAssertEqual(matcher.match(quiet, in: database, frameId: "site", deviceId: "p1").reasons, [.tooFewEmittersHeard])

        // Another building: nothing recorded is heard there.
        let other = Site(name: "b", seed: 77)
        let away = other.listen(device: "p1", x: 50, z: 50, start: 600, seconds: 15, seed: 2)
        var devicesOnly = FingerprintMatcher.Options()
        devicesOnly.useClasses = false
        let result = FingerprintMatcher(options: devicesOnly).match(away, in: database, frameId: "site", deviceId: "p1")
        XCTAssertEqual(result.verdict, .insufficientEvidence)
        XCTAssertEqual(result.reasons, [.tooFewCommonEmitters])
        XCTAssertNil(result.x)
        XCTAssertTrue(result.summary.hasPrefix("Insufficient evidence"))
    }

    func testTwoSpotsThatSoundAlikeAreAmbiguous() {
        let summaries = (0..<5).map { index in
            AmbientEmitterSummary(emitter: AmbientEmitterKey(kind: .eddystoneUID, value: "b\(index)"), rssi: -80 - Double(index),
                                  spread: 2, presence: 1, samples: 30, trend: 0)
        }
        let snapshot = AmbientSnapshot(start: 0, end: 20, emitters: summaries)
        func spot(_ id: String, x: Double) -> RadioFingerprint {
            try! RadioFingerprint.record(snapshot, id: id, label: id, frameId: "site", x: x, z: 0, positionSource: .declared,
                                         positionR95: 1, recordedBy: "p1").get()
        }
        let far = FingerprintDatabase(fingerprints: [spot("west", x: 0), spot("east", x: 80)])
        XCTAssertEqual(FingerprintMatcher().match(snapshot, in: far, frameId: "site", deviceId: "p1").reasons, [.ambiguous])
        // Close together they merge: one answer, with a radius that covers both.
        let near = FingerprintDatabase(fingerprints: [spot("left", x: 0), spot("right", x: 8)])
        let merged = FingerprintMatcher().match(snapshot, in: near, frameId: "site", deviceId: "p1")
        XCTAssertTrue(merged.isMatch)
        XCTAssertEqual(merged.x!, 4, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(merged.r95!, 20 + 4)
    }

    func testSpotsFromAnotherPhoneUsePortableKeysOnly() {
        let site = Site(name: "a", seed: 5)
        let database = site.recordGrid(device: "p1", seed: 60)
        let spot = Site.grid[10]
        let snapshot = site.listen(device: "p2", x: spot.x, z: spot.z, start: 600, seconds: 15, seed: 3)
        let result = FingerprintMatcher().match(snapshot, in: database, frameId: "site", deviceId: "p2")
        XCTAssertTrue(result.candidates.allSatisfy { $0.commonDevices <= 4 }, "only the four beacons can be recognised")
        if result.isMatch { XCTAssertLessThanOrEqual(hypot(result.x! - spot.x, result.z! - spot.z), result.r95!) }
    }

    func testDeterministic() {
        let site = Site(name: "a", seed: 6)
        XCTAssertEqual(site.recordGrid(device: "p1", seed: 70), site.recordGrid(device: "p1", seed: 70))
    }

    /// The module stays out of the GPS trust decision and the pipeline until it is validated.
    func testIsolatedFromGNSSIntegrityAndPositioning() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MeshCore")
        let names = ["AmbientEmitterKey", "AmbientAdvertisement", "AmbientRecorder", "AmbientSnapshot", "RadioFingerprint",
                     "FingerprintDatabase", "FingerprintMatcher", "FingerprintMatch"]
        var checked = 0
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "swift" && file.lastPathComponent != "AmbientRadio.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for name in names { XCTAssertFalse(text.contains(name), "\(file.lastPathComponent) uses \(name)") }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 20)
    }

    // MARK: Evaluation

    struct Outcome {
        var correct = 0, wrong = 0, insufficient = 0
        var total: Int { correct + wrong + insufficient }
        var line: String {
            func percent(_ value: Int) -> String { "\(Int((100 * Double(value) / Double(max(1, total))).rounded())) %" }
            return "\(percent(correct)) | \(percent(wrong)) | \(percent(insufficient))"
        }
    }

    enum Place: String, CaseIterable {
        case atSpot = "at a recorded spot"
        case near = "5 m from a spot"
        case between = "between spots (12–18 m)"
        case otherBuilding = "another building"
    }

    /// Recorded 16 spots, then listens 15 s at places around them after `minutes`, for each feature
    /// set. Correct: a match whose radius holds the truth. Wrong: a match whose radius does not.
    func evaluate(minutes: Double, features: (devices: Bool, classes: Bool), seeds: [UInt32] = [1, 2, 3, 4, 5],
                  rotatingOnly: Bool = false) -> [Place: Outcome] {
        var options = FingerprintMatcher.Options()
        options.useDevices = features.devices
        options.useClasses = features.classes
        // Without devices the device requirement cannot hold; class ranks alone show why it exists.
        if !features.devices { options.minCommonDevices = 0 }
        let matcher = FingerprintMatcher(options: options)
        var outcomes: [Place: Outcome] = [:]
        for seed in seeds {
            let site = Site(name: "site\(seed)", seed: seed, rotatingOnly: rotatingOnly)
            let other = Site(name: "other\(seed)", seed: seed &+ 1_000, rotatingOnly: rotatingOnly)
            let database = site.recordGrid(device: "p1", seed: seed &* 100)
            let start = 16 * 30 + minutes * 60
            var random = DeterministicRandom(seed: seed &+ 500)
            for (index, spot) in Site.grid.enumerated() {
                let angle = random.uniform(0, 2 * Double.pi)
                let places: [(Place, Site, Double, Double)] = [
                    (.atSpot, site, spot.x, spot.z),
                    (.near, site, spot.x + 5 * sin(angle), spot.z + 5 * cos(angle)),
                    (.between, site, spot.x + 12.5 + random.uniform(-3, 3), spot.z + 12.5 + random.uniform(-3, 3)),
                    (.otherBuilding, other, spot.x, spot.z),
                ]
                for (place, where_, x, z) in places {
                    let snapshot = where_.listen(device: "p1", x: x, z: z, start: start + Double(index) * 20, seconds: 15,
                                                 seed: seed &* 1_000 &+ UInt32(index) &* 7 &+ UInt32(Place.allCases.firstIndex(of: place)!))
                    let result = matcher.match(snapshot, in: database, frameId: "site", deviceId: "p1")
                    var outcome = outcomes[place, default: Outcome()]
                    if !result.isMatch {
                        outcome.insufficient += 1
                    } else if place != .otherBuilding, hypot(result.x! - x, result.z! - z) <= result.r95! {
                        outcome.correct += 1
                    } else {
                        outcome.wrong += 1
                    }
                    outcomes[place] = outcome
                }
            }
        }
        return outcomes
    }

    /// Default matcher (devices and class ranks): matches at and near recorded spots, and never
    /// claims a spot in another building, fresh or after the devices rotated.
    func testDefaultsMatchSpotsAndNeverAnotherBuilding() {
        for minutes in [2.0, 60] {
            let outcomes = evaluate(minutes: minutes, features: (true, true), seeds: [1, 2, 3])
            XCTAssertGreaterThanOrEqual(Double(outcomes[.atSpot]!.correct) / Double(outcomes[.atSpot]!.total), 0.7, "\(minutes) min")
            for place in [Place.atSpot, .near, .between] {
                XCTAssertLessThanOrEqual(Double(outcomes[place]!.wrong) / Double(outcomes[place]!.total), 0.05, "\(place) \(minutes) min")
            }
            XCTAssertEqual(outcomes[.otherBuilding]!.wrong, 0, "\(minutes) min")
        }
    }

    /// Phones, laptops and earbuds rotate their addresses: device identities decay within minutes,
    /// and what remains must answer "insufficient evidence" rather than a wrong spot. With nothing
    /// but rotating devices around, an hour later almost nothing can be matched.
    func testRotationDecaysIdentitiesWithoutWrongAnswers() {
        let fresh = evaluate(minutes: 2, features: (true, false), seeds: [1, 2, 3])
        let later = evaluate(minutes: 60, features: (true, false), seeds: [1, 2, 3])
        XCTAssertLessThan(later[.atSpot]!.correct, fresh[.atSpot]!.correct)
        let rotating = evaluate(minutes: 60, features: (true, true), seeds: [1, 2, 3], rotatingOnly: true)
        XCTAssertGreaterThanOrEqual(Double(rotating[.atSpot]!.insufficient) / Double(rotating[.atSpot]!.total), 0.9)
        for outcomes in [later, rotating] {
            for place in Place.allCases {
                XCTAssertLessThanOrEqual(Double(outcomes[place]!.wrong) / Double(outcomes[place]!.total), 0.05, place.rawValue)
            }
        }
    }

    func testEvaluationReport() throws {
        guard let path = ProcessInfo.processInfo.environment["AMBIENT_REPORT"] else {
            throw XCTSkip("set AMBIENT_REPORT=<file.md> to write the evaluation")
        }
        var lines = [
            "Synthetic: AmbientRadioTests.Site, 5 sites × 16 spots recorded 20 s each, then 15 s visits. Correct = match whose radius holds the truth; wrong = match whose radius does not (any match in another building is wrong).",
            "",
            "| Features | Minutes after recording | Place | Correct | Wrong | Insufficient evidence |",
            "|---|---|---|---|---|---|",
        ]
        let configurations: [(String, (Bool, Bool), Bool)] = [
            ("devices only", (true, false), false),
            ("class ranks only (no device requirement)", (false, true), false),
            ("both (default)", (true, true), false),
            ("both, site with only rotating devices", (true, true), true),
        ]
        for (label, features, rotatingOnly) in configurations {
            for minutes in [2.0, 30, 60] {
                let outcomes = evaluate(minutes: minutes, features: features, rotatingOnly: rotatingOnly)
                for place in Place.allCases {
                    lines.append("| \(label) | \(Int(minutes)) | \(place.rawValue) | \(outcomes[place]!.line) |")
                }
            }
        }
        let report = lines.joined(separator: "\n") + "\n"
        try report.write(toFile: path, atomically: true, encoding: .utf8)
        print(report)
    }
}
