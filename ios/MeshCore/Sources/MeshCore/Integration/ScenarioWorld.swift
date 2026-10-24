import Foundation

/// Headless rehearsal of a scenario: every phone walks its true path, runs its own
/// GhostCorePipeline (the code the app runs), hears its neighbours through the radio model, and an
/// idealised mesh carries each phone's report to every phone it is connected to. Seeded, so a run
/// is repeatable. Results are synthetic and are reported as such.
public final class ScenarioWorld {
    public enum Outcome: String {
        case pass, fail, pending
    }

    public struct Result: Equatable {
        public let id: String
        public let text: String
        public let outcome: Outcome
        public let detail: String
        public let gate: Bool
    }

    public struct Report {
        public let scenario: Scenario
        public let results: [Result]
        public var gateFailures: [Result] { results.filter { $0.gate && $0.outcome == .fail } }

        public var table: String {
            results.map { r in
                "scenario|\(scenario.id)|\(r.id)|\(r.outcome.rawValue.uppercased())\(r.gate ? "" : " (not gating)")|\(r.text)|\(r.detail)"
            }.joined(separator: "\n")
        }
    }

    /// Engine factories, called with (phone id, frame id); nil keeps the baseline (or no integrity).
    public typealias Factory<T> = (String, String) -> T

    /// Scenario seconds are offset by this, so records carry plausible Unix timestamps.
    public static let epoch = 1_793_000_000.0
    /// Seconds a relay hop adds before a report arrives (one mesh tick).
    public static let hopDelay = 0.3

    public let scenario: Scenario
    public let radio: RadioModel
    private let makeIntegrity: Factory<GhostIntegrityEngine>?
    private let makePositioning: Factory<GhostPositioningEngine>?
    private let makePrediction: Factory<GhostPredictionEngine>?

    public init(scenario: Scenario, radio: RadioModel = .outdoors, integrity: Factory<GhostIntegrityEngine>? = nil,
                positioning: Factory<GhostPositioningEngine>? = nil, prediction: Factory<GhostPredictionEngine>? = nil) {
        self.scenario = scenario
        self.radio = radio
        makeIntegrity = integrity
        makePositioning = positioning
        makePrediction = prediction
    }

