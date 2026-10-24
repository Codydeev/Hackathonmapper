import Combine
import CoreLocation
import CoreMotion
import Foundation
import MeshCore

/// Luotsi's GPS check, on the phone: every fix is judged against this phone's own steps, compass
/// and stillness (MeshCore `TrustEngine`, six witnesses), so jammed or spoofed GPS is caught and
/// the phone stops sharing it. The others then place it over Bluetooth, as for any phone without
/// GPS. A demo attacker can jam or spoof this phone's real GPS stream, and only this phone's.
@MainActor
final class GPSGuard: ObservableObject {
    /// A fix as this phone's receiver reports it, after any demo attack.
    struct Fix {
        let latitude: Double
        let longitude: Double
        let accuracy: Double
        let receivedAt: Date
    }

    enum Level { case good, info, warn, bad }

    @Published private(set) var state: TrustState?
    @Published private(set) var attack: GPSAttack?
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "gpsCheck") } }
    @Published private(set) var motionAvailable = false
    @Published private(set) var stepCount = 0
    private(set) var latestFix: Fix?

    private let location: LocationSource
    private var engine = TrustEngine()
    private var attacker: GPSAttacker
    private let motion = CMMotionManager()
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?
    /// Local frame of the engine: metres east (x) and north (y) of the shared frame's GPS origin.
    private let origin: (latitude: Double, longitude: Double)
    private static let metersPerDegree = 6_371_008.8 * Double.pi / 180

    // Step and stillness detector (Luotsi sensors.js), on accelerometer magnitude in m/s².
    private var fast: Double?
    private var slow: Double?
    private var armed = false
    private var lastStep = -Double.infinity
    private var magnitudes: [(t: Double, m: Double)] = []
    private var isStill = false
    private var heading: Double?

    init(location: LocationSource) {
        self.location = location
        let origin = GeoFrame.origins[GeoFrame.defaultFrameId].map { ($0.latitude, $0.longitude) } ?? (61.4499, 23.8560)
        self.origin = origin
        enabled = UserDefaults.standard.object(forKey: "gpsCheck") as? Bool ?? true
        attacker = GPSAttacker(teleportTo: Self.local(origin, latitude: GPSAttacker.pulkovo.latitude,
                                                      longitude: GPSAttacker.pulkovo.longitude))
    }

    /// Monotonic seconds, the same clock as Core Motion timestamps.
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func start() {
        guard timer == nil else { return }
        location.$latest
            .compactMap { $0 }
            .removeDuplicates { $0.timestamp == $1.timestamp }
            .sink { [weak self] in self?.receive($0) }
            .store(in: &cancellables)
        location.$heading
            .compactMap { $0 }
            .sink { [weak self] in self?.receive($0) }
            .store(in: &cancellables)
        if motion.isDeviceMotionAvailable {
            motionAvailable = true
            motion.deviceMotionUpdateInterval = 1.0 / 60
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                MainActor.assumeIsolated { self?.receive(data) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func setAttack(_ attack: GPSAttack?) {
        if let attack { attacker.start(attack, t: now) } else { attacker.stop() }
        self.attack = attack
    }

    /// Whether this phone may share its GPS: while the check trusts it, or during the very first
    /// check after launch (nothing has gone wrong yet). With the check off, always.
    var allowsGPS: Bool {
        guard enabled, let state else { return true }
        if state.usesGNSS { return true }
        return (state.verdict == .initial || state.verdict == .verifying) && state.deadReckoning == nil
    }

    /// The latest (possibly attacked) fix if it is fresh and precise enough to place the phone.
    func usableFix(maxAccuracy: Double, maxAge: TimeInterval, at date: Date = Date()) -> Fix? {
        guard let fix = latestFix, fix.accuracy >= 0, fix.accuracy <= maxAccuracy,
              date.timeIntervalSince(fix.receivedAt) <= maxAge else { return nil }
        return fix
    }

    /// One line for the status card; nil while the check is off or has seen no fix yet.
    var summary: (text: String, level: Level)? {
        guard enabled, let state else { return nil }
        let prefix = attack.map { "Demo attack (\(Self.label($0))) · " } ?? ""
        switch state.verdict {
        case .initial: return attack == nil ? nil : (prefix + "waiting for a fix", .info)
        case .verifying: return (prefix + "Checking GPS against your steps…", .info)
        case .trusted: return (prefix + "GPS checked against your steps: trusted", .good)
        case .suspect: return (prefix + "GPS suspicious: \(state.reason)", .warn)
        case .rejected: return (prefix + "GPS rejected: \(state.reason)", .bad)
        case .nosignal: return (prefix + state.reason, .bad)
        }
    }

    static func label(_ attack: GPSAttack) -> String {
        switch attack {
        case .jam: return "Jamming"
        case .teleport: return "Spoof: teleport"
        case .drag: return "Spoof: slow drag"
        }
    }

    // MARK: - Inputs

    private func receive(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0 else { return }
        let t = now
        let p = Self.local(origin, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        // A jammed receiver reports nothing: the last fix simply ages.
        guard let fix = attacker.apply(t: t, x: p.x, y: p.y, accuracy: location.horizontalAccuracy) else { return }
        engine.onFix(t: t, x: fix.x, y: fix.y, accuracy: fix.accuracy)
        let c = coordinate(x: fix.x, y: fix.y)
        latestFix = Fix(latitude: c.latitude, longitude: c.longitude, accuracy: fix.accuracy, receivedAt: Date())
        state = engine.state(t: t)
    }

    private func receive(_ heading: CLHeading) {
        let degrees = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        guard degrees >= 0 else { return }
        let h = degrees * Double.pi / 180
        // Smoothed like the Luotsi web app: a quarter of the way to each new reading.
        if let current = self.heading {
            self.heading = current + 0.25 * atan2(sin(h - current), cos(h - current))
        } else {
            self.heading = h
        }
        engine.onHeading(self.heading!)
    }

    /// Steps from the accelerometer magnitude (fast vs slow average), stillness from its spread.
    private func receive(_ data: CMDeviceMotion) {
        let t = data.timestamp
        let g = 9.81
        let m = g * ((data.gravity.x + data.userAcceleration.x) * (data.gravity.x + data.userAcceleration.x)
            + (data.gravity.y + data.userAcceleration.y) * (data.gravity.y + data.userAcceleration.y)
            + (data.gravity.z + data.userAcceleration.z) * (data.gravity.z + data.userAcceleration.z)).squareRoot()
        let f = fast.map { $0 + 0.25 * (m - $0) } ?? m
        let s = slow.map { $0 + 0.02 * (m - $0) } ?? m
        fast = f
        slow = s
        let d = f - s
        if !armed && d > 1.1 { armed = true }
        if armed && d < 0 {
            armed = false
            if t - lastStep > 0.3 {
                lastStep = t
                stepCount += 1
                engine.onStep(t: t, heading: heading)
            }
        }
        magnitudes.append((t, m))
        magnitudes.removeAll { $0.t < t - 1.5 }
        if magnitudes.count > 10 {
            let mean = magnitudes.reduce(0) { $0 + $1.m } / Double(magnitudes.count)
            let sd = (magnitudes.reduce(0) { $0 + ($1.m - mean) * ($1.m - mean) } / Double(magnitudes.count)).squareRoot()
            let still = sd < 0.18 && t - lastStep > 2
            if still != isStill {
                isStill = still
                engine.onMotion(t: t, still: still)
            }
        }
    }

    private func tick() {
        let t = now
        engine.tick(t: t)
        state = engine.state(t: t)
    }

    // MARK: - Frame

    /// Equirectangular metres around the origin, without the dashboard's ±10 km limit, so a
    /// teleport hundreds of kilometres away can still be judged.
    private static func local(_ origin: (latitude: Double, longitude: Double), latitude: Double,
                              longitude: Double) -> (x: Double, y: Double) {
        ((longitude - origin.longitude) * metersPerDegree * cos(origin.latitude * Double.pi / 180),
         (latitude - origin.latitude) * metersPerDegree)
    }

    private func coordinate(x: Double, y: Double) -> (latitude: Double, longitude: Double) {
        (origin.latitude + y / Self.metersPerDegree,
         origin.longitude + x / (Self.metersPerDegree * cos(origin.latitude * Double.pi / 180)))
    }
}
