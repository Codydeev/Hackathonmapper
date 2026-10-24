import Foundation

// Deterministic synthetic GNSS faults for testing GNSSIntegrityEngine. Faults are applied to the
// fixes the app hands to the engine (application data), never to a radio: nothing here transmits
// or needs a GNSS simulator, and the same seed always replays the same run.
//
// A run builds one simulated world per scenario and seed (a walker with pauses and turns, GNSS with
// time-correlated error, dead reckoning with heading and step-length bias, peers walking alongside
// with their own GNSS, surveyed beacons, Bluetooth RSSI) and then replays that same world through
// each detector configuration, so configurations are compared on identical data.

/// mulberry32: small and identical on every platform, so a seed replays the same run.
public struct DeterministicRandom {
    private var state: UInt32

    public init(seed: UInt32) {
        state = seed
    }

    public mutating func next() -> Double {
        state = state &+ 0x6d2b_79f5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }

    public mutating func gauss() -> Double {
        (-2 * log(max(next(), 1e-12))).squareRoot() * cos(2 * Double.pi * next())
    }

    public mutating func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * next()
    }
}

public enum GNSSFault: Equatable {
    /// Position jumps by a fixed offset and stays there (teleport spoof, receiver relock).
    case jump(dx: Double, dz: Double)
    /// Fixes run away at a steady speed, with matching reported speed and course.
    case fakeTrack(speed: Double, course: Double)
    /// Fixes accelerate away from the true track.
    case acceleration(rate: Double, course: Double)
    /// Position slides away slowly (drag-off spoof, slowly growing multipath); reported velocity
    /// includes the slide, as a careful spoofer would make it.
    case slowDrift(rate: Double, course: Double)
    /// The receiver keeps reporting the position from the start of the fault with fresh timestamps.
    case frozenPosition
    /// Fixes arrive late, with their true (old) timestamps.
    case delayed(by: TimeInterval)
    /// No fixes at all.
    case dropout
    /// Reported accuracy and noise grow for ten seconds, then fixes stop (jamming).
    case jamming
    /// Fixes recorded `lag` seconds earlier are played back with current timestamps (meaconing).
    case replay(lag: TimeInterval)

    /// Faults that place the phone somewhere wrong (rather than only taking GNSS away), which the
    /// engine has to flag as anomalies.
    public var isIntegrityFault: Bool {
        switch self {
        case .delayed, .dropout, .jamming: false
        default: true
        }
    }
}

public struct GNSSFaultInjection: Equatable {
    public var fault: GNSSFault
    public var start: TimeInterval
    /// nil: until the run ends.
    public var end: TimeInterval?
    /// Applies the same fault to every peer's GNSS as well: one spoofer, jammer or ionosphere
    /// covering the whole group.
    public var commonMode: Bool

    public init(_ fault: GNSSFault, start: TimeInterval, end: TimeInterval? = nil, commonMode: Bool = false) {
        self.fault = fault
        self.start = start
        self.end = end
        self.commonMode = commonMode
    }

    func isActive(at time: TimeInterval) -> Bool {
        time >= start && end.map { time < $0 } ?? true
    }
}

public struct GNSSScenario: Equatable {
    public enum Motion: String, Equatable {
        /// Walks with turns and occasional pauses.
        case walk
        /// Stays where it is (the GPS anchor on a table).
        case still
    }

    /// How hard the sky is on GNSS when nothing is wrong.
    public enum Environment: String, Equatable {
        /// 2.5 m per axis of slowly wandering error, accuracy reported honestly (about 4 m).
        case openSky
        /// 5 m of wandering error plus multipath bursts: every few minutes the fix steps 10–35 m
        /// aside for 8–25 s while the reported accuracy grows only by a third. No fault, but the
        /// hardest clean case for false alarms.
        case urban
    }

    public var name: String
    public var duration: Int
    public var injections: [GNSSFaultInjection]
    public var motion: Motion
    public var environment: Environment
    public var peerCount: Int
    /// Surveyed beacons, placed 15 m beside the route where the walker passes at these seconds.
    public var anchorsAt: [Int]

    public init(_ name: String, duration: Int = 600, injections: [GNSSFaultInjection] = [], motion: Motion = .walk,
                environment: Environment = .openSky, peerCount: Int = 3, anchorsAt: [Int] = []) {
        self.name = name
        self.duration = duration
        self.injections = injections
        self.motion = motion
        self.environment = environment
        self.peerCount = peerCount
        self.anchorsAt = anchorsAt
    }

    /// When the fault the engine should catch begins: the first integrity fault, or else the first
    /// fault of any kind.
    public var detectionStart: TimeInterval? {
        (injections.first { $0.fault.isIntegrityFault } ?? injections.first)?.start
    }