    public func run() -> Report {
        var rng = SeededRandom(seed: scenario.seed)
        let ids = scenario.phones.map(\.id)
        var pipelines: [String: GhostCorePipeline] = [:]
        for phone in scenario.phones {
            pipelines[phone.id] = GhostCorePipeline(
                configuration: .init(selfId: phone.id, frameId: scenario.frameId),
                integrity: makeIntegrity?(phone.id, scenario.frameId),
                positioning: makePositioning?(phone.id, scenario.frameId),
                prediction: makePrediction?(phone.id, scenario.frameId))
        }
        let epochs = Dictionary(uniqueKeysWithValues: ids.map { ($0, UUID().uuidString) })
        var publications: [String: GhostCorePipeline.Publication] = [:]
        var blocked = Set<String>()
        var activeFaults = Set<String>()
        let steps = scenario.steps.sorted { $0.at < $1.at }
        var nextStep = 0
        var samples: [String: [Bool]] = [:]
        var errors: [String: [(error: Double, r95: Double)]] = [:]
        var firstHold: [String: Double] = [:]

        func pair(_ a: String, _ b: String) -> String { a < b ? a + "\n" + b : b + "\n" + a }

        for second in 0...Int(scenario.duration) {
            let t = Double(second)
            let now = Self.epoch + t
            while nextStep < steps.count, steps[nextStep].at <= t {
                let input = steps[nextStep].input
                pipelines[input.subjectId]?.apply(input, at: now)
                switch input {
                case .peerLink(let a, let b, let up):
                    if up { blocked.remove(pair(a, b)) } else { blocked.insert(pair(a, b)) }
                case .gnssClear(let id): activeFaults.remove(id)
                case .gnssOutage(let id, false): activeFaults.remove(id)
                default: activeFaults.insert(input.subjectId)
                }
                nextStep += 1
            }

            // Sensors: motion over the last second and a GNSS fix around the true position.
            var truth: [String: FloorVector] = [:]
            for phone in scenario.phones {
                guard let p = scenario.truth(of: phone.id, at: t), let pipeline = pipelines[phone.id] else { continue }
                truth[phone.id] = p
                if second > 0, let before = scenario.truth(of: phone.id, at: t - 1) {
                    let dx = p.x - before.x, dz = p.z - before.z
                    let distance = (dx * dx + dz * dz).squareRoot()
                    let noise = 0.05 + 0.1 * distance
                    let moved = FloorVector(x: dx + noise * rng.gauss(), z: dz + noise * rng.gauss())
                    let still = distance < 0.1
                    if let motion = try? Self.validated(MotionObservation(
                        subjectId: phone.id, timestamp: now, interval: 1, frameId: scenario.frameId, method: .stepDetector,
                        steps: still ? 0 : Int((distance / 0.7).rounded()), displacement: moved,
                        heading: still ? nil : atan2(dx, dz), stationary: still,
                        uncertainty: .init(displacementR95: PositionUncertainty.r95(fromSigma: noise), headingSigma: 0.15),
                        freshness: Freshness(maxAge: 5),
                        provenance: Provenance(producerId: phone.id, algorithm: "scenario-motion@1", gnssDependent: false,
                                               simulated: true))) {
                        pipeline.ingest(motion: motion)
                    }
                }
                if phone.hasGNSS {
                    let sigma = phone.accuracy68 / 1.5096
                    let fix = PositionEstimate(
                        subjectId: phone.id, timestamp: now, frameId: scenario.frameId, kind: .measured, method: .gnss,
                        position: Position(x: p.x + sigma * rng.gauss(), y: 0, z: p.z + sigma * rng.gauss()),
                        uncertainty: PositionUncertainty(r95: PositionUncertainty.r95(fromRadius68: phone.accuracy68)),
                        lastAbsoluteAt: now, source: .gnss, freshness: Freshness(maxAge: 30),
                        provenance: Provenance(producerId: phone.id, algorithm: "scenario-gnss@1", gnssDependent: true,
                                               simulated: true))
                    pipeline.ingest(fix: fix, receivedAt: now)
                }
            }

            // Radio: which pairs hear each other this second, and how loudly in each direction.
            var heard: [String: [String: Int]] = [:]
            for (i, a) in ids.enumerated() {
                for b in ids[(i + 1)...] {
                    guard let pa = truth[a], let pb = truth[b], !blocked.contains(pair(a, b)) else { continue }
                    let d = ((pa.x - pb.x) * (pa.x - pb.x) + (pa.z - pb.z) * (pa.z - pb.z)).squareRoot()
                    guard rng.next() < radio.hearProbability(atDistance: d) else { continue }
                    let expected = radio.expectedRSSI(atDistance: d)
                    heard[a, default: [:]][b] = Int(max(-127, min(20, expected + radio.sigma * rng.gauss())).rounded())
                    heard[b, default: [:]][a] = Int(max(-127, min(20, expected + radio.sigma * rng.gauss())).rounded())
                }
            }
            for id in ids {
                let records = (heard[id] ?? [:]).sorted { $0.key < $1.key }.map { peer, rssi in
                    PeerObservation(observerId: id, peerId: peer, timestamp: now, frameId: scenario.frameId,
                                    channel: .connection, linkState: .ready, rawRSSI: [Double(rssi)], window: 1,
                                    smoothedRSSI: Double(rssi), uncertainty: .init(stdDevDb: nil, sampleCount: 1),
                                    freshness: Freshness(maxAge: 6),
                                    provenance: Provenance(producerId: id, algorithm: "scenario-radio@1",
                                                           gnssDependent: false, simulated: true))
                }
                pipelines[id]?.ingest(observations: records)
            }

            // Mesh: each phone's report reaches every phone it is connected to, along the shortest path.
            for origin in ids {
                let publication = publications[origin]
                    ?? .init(position: Position(x: 0, y: 0, z: 0), accuracyMeters: nil, source: .none)
                let update = DeviceUpdate(
                    id: origin, label: scenario.phones.first { $0.id == origin }?.label, epochId: epochs[origin]!,
                    sequence: second, role: "mobile", position: publication.position, positionMode: "floor",
                    accuracyMeters: publication.accuracyMeters,
                    neighbors: (heard[origin] ?? [:]).sorted { $0.key < $1.key }
                        .map { NeighborObservation(id: $0.key, rssi: $0.value, ageMs: 0) },
                    positionSource: publication.source)
                var parent: [String: String] = [origin: origin]
                var queue = [origin]
                while !queue.isEmpty {
                    let node = queue.removeFirst()
                    for next in (heard[node] ?? [:]).keys.sorted() where parent[next] == nil {
                        parent[next] = node
                        queue.append(next)
                    }
                }
                for (receiver, _) in parent {
                    var path: [String] = []
                    var hop = parent[receiver]!
                    while hop != origin {
                        path.insert(hop, at: 0)
                        hop = parent[hop]!
                    }
                    let delay = receiver == origin ? 0 : Double(path.count + 1) * Self.hopDelay
                    pipelines[receiver]?.ingest(report: update, receivedAt: now - 1 + delay, path: path)
                }
            }

            // Every phone's pipeline steps; expectations are checked on what it shows.
            var outputs: [String: GhostCorePipeline.Output] = [:]
            for id in ids {
                guard let output = pipelines[id]?.step(now: now) else { continue }
                outputs[id] = output
                publications[id] = output.publication
            }
            for e in scenario.expectations where t >= e.from && t <= e.to {
                let holds = check(e, outputs: outputs, truth: truth, faultActive: activeFaults.contains(e.subject))
                samples[e.id, default: []].append(holds)
                if holds, firstHold[e.id] == nil { firstHold[e.id] = t }
                if e.check == .truthInsideR95, let shown = phone(e.subject, in: outputs[e.observer])?.selected,
                   let position = shown.position, let p = truth[e.subject] {
                    let error = ((position.x - p.x) * (position.x - p.x) + (position.z - p.z) * (position.z - p.z)).squareRoot()
                    errors[e.id, default: []].append((error, shown.uncertainty.r95))
                }
            }
        }

        let results = scenario.expectations.map { e -> Result in
            let missing = e.requires.filter { engine in
                switch engine {
                case "integrity": return makeIntegrity == nil
                case "positioning", "prediction": return false
                default: return true
                }
            }
            if !missing.isEmpty {
                return Result(id: e.id, text: e.text, outcome: .pending,
                              detail: "needs \(missing.joined(separator: ", ")) engine", gate: e.gate)
            }
            let held = samples[e.id] ?? []
            var detail: String
            let pass: Bool
            if let within = e.within {
                let first = firstHold[e.id]
                pass = first.map { $0 <= e.from + within } ?? false
                detail = first.map { String(format: "first held %.0f s after t=%.0f (limit %.0f s)", $0 - e.from, e.from, within) }
                    ?? "never held"
            } else {
                let fraction = held.isEmpty ? 0 : Double(held.filter { $0 }.count) / Double(held.count)
                pass = fraction >= (e.minFraction ?? 1)
                detail = String(format: "held %.0f%% of %d s (need %.0f%%)", fraction * 100, held.count, (e.minFraction ?? 1) * 100)
            }
            if let list = errors[e.id], !list.isEmpty {
                let median = { (values: [Double]) in values.sorted()[values.count / 2] }
                detail += String(format: "; median error %.1f m, median r95 %.1f m", median(list.map(\.error)), median(list.map(\.r95)))
            }
            return Result(id: e.id, text: e.text, outcome: pass ? .pass : .fail, detail: detail + "; synthetic", gate: e.gate)
        }
        return Report(scenario: scenario, results: results)
    }

