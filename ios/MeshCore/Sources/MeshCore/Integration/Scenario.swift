import Foundation

/// A raw input a scenario feeds into the real pipeline: it changes a phone's own sensor streams,
/// never an engine's output. GNSS faults act on the phone named by `subjectId`, which in the app is
/// always the phone running the scenario: other phones are other devices.
public enum ScenarioInput: Equatable {
    /// The phone's GNSS delivers no fixes while active.
    case gnssOutage(subjectId: String, active: Bool)
    /// Every following fix is shifted by (dx, dz) metres at once.
    case gnssJump(subjectId: String, dx: Double, dz: Double)
    /// From now on the shift grows at `metersPerSecond`, towards `bearingDegrees` (0 = +z north, 90 = +x east).
    case gnssDrift(subjectId: String, metersPerSecond: Double, bearingDegrees: Double)
    /// Removes outage, jump and drift.
    case gnssClear(subjectId: String)
    /// Forces this phone's Bluetooth link to `peerId` down (the relay's test link filter) or lets it up again.
    case peerLink(subjectId: String, peerId: String, up: Bool)

    public var subjectId: String {
        switch self {
        case .gnssOutage(let id, _), .gnssJump(let id, _, _), .gnssDrift(let id, _, _), .gnssClear(let id),
             .peerLink(let id, _, _):
            return id
        }
    }
}

/// JSON: `{"type": "gnssJump", "subjectId": "phone-c", "dx": 400, "dz": 0}`.
extension ScenarioInput: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, subjectId, active, dx, dz, metersPerSecond, bearingDegrees, peerId, up
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let subject = try c.decode(String.self, forKey: .subjectId)
        switch try c.decode(String.self, forKey: .type) {
        case "gnssOutage": self = .gnssOutage(subjectId: subject, active: try c.decode(Bool.self, forKey: .active))
        case "gnssJump":
            self = .gnssJump(subjectId: subject, dx: try c.decode(Double.self, forKey: .dx), dz: try c.decode(Double.self, forKey: .dz))
        case "gnssDrift":
            self = .gnssDrift(subjectId: subject, metersPerSecond: try c.decode(Double.self, forKey: .metersPerSecond),
                              bearingDegrees: try c.decode(Double.self, forKey: .bearingDegrees))
        case "gnssClear": self = .gnssClear(subjectId: subject)
        case "peerLink":
            self = .peerLink(subjectId: subject, peerId: try c.decode(String.self, forKey: .peerId),
                             up: try c.decode(Bool.self, forKey: .up))
        default: throw GhostCoreContractError.invalid("scenario.input.type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(subjectId, forKey: .subjectId)
        switch self {
        case .gnssOutage(_, let active):
            try c.encode("gnssOutage", forKey: .type)
            try c.encode(active, forKey: .active)
        case .gnssJump(_, let dx, let dz):
            try c.encode("gnssJump", forKey: .type)
            try c.encode(dx, forKey: .dx)
            try c.encode(dz, forKey: .dz)
        case .gnssDrift(_, let speed, let bearing):
            try c.encode("gnssDrift", forKey: .type)
            try c.encode(speed, forKey: .metersPerSecond)
            try c.encode(bearing, forKey: .bearingDegrees)
        case .gnssClear:
            try c.encode("gnssClear", forKey: .type)
        case .peerLink(_, let peer, let up):
            try c.encode("peerLink", forKey: .type)
            try c.encode(peer, forKey: .peerId)
            try c.encode(up, forKey: .up)
        }
    }
}

/// The GNSS faults active on one phone. Applied to each raw fix before any engine sees it; a
/// changed fix is marked simulated, so everything derived from it carries the SIMULATED badge.
public struct GNSSFaults: Equatable {
    public private(set) var outage = false
    public private(set) var jump = FloorVector(x: 0, z: 0)
    public private(set) var drift: (start: Double, metersPerSecond: Double, bearing: Double)?

    public init() {}

    public var isActive: Bool { outage || jump != FloorVector(x: 0, z: 0) || drift != nil }

    public mutating func apply(_ input: ScenarioInput, at t: Double) {
        switch input {
        case .gnssOutage(_, let active): outage = active
        case .gnssJump(_, let dx, let dz): jump = FloorVector(x: jump.x + dx, z: jump.z + dz)
        case .gnssDrift(_, let speed, let bearing): drift = (t, speed, bearing * Double.pi / 180)
        case .gnssClear: self = GNSSFaults()
        case .peerLink: break
        }
    }

    /// The shift at time `t`.
    public func offset(at t: Double) -> FloorVector {
        var x = jump.x, z = jump.z
        if let drift {
            let d = drift.metersPerSecond * max(0, t - drift.start)
            x += d * sin(drift.bearing)
            z += d * cos(drift.bearing)
        }
        return FloorVector(x: x, z: z)
    }