    public var expectsAnomaly: Bool { injections.contains { $0.fault.isIntegrityFault } }

    /// ARCHITECTURE.md section 10, S2: phone C's fixes offset by 400 m at once.
    public static let jump400 = GNSSScenario("S2 jump 400 m", injections: [GNSSFaultInjection(.jump(dx: 400, dz: 0), start: 240)])
    /// S3: C's offset grows 1 m/s, bearing 90°.
    public static let drift1 = GNSSScenario("S3 drift 1 m/s", injections: [GNSSFaultInjection(.slowDrift(rate: 1, course: 90), start: 240)])
    /// S4: the S3 offset (60 m after a minute) is removed again.
    public static let recovery = GNSSScenario("S4 drift removed", injections: [
        GNSSFaultInjection(.slowDrift(rate: 1, course: 90), start: 240, end: 300),
    ])

    /// The scenario library: clean runs for false alarms, then one per fault.
    public static let library: [GNSSScenario] = [
        GNSSScenario("clean walk", duration: 900),
        GNSSScenario("clean, phone still", duration: 900, motion: .still),
        GNSSScenario("clean walk, urban multipath", duration: 900, environment: .urban),
        GNSSScenario("clean, still, urban multipath", duration: 900, motion: .still, environment: .urban),
        jump400, drift1, recovery,
        GNSSScenario("teleport 1 km", injections: [GNSSFaultInjection(.jump(dx: 700, dz: -700), start: 240)]),
        GNSSScenario("jump 50 m", injections: [GNSSFaultInjection(.jump(dx: 35, dz: 35), start: 240)]),
        GNSSScenario("fake track 15 m/s", injections: [GNSSFaultInjection(.fakeTrack(speed: 15, course: 120), start: 240)]),
        GNSSScenario("acceleration 8 m/s²", injections: [GNSSFaultInjection(.acceleration(rate: 8, course: 200), start: 240)]),
        GNSSScenario("slow drift 0.5 m/s", duration: 900, injections: [GNSSFaultInjection(.slowDrift(rate: 0.5, course: 75), start: 240)]),
        GNSSScenario("slow drift 0.2 m/s", duration: 900, injections: [GNSSFaultInjection(.slowDrift(rate: 0.2, course: 75), start: 240)]),
        GNSSScenario("very slow drift 0.05 m/s", duration: 900, injections: [GNSSFaultInjection(.slowDrift(rate: 0.05, course: 75), start: 240)]),
        GNSSScenario("slow drift 0.5 m/s, phone still", duration: 900, injections: [GNSSFaultInjection(.slowDrift(rate: 0.5, course: 75), start: 240)], motion: .still),
        GNSSScenario("frozen position", injections: [GNSSFaultInjection(.frozenPosition, start: 240, end: 360)]),
        GNSSScenario("replay 30 s old", injections: [GNSSFaultInjection(.replay(lag: 30), start: 240)]),
        GNSSScenario("fixes 15 s late", injections: [GNSSFaultInjection(.delayed(by: 15), start: 240, end: 300)]),
        GNSSScenario("dropout 60 s", injections: [GNSSFaultInjection(.dropout, start: 240, end: 300)]),
        GNSSScenario("jamming 60 s", injections: [GNSSFaultInjection(.jamming, start: 240, end: 300)]),
        GNSSScenario("jam 30 s, then 200 m offset", injections: [
            GNSSFaultInjection(.dropout, start: 240, end: 270),
            GNSSFaultInjection(.jump(dx: 140, dz: 140), start: 270),
        ]),
        GNSSScenario("common-mode jump 1 km", injections: [GNSSFaultInjection(.jump(dx: 700, dz: -700), start: 240, commonMode: true)]),
        GNSSScenario("common-mode drift 0.5 m/s", duration: 900, injections: [GNSSFaultInjection(.slowDrift(rate: 0.5, course: 75), start: 240, commonMode: true)]),
        GNSSScenario("common-mode drift 0.5 m/s, anchor at 600 s", duration: 900,
                     injections: [GNSSFaultInjection(.slowDrift(rate: 0.5, course: 75), start: 240, commonMode: true)],
                     anchorsAt: [600]),
    ]

    public static func named(_ name: String) -> GNSSScenario? { library.first { $0.name == name } }
}

/// Which inputs a detector gets. The world is the same for all of them.
public struct GNSSDetectorConfig: Equatable {
    public var name: String
    public var useInertial: Bool
    public var usePeers: Bool
    public var useAnchors: Bool
    public var options: GNSSIntegrityEngine.Options

    public init(_ name: String, useInertial: Bool, usePeers: Bool, useAnchors: Bool,
                options: GNSSIntegrityEngine.Options = .pedestrian) {
        self.name = name
        self.useInertial = useInertial
        self.usePeers = usePeers
        self.useAnchors = useAnchors
        self.options = options
    }