    private func phone(_ id: String, in output: GhostCorePipeline.Output?) -> GhostCorePipeline.Phone? {
        output?.phones.first { $0.id == id }
    }

    private func check(_ e: ScenarioExpectation, outputs: [String: GhostCorePipeline.Output], truth: [String: FloorVector],
                       faultActive: Bool) -> Bool {
        let seen = phone(e.subject, in: outputs[e.observer])
        let values = Set(e.values ?? [])
        switch e.check {
        case .integrityStatus:
            guard let status = phone(e.subject, in: outputs[e.subject])?.integrity?.status else { return false }
            return values.contains(status.rawValue)
        case .positionKind:
            guard let kind = seen?.selected?.kind else { return values.contains("none") }
            return values.contains(kind.rawValue)
        case .truthInsideR95:
            guard let shown = seen?.selected, let position = shown.position, let p = truth[e.subject] else { return false }
            let d = ((position.x - p.x) * (position.x - p.x) + (position.z - p.z) * (position.z - p.z)).squareRoot()
            return d <= shown.uncertainty.r95
        case .predictionShown:
            return seen?.selected?.kind == .predicted
        case .predictionNotShown:
            return seen?.selected != nil && seen?.selected?.kind != .predicted
        case .notAnchoredBy:
            guard let own = phone(e.observer, in: outputs[e.observer])?.estimate else { return true }
            return !own.provenance.inputs.contains { $0.used && $0.id == e.subject && $0.source == .gnss }
        case .simulatedMarked:
            guard faultActive, let fix = phone(e.subject, in: outputs[e.subject])?.rawFix else { return true }
            return fix.provenance.simulated
        }
    }

    private static func validated<T: GhostRecord>(_ record: T) throws -> T {
        try record.validate()
        return record
    }
}