    /// The fix as the faulty receiver would report it, or nil during an outage.
    public func apply(to fix: PositionEstimate) -> PositionEstimate? {
        guard !outage else { return nil }
        guard isActive, let position = fix.position else { return fix }
        let shift = offset(at: fix.timestamp)
        let limit = GhostCoreContract.maxCoordinate
        let moved = Position(x: min(limit, max(-limit, position.x + shift.x)), y: position.y,
                             z: min(limit, max(-limit, position.z + shift.z)))
        let p = fix.provenance
        return PositionEstimate(subjectId: fix.subjectId, timestamp: fix.timestamp, frameId: fix.frameId, kind: fix.kind,
                                method: fix.method, position: moved, positionMode: fix.positionMode,
                                uncertainty: fix.uncertainty, heading: fix.heading, headingSigma: fix.headingSigma,
                                velocity: fix.velocity, lastAbsoluteAt: fix.lastAbsoluteAt, source: fix.source,
                                freshness: fix.freshness,
                                provenance: Provenance(producerId: p.producerId, algorithm: p.algorithm, inputs: p.inputs,
                                                       contributors: p.contributors, gnssDependent: p.gnssDependent,
                                                       simulated: true))
    }

    public static func == (a: GNSSFaults, b: GNSSFaults) -> Bool {
        a.outage == b.outage && a.jump == b.jump && a.drift?.start == b.drift?.start
            && a.drift?.metersPerSecond == b.drift?.metersPerSecond && a.drift?.bearing == b.drift?.bearing
    }
}

/// A scripted test: phones with true paths (used only by the headless world), timed raw inputs,
/// and expectations. Files live in contract/scenarios/.
public struct Scenario: Codable, Equatable {
    public struct Waypoint: Codable, Equatable {
        public let t: Double
        public let x: Double
        public let z: Double
    }

    public struct Phone: Codable, Equatable {
        public let id: String
        public let label: String
        /// False for a phone that never has GNSS (indoors, or GPS off).
        public let hasGNSS: Bool
        /// Claimed 68 % accuracy of its fixes, metres; the true error follows it.
        public let accuracy68: Double
        /// True path; linear between waypoints, held after the last one.
        public let waypoints: [Waypoint]
    }

    public struct Step: Codable, Equatable {
        public let at: Double
        public let input: ScenarioInput
        public let caption: String?
    }

    public let id: String
    public let title: String
    public let summary: String
    public let frameId: String
    public let seed: UInt32
    public let duration: Double
    public let phones: [Phone]
    public let steps: [Step]
    public let expectations: [ScenarioExpectation]

    public func truth(of phoneId: String, at t: Double) -> FloorVector? {
        guard let points = phones.first(where: { $0.id == phoneId })?.waypoints, let first = points.first else { return nil }
        if t <= first.t { return FloorVector(x: first.x, z: first.z) }
        for (a, b) in zip(points, points.dropFirst()) where t <= b.t {
            let f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 1
            return FloorVector(x: a.x + (b.x - a.x) * f, z: a.z + (b.z - a.z) * f)
        }
        return points.last.map { FloorVector(x: $0.x, z: $0.z) }
    }
}

/// One checkable claim about a scenario run, seen from `observer`'s pipeline.
public struct ScenarioExpectation: Codable, Equatable {
    public enum Check: String, Codable {
        /// The subject's integrity status as the observer sees it (its own, or relayed) is one of `values`.
        case integrityStatus
        /// The kind of the subject's selected position is one of `values`.
        case positionKind
        /// The subject's true position lies inside the selected position's r95.
        case truthInsideR95
        /// The subject is shown as a prediction.
        case predictionShown
        /// The subject is not shown as a prediction.
        case predictionNotShown
        /// The observer's own estimate does not use the subject as an anchor.
        case notAnchoredBy
        /// No selected position anywhere is presented as measured unless its source is GNSS or UWB
        /// and its provenance is marked simulated whenever a fault is active.
        case simulatedMarked
    }

    public let id: String
    public let text: String
    public let check: Check
    public let observer: String
    public let subject: String
    /// Window start, seconds into the scenario.
    public let from: Double
    /// Window end.
    public let to: Double
    /// Pass when the check holds at least once within this many seconds after `from`.
    public let within: Double?
    /// Pass when the check holds in at least this fraction of the seconds in the window.
    public let minFraction: Double?
    public let values: [String]?
    /// Engines the claim is about; with one missing the result is "pending", never "pass".
    public let requires: [String]
    /// A failure fails the gate. Acceptance thresholds still being worked towards are not gating.
    public let gate: Bool
}

/// What a running scenario shows in the app.
public struct ScenarioState: Equatable {
    public let scenarioId: String
    public let title: String
    public let elapsed: Double
    public let stepIndex: Int
    public let caption: String?
    public let isRunning: Bool

    public init(scenarioId: String, title: String, elapsed: Double, stepIndex: Int, caption: String?, isRunning: Bool) {
        self.scenarioId = scenarioId
        self.title = title
        self.elapsed = elapsed
        self.stepIndex = stepIndex
        self.caption = caption
        self.isRunning = isRunning
    }
}