    /// The fix's own consistency only: accuracy, age, timestamps, speed, acceleration, jumps.
    public static let gnssOnly = GNSSDetectorConfig("GNSS only", useInertial: false, usePeers: false, useAnchors: false)
    /// Plus consensus with peers whose positions come from their own GNSS.
    public static let peers = GNSSDetectorConfig("+ peers", useInertial: false, usePeers: true, useAnchors: false)
    /// Plus surveyed beacons, still without inertial motion.
    public static let peersAndAnchors = GNSSDetectorConfig("+ peers + beacons", useInertial: false, usePeers: true, useAnchors: true)
    /// Plus inertial motion.
    public static let inertial = GNSSDetectorConfig("+ inertial", useInertial: true, usePeers: false, useAnchors: false)
    /// Everything, surveyed beacons included.
    public static let full = GNSSDetectorConfig("full", useInertial: true, usePeers: true, useAnchors: true)

    public static let all = [gnssOnly, peers, peersAndAnchors, inertial, full]
}

/// One simulated world: everything the app would have received, second by second.
public struct GNSSSimulatedWorld {
    public let scenario: GNSSScenario
    public let seed: UInt32
    /// Index = second. Where the phone really is.
    public let truth: [FloorPoint]
    /// The fix delivered in each second, after faults; nil when none arrived.
    public let fixes: [GNSSFix?]
    /// Dead-reckoning increment ending in each second (index 0 unused).
    public let motion: [InertialDisplacement?]
    public let peerReports: [[PeerProximity]]
    public let anchorReports: [[PeerProximity]]
    /// RSSI (dBm) behind each report, same layout.
    public let peerRSSI: [[Double]]
    public let anchorRSSI: [[Double]]

    public init(scenario: GNSSScenario, seed: UInt32) {
        self.scenario = scenario
        self.seed = seed
        let duration = scenario.duration
        let radio = RadioModel.outdoors

        let truth = Self.route(seed: seed, duration: duration, motion: scenario.motion)
        self.truth = truth
        let ownClean = Self.cleanFixes(truth: truth, seed: seed &+ 1_000, environment: scenario.environment)
        fixes = (0...duration).map { second in
            Self.inject(scenario.injections, second: second, clean: ownClean)
        }

        var noise = DeterministicRandom(seed: seed &+ 2_000)
        let headingBias = noise.uniform(-4, 4) * Double.pi / 180
        let scale = 1 + noise.uniform(-0.03, 0.03)
        var headingWalk = 0.0
        var motion: [InertialDisplacement?] = [nil]
        for second in 1...duration {
            let dx = truth[second].x - truth[second - 1].x, dz = truth[second].z - truth[second - 1].z
            let start = Double(second - 1), end = Double(second)
            if hypot(dx, dz) < 0.05 {
                motion.append(InertialDisplacement(start: start, end: end, dx: 0, dz: 0, sigma: 0.02, stationary: true))
                continue
            }
            headingWalk = max(-0.035, min(0.035, headingWalk + 0.005 * noise.gauss()))
            let angle = headingBias + headingWalk
            let rx = scale * (dx * cos(angle) + dz * sin(angle)) + 0.08 * noise.gauss()
            let rz = scale * (-dx * sin(angle) + dz * cos(angle)) + 0.08 * noise.gauss()
            motion.append(InertialDisplacement(start: start, end: end, dx: rx, dz: rz, sigma: 0.1 + 0.05 * hypot(dx, dz)))
        }
        self.motion = motion

        var peerReports = [[PeerProximity]](repeating: [], count: duration + 1)
        var peerRSSI = [[Double]](repeating: [], count: duration + 1)
        let commonMode = scenario.injections.filter(\.commonMode)
        for peer in 0..<scenario.peerCount {
            var layout = DeterministicRandom(seed: seed &+ 3_000 &+ UInt32(peer))
            let radius = layout.uniform(8, 35), phase = layout.uniform(0, 2 * Double.pi)
            let rate = layout.uniform(-0.01, 0.01)
            let peerTruth = truth.enumerated().map { second, point in
                let angle = phase + rate * Double(second)
                return FloorPoint(x: point.x + radius * sin(angle), z: point.z + radius * cos(angle))
            }
            let peerClean = Self.cleanFixes(truth: peerTruth, seed: seed &+ 4_000 &+ UInt32(peer), environment: scenario.environment)
            var hearing = DeterministicRandom(seed: seed &+ 5_000 &+ UInt32(peer))
            for second in 1...duration {
                let distance = hypot(peerTruth[second].x - truth[second].x, peerTruth[second].z - truth[second].z)
                let heard = hearing.next() <= radio.hearProbability(atDistance: distance)
                let rssi = radio.expectedRSSI(atDistance: distance) + radio.sigma * 0.8 * hearing.gauss()
                guard heard, let fix = Self.inject(commonMode, second: second, clean: peerClean) else { continue }
                peerReports[second].append(PeerProximity(
                    time: Double(second), peerId: "peer-\(peer)", peerPosition: fix.position, peerSigma: fix.sigma,
                    origin: .gnssDerived, maxRange: PeerProximity.maxRange(rssi: rssi, radio: radio)))
                peerRSSI[second].append(rssi)
            }
        }
        self.peerReports = peerReports
        self.peerRSSI = peerRSSI

        var anchorReports = [[PeerProximity]](repeating: [], count: duration + 1)
        var anchorRSSI = [[Double]](repeating: [], count: duration + 1)
        var hearing = DeterministicRandom(seed: seed &+ 6_000)
        for (index, at) in scenario.anchorsAt.enumerated() where at > 0 && at <= duration {
            let dx = truth[at].x - truth[at - 1].x, dz = truth[at].z - truth[at - 1].z
            let length = max(hypot(dx, dz), 1e-9)
            let anchor = FloorPoint(x: truth[at].x + 15 * dz / length, z: truth[at].z - 15 * dx / length)
            for second in 1...duration {
                let distance = hypot(anchor.x - truth[second].x, anchor.z - truth[second].z)
                guard hearing.next() <= radio.hearProbability(atDistance: distance) else { continue }
                let rssi = radio.expectedRSSI(atDistance: distance) + radio.sigma * 0.8 * hearing.gauss()
                anchorReports[second].append(PeerProximity(
                    time: Double(second), peerId: "anchor-\(index)", peerPosition: anchor, peerSigma: 1,
                    origin: .surveyed, maxRange: PeerProximity.maxRange(rssi: rssi, radio: radio)))
                anchorRSSI[second].append(rssi)
            }
        }
        self.anchorReports = anchorReports
        self.anchorRSSI = anchorRSSI
    }

    /// A walker on turns and pauses, or a phone lying still.
    static func route(seed: UInt32, duration: Int, motion: GNSSScenario.Motion) -> [FloorPoint] {
        var random = DeterministicRandom(seed: seed)
        var x = 0.0, z = 0.0
        var heading = random.uniform(0, 2 * Double.pi)
        var speed = random.uniform(1.2, 1.5)
        var segmentLeft = random.uniform(20, 80)
        var pauseLeft = 0
        var points = [FloorPoint(x: 0, z: 0)]
        for _ in 1...max(1, duration) {
            if motion == .walk {
                if pauseLeft > 0 {
                    pauseLeft -= 1
                } else {
                    x += speed * sin(heading)
                    z += speed * cos(heading)
                    segmentLeft -= 1
                    if segmentLeft <= 0 {
                        heading += random.uniform(-70, 70) * Double.pi / 180
                        speed = random.uniform(1.2, 1.5)
                        segmentLeft = random.uniform(20, 80)
                        if random.next() < 0.25 { pauseLeft = Int(random.uniform(10, 40)) }
                    }
                }
            }
            points.append(FloorPoint(x: x, z: z))
        }
        return points
    }

    /// Fixes with time-correlated error (Gauss-Markov), white noise on top, and a reported accuracy
    /// that matches them; in `.urban`, multipath bursts the reported accuracy mostly misses.
    static func cleanFixes(truth: [FloorPoint], seed: UInt32, environment: GNSSScenario.Environment = .openSky) -> [GNSSFix] {
        var random = DeterministicRandom(seed: seed)
        let urban = environment == .urban
        let sigma = urban ? 5.0 : 2.5, white = urban ? 1.5 : 0.8, tau = urban ? 30.0 : 45.0
        let decay = exp(-1 / tau), drive = sigma * (1 - decay * decay).squareRoot()
        var ex = sigma * random.gauss(), ez = sigma * random.gauss()
        var burstLeft = 0, burstX = 0.0, burstZ = 0.0
        return truth.indices.map { second in
            ex = decay * ex + drive * random.gauss()
            ez = decay * ez + drive * random.gauss()
            if urban {
                if burstLeft > 0 {
                    burstLeft -= 1
                } else if random.next() < 1.0 / 150 {
                    burstLeft = Int(random.uniform(8, 25))
                    let size = random.uniform(10, 35), angle = random.uniform(0, 2 * Double.pi)
                    burstX = size * sin(angle)
                    burstZ = size * cos(angle)
                }
            }
            let bx = burstLeft > 0 ? burstX : 0, bz = burstLeft > 0 ? burstZ : 0
            let previous = truth[max(0, second - 1)]
            let vx = truth[second].x - previous.x + 0.2 * random.gauss()
            let vz = truth[second].z - previous.z + 0.2 * random.gauss()
            let speed = hypot(vx, vz)
            var course = atan2(vx, vz) * 180 / Double.pi
            if course < 0 { course += 360 }
            let inflation = burstLeft > 0 ? 1.33 : 1
            let accuracy = (1.515 * hypot(sigma, white) * inflation * random.uniform(0.85, 1.15) * 10).rounded() / 10
            return GNSSFix(time: Double(second),
                           position: FloorPoint(x: truth[second].x + ex + bx + white * random.gauss(),
                                                z: truth[second].z + ez + bz + white * random.gauss()),
                           accuracy: accuracy, speed: speed, course: speed < 0.3 ? -1 : course, speedAccuracy: 0.3)
        }
    }

    /// The fix delivered in `second` once the faults active then have been applied.
    static func inject(_ injections: [GNSSFaultInjection], second: Int, clean: [GNSSFix]) -> GNSSFix? {
        let now = Double(second)
        var fix: GNSSFix? = clean[second]
        for injection in injections where injection.isActive(at: now) {
            guard let current = fix else { break }
            let elapsed = now - injection.start
            func moved(_ dx: Double, _ dz: Double, velocity: (Double, Double)? = nil) -> GNSSFix {
                var speed = current.speed, course = current.course
                if let velocity, let base = current.velocity {
                    let vx = base.x + velocity.0, vz = base.z + velocity.1
                    speed = hypot(vx, vz)
                    let degrees = atan2(vx, vz) * 180 / Double.pi
                    course = degrees < 0 ? degrees + 360 : degrees
                }
                return GNSSFix(time: current.time, position: FloorPoint(x: current.position.x + dx, z: current.position.z + dz),
                               accuracy: current.accuracy, speed: speed, course: course, speedAccuracy: current.speedAccuracy)
            }
            switch injection.fault {
            case let .jump(dx, dz):
                fix = moved(dx, dz)
            case let .fakeTrack(speed, course):
                let r = course * Double.pi / 180
                fix = moved(speed * elapsed * sin(r), speed * elapsed * cos(r), velocity: (speed * sin(r), speed * cos(r)))
            case let .acceleration(rate, course):
                let r = course * Double.pi / 180, distance = 0.5 * rate * elapsed * elapsed
                fix = moved(distance * sin(r), distance * cos(r), velocity: (rate * elapsed * sin(r), rate * elapsed * cos(r)))
            case let .slowDrift(rate, course):
                let r = course * Double.pi / 180
                fix = moved(rate * elapsed * sin(r), rate * elapsed * cos(r), velocity: (rate * sin(r), rate * cos(r)))
            case .frozenPosition:
                let frozen = clean[min(clean.count - 1, max(0, Int(injection.start)))]
                fix = GNSSFix(time: now, position: frozen.position, accuracy: frozen.accuracy, speed: 0, course: -1,
                              speedAccuracy: current.speedAccuracy)
            case let .delayed(by):
                fix = clean[max(0, second - Int(by))]
            case .dropout:
                fix = nil
            case .jamming:
                guard elapsed < 10 else { fix = nil; break }
                var random = DeterministicRandom(seed: UInt32(truncatingIfNeeded: second) &* 7_919)
                let accuracy = 10 + 9 * elapsed
                fix = GNSSFix(time: now, position: FloorPoint(x: current.position.x + accuracy / 1.515 * random.gauss(),
                                                              z: current.position.z + accuracy / 1.515 * random.gauss()),
                              accuracy: accuracy)
            case let .replay(lag):
                let old = clean[max(0, second - Int(lag))]
                fix = GNSSFix(time: now, position: old.position, accuracy: old.accuracy, speed: old.speed, course: old.course,
                              speedAccuracy: old.speedAccuracy)
            }
        }
        return fix
    }
}

extension GNSSSimulatedWorld {
    /// One second of the world as the GhostCore pipeline would receive it: this phone's raw fix
    /// (after faults) and motion, and each heard peer or beacon with its position. Every record is
    /// marked simulated.
    public struct ContractInputs {
        public let fix: PositionEstimate?
        public let motion: MotionObservation?
        public let peers: [(observation: PeerObservation, position: PositionEstimate)]
    }

    /// `epoch` is the Unix time of second 0. A fix outside the frame's coordinate limit is dropped,
    /// as the app would never produce it.
    public func contractInputs(second: Int, subjectId: String = "phone-c", frameId: String = GeoFrame.defaultFrameId,
                               epoch: Double = 1_793_000_000) -> ContractInputs {
        func provenance(_ producer: String, gnss: Bool) -> Provenance {
            Provenance(producerId: producer, algorithm: "gnss-harness@1", gnssDependent: gnss, simulated: true)
        }
        func inFrame(_ point: FloorPoint) -> Bool {
            abs(point.x) <= GhostCoreContract.maxCoordinate && abs(point.z) <= GhostCoreContract.maxCoordinate
        }
        var fix: PositionEstimate?
        if let raw = fixes[second], inFrame(raw.position) {
            let velocity = raw.velocity.flatMap { hypot($0.x, $0.z) <= 100 ? FloorVector(x: $0.x, z: $0.z) : nil }
            fix = PositionEstimate(
                subjectId: subjectId, timestamp: epoch + raw.time, frameId: frameId, kind: .measured, method: .gnss,
                position: Position(x: raw.position.x, y: 0, z: raw.position.z),
                uncertainty: PositionUncertainty(r95: PositionUncertainty.r95(fromRadius68: raw.accuracy)),
                velocity: velocity, lastAbsoluteAt: epoch + raw.time, source: .gnss,
                freshness: Freshness(maxAge: 30), provenance: provenance(subjectId, gnss: true))
        }
        let motion = self.motion[second].map { step in
            MotionObservation(
                subjectId: subjectId, timestamp: epoch + step.end, interval: step.end - step.start, frameId: frameId,
                method: .pedometer, displacement: FloorVector(x: step.dx, z: step.dz), stationary: step.stationary,
                uncertainty: .init(displacementR95: PositionUncertainty.r95(fromSigma: step.sigma), headingSigma: nil),
                freshness: Freshness(maxAge: 5), provenance: provenance(subjectId, gnss: false))
        }
        var peers: [(observation: PeerObservation, position: PositionEstimate)] = []
        let heard = zip(peerReports[second], peerRSSI[second]).map { ($0, $1, false) }
            + zip(anchorReports[second], anchorRSSI[second]).map { ($0, $1, true) }
        for (report, rssi, surveyed) in heard where inFrame(report.peerPosition) {
            let clamped = min(20, max(-127, rssi))
            let observation = PeerObservation(
                observerId: subjectId, peerId: report.peerId, timestamp: epoch + report.time, frameId: frameId,
                channel: .connection, linkState: .ready, rawRSSI: [clamped], window: 1, smoothedRSSI: clamped,
                uncertainty: .init(stdDevDb: nil, sampleCount: 1), freshness: Freshness(maxAge: 5),
                provenance: provenance(subjectId, gnss: false))
            let point = Position(x: report.peerPosition.x, y: 0, z: report.peerPosition.z)
            let uncertainty = PositionUncertainty(r95: PositionUncertainty.r95(fromSigma: report.peerSigma))
            let position = surveyed
                ? PositionEstimate(subjectId: report.peerId, timestamp: epoch + report.time, frameId: frameId,
                                   kind: .declared, method: .manual, position: point, uncertainty: uncertainty,
                                   source: .manual, freshness: Freshness(maxAge: 3_600),
                                   provenance: provenance(report.peerId, gnss: false))
                : PositionEstimate(subjectId: report.peerId, timestamp: epoch + report.time, frameId: frameId,
                                   kind: .measured, method: .gnss, position: point, uncertainty: uncertainty,
                                   lastAbsoluteAt: epoch + report.time, source: .gnss, freshness: Freshness(maxAge: 30),
                                   provenance: provenance(report.peerId, gnss: true))
            peers.append((observation, position))
        }
        return ContractInputs(fix: fix, motion: motion, peers: peers)
    }
}

public struct GNSSRunMetrics: Equatable {
    /// Seconds with no fault yet (after warm-up), and those flagged as anomalies anyway.
    public let cleanEpochs: Int
    public let falseAlarmEpochs: Int
    /// Separate false-alarm episodes, and how many of them reached `rejected`.
    public let falseAlarmEvents: Int
    public let falseRejectEpochs: Int
    /// Flagged clean seconds in which the fix really was off by more than `justifiedError` (urban
    /// multipath): no fault was injected, but GNSS was wrong.
    public let justifiedAlarmEpochs: Int
    /// Clean seconds marked `trusted`: what honesty costs in availability.
    public let trustedCleanEpochs: Int
    public let faultEpochs: Int
    public let detected: Bool
    /// Seconds from the fault's start to the first flag.
    public let detectionDelay: TimeInterval?
    /// How far the delivered fix was from the truth when first flagged, meters.
    public let errorAtDetection: Double?
    /// Seconds in the fault when a fix still marked usable was off by more than the alert limit and
    /// by more than 3.5 times its recommended sigma: misleading information.
    public let misleadingEpochs: Int
    /// The same, while marked `trusted`: integrity failures.
    public let trustedButWrongEpochs: Int
    /// Largest error of a fix still usable during the fault, meters.
    public let maxUndetectedError: Double
    /// Seconds from the end of the fault to `trusted` again; nil if it never was.
    public let retrustDelay: TimeInterval?
}

public struct GNSSRunResult {
    public let scenario: String
    public let config: String
    public let seed: UInt32
    public let assessments: [GNSSIntegrityAssessment]
    /// Index = second; distance of the delivered fix from the truth.
    public let errors: [Double?]
    public let metrics: GNSSRunMetrics
}

public struct GNSSComparisonRow: Equatable {
    public let scenario: String
    public let config: String
    public let runs: Int
    public let detectedRuns: Int
    public let medianDelay: TimeInterval?
    public let maxDelay: TimeInterval?
    public let medianErrorAtDetection: Double?
    public let falseAlarmEpochs: Int
    public let cleanEpochs: Int
    public let falseAlarmEvents: Int
    public let falseRejectEpochs: Int
    public let justifiedAlarmEpochs: Int
    public let trustedCleanEpochs: Int
    public let misleadingEpochs: Int
    public let trustedButWrongEpochs: Int
    public let maxUndetectedError: Double
    public let minRetrustDelay: TimeInterval?
    public let expectsAnomaly: Bool
    public let hasFault: Bool

    public var missedRuns: Int { hasFault ? runs - detectedRuns : 0 }
    public var falseAlarmRate: Double { cleanEpochs == 0 ? 0 : Double(falseAlarmEpochs) / Double(cleanEpochs) }
}

public enum GNSSFaultHarness {
    /// Seconds ignored at the start of a run.
    public static let warmUp = 10
    /// Position error beyond which a usable fix is hazardous for someone on foot, meters.
    public static let alertLimit = 30.0
    /// A flag on clean data is justified when the fix really was off by more than this, meters.
    public static let justifiedError = 20.0

    public static func run(_ world: GNSSSimulatedWorld, config: GNSSDetectorConfig) -> GNSSRunResult {
        let engine = GNSSIntegrityEngine(options: config.options)
        let scenario = world.scenario
        var assessments: [GNSSIntegrityAssessment] = []
        var errors: [Double?] = [nil]
        for second in 1...scenario.duration {
            let now = Double(second)
            if config.useInertial, let motion = world.motion[second] { engine.addMotion(motion) }
            if config.usePeers { world.peerReports[second].forEach(engine.addPeer) }
            if config.useAnchors { world.anchorReports[second].forEach(engine.addPeer) }
            if let fix = world.fixes[second] {
                assessments.append(engine.assess(fix, at: now))
                errors.append(GNSSIntegrityEngine.distance(fix.position, world.truth[second]))
            } else {
                assessments.append(engine.assess(at: now))
                errors.append(nil)
            }
        }
        return GNSSRunResult(scenario: scenario.name, config: config.name, seed: world.seed, assessments: assessments,
                             errors: errors, metrics: metrics(scenario: scenario, assessments: assessments, errors: errors))
    }

    static func metrics(scenario: GNSSScenario, assessments: [GNSSIntegrityAssessment], errors: [Double?]) -> GNSSRunMetrics {
        let faultStart = scenario.injections.map(\.start).min()
        let detectionStart = scenario.detectionStart
        let faultEnd = scenario.injections.contains { $0.end == nil }
            ? nil : scenario.injections.compactMap(\.end).max()
        let flags: (GNSSIntegrityStatus) -> Bool = scenario.expectsAnomaly
            ? { $0.isAnomaly }
            : { $0 != .trusted && $0 != .insufficientEvidence }
        var clean = 0, falseEpochs = 0, falseEvents = 0, falseRejects = 0, justified = 0, trustedClean = 0
        var faultEpochs = 0, misleading = 0, trustedWrong = 0
        var wasFalse = false
        var delay: TimeInterval?, errorAtDetection: Double?, retrust: TimeInterval?
        var maxUndetected = 0.0
        for (index, assessment) in assessments.enumerated() {
            let second = index + 1
            let time = Double(second)
            let error = errors[second]
            if let faultStart, time >= faultStart {
                if let faultEnd, time >= faultEnd {
                    if retrust == nil, assessment.status == .trusted { retrust = time - faultEnd }
                    continue
                }
                faultEpochs += 1
                if delay == nil, let detectionStart, time >= detectionStart, flags(assessment.status) {
                    delay = time - detectionStart
                    errorAtDetection = error
                }
                if assessment.usableAsPosition, let error {
                    maxUndetected = max(maxUndetected, error)
                    let stated = 3.5 * (assessment.uncertainty.recommendedSigma ?? 0)
                    if error > max(alertLimit, stated) {
                        misleading += 1
                        if assessment.status == .trusted { trustedWrong += 1 }
                    }
                }
            } else if second >= warmUp {
                clean += 1
                if assessment.status == .trusted { trustedClean += 1 }
                if assessment.status == .rejected { falseRejects += 1 }
                let flagged = assessment.isAnomaly
                if flagged {
                    falseEpochs += 1
                    if !wasFalse { falseEvents += 1 }
                    if let error, error > justifiedError { justified += 1 }
                }
                wasFalse = flagged
            }
        }
        return GNSSRunMetrics(cleanEpochs: clean, falseAlarmEpochs: falseEpochs, falseAlarmEvents: falseEvents,
                              falseRejectEpochs: falseRejects, justifiedAlarmEpochs: justified,
                              trustedCleanEpochs: trustedClean,
                              faultEpochs: faultEpochs, detected: delay != nil, detectionDelay: delay,
                              errorAtDetection: errorAtDetection, misleadingEpochs: misleading,
                              trustedButWrongEpochs: trustedWrong, maxUndetectedError: maxUndetected,
                              retrustDelay: retrust)
    }

    /// Runs every scenario on every seed through every configuration.
    public static func compare(scenarios: [GNSSScenario] = GNSSScenario.library,
                               configs: [GNSSDetectorConfig] = GNSSDetectorConfig.all,
                               seeds: [UInt32] = Array(1...5)) -> [GNSSComparisonRow] {
        var rows: [GNSSComparisonRow] = []
        for scenario in scenarios {
            let worlds = seeds.map { GNSSSimulatedWorld(scenario: scenario, seed: $0) }
            for config in configs {
                let results = worlds.map { run($0, config: config).metrics }
                let delays = results.compactMap(\.detectionDelay).sorted()
                let errors = results.compactMap(\.errorAtDetection).sorted()
                rows.append(GNSSComparisonRow(
                    scenario: scenario.name, config: config.name, runs: results.count,
                    detectedRuns: results.filter(\.detected).count,
                    medianDelay: delays.isEmpty ? nil : delays[delays.count / 2], maxDelay: delays.last,
                    medianErrorAtDetection: errors.isEmpty ? nil : errors[errors.count / 2],
                    falseAlarmEpochs: results.map(\.falseAlarmEpochs).reduce(0, +),
                    cleanEpochs: results.map(\.cleanEpochs).reduce(0, +),
                    falseAlarmEvents: results.map(\.falseAlarmEvents).reduce(0, +),
                    falseRejectEpochs: results.map(\.falseRejectEpochs).reduce(0, +),
                    justifiedAlarmEpochs: results.map(\.justifiedAlarmEpochs).reduce(0, +),
                    trustedCleanEpochs: results.map(\.trustedCleanEpochs).reduce(0, +),
                    misleadingEpochs: results.map(\.misleadingEpochs).reduce(0, +),
                    trustedButWrongEpochs: results.map(\.trustedButWrongEpochs).reduce(0, +),
                    maxUndetectedError: results.map(\.maxUndetectedError).max() ?? 0,
                    minRetrustDelay: results.compactMap(\.retrustDelay).min(),
                    expectsAnomaly: scenario.expectsAnomaly, hasFault: !scenario.injections.isEmpty))
            }
        }
        return rows
    }

    /// The comparison as a Markdown table.
    public static func markdown(_ rows: [GNSSComparisonRow]) -> String {
        var lines = [
            "| Scenario | Detector | Detected | Delay median / max | Offset at detection | Clean-data alarms: s / episodes / rejected s / s with GPS really > \(Int(justifiedError)) m off, of clean s | Trusted share (clean) | Misleading s (of them trusted) | Max undetected error |",
            "|---|---|---|---|---|---|---|---|---|",
        ]
        func seconds(_ value: TimeInterval?) -> String { value.map { "\(Int($0)) s" } ?? "–" }
        func meters(_ value: Double?) -> String { value.map { "\(Int($0.rounded())) m" } ?? "–" }
        for row in rows {
            let detected = row.hasFault ? "\(row.detectedRuns)/\(row.runs)" : "–"
            let delay = row.hasFault ? "\(seconds(row.medianDelay)) / \(seconds(row.maxDelay))" : "–"
            let falseAlarms = row.cleanEpochs == 0 ? "–"
                : "\(row.falseAlarmEpochs) / \(row.falseAlarmEvents) / \(row.falseRejectEpochs) / \(row.justifiedAlarmEpochs) of \(row.cleanEpochs)"
            let trusted = row.cleanEpochs == 0 ? "–"
                : "\(Int((100 * Double(row.trustedCleanEpochs) / Double(row.cleanEpochs)).rounded())) %"
            let hazard = row.hasFault ? "\(row.misleadingEpochs) (\(row.trustedButWrongEpochs))" : "–"
            let undetected = row.hasFault ? meters(row.maxUndetectedError) : "–"
            lines.append("| \(row.scenario) | \(row.config) | \(detected) | \(delay) | \(meters(row.medianErrorAtDetection)) | \(falseAlarms) | \(trusted) | \(hazard) | \(undetected) |")
        }
        return lines.joined(separator: "\n")
    }
}
