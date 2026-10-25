import Combine
import CoreMotion
import Foundation
import MeshCore
import NearbyInteraction

/// Latest UWB measurement to one neighbor. `direction` is in this phone's device frame.
struct UWBMeasurement {
    let distance: Double?
    let direction: Vector3?
    let updatedAt: Date
}

/// Latest UWB distance to one neighbor, updated with every measurement.
struct UWBReading {
    let distance: Double
    let at: Date
}

/// One Nearby Interaction session per selected neighbor (`UWBSessionPolicy`); both phones run a
/// session configured with the other's token, swapped over the BLE link. UWB is never on the mesh's
/// critical path: a denied permission or a refused session only means fewer UWB distances.
/// All callbacks and callers run on the main queue.
final class UWBRanging: NSObject, ObservableObject, NISessionDelegate {
    /// A session that has measured nothing this long resends its token, in case the swap was lost.
    static let tokenRetry: TimeInterval = 5
    /// A session with no new token and no measurement for this long is closed, so it frees its slot.
    static let progressTimeout: TimeInterval = 20
    /// How long a neighbor that never answered or measured is left out before trying again.
    static let silentCooldown: TimeInterval = 60
    /// Wait before reopening a session iOS refused or invalidated.
    static let reopenDelay: TimeInterval = 30
    /// Nearby Interaction reports many times a second; the UI list refreshes at most this often.
    static let displayInterval: TimeInterval = 0.5
    /// A session counts as measuring while its last distance is at most this old.
    static let measuringWindow: TimeInterval = 3

    static var supportsDistance: Bool { NISession.deviceCapabilities.supportsPreciseDistanceMeasurement }
    /// False on many iPhones with the second-generation UWB chip (U2) unless the phone moves with
    /// camera assistance, which a mounted anchor cannot do. Only phones reporting true can be anchors.
    static var supportsDirection: Bool { NISession.deviceCapabilities.supportsDirectionMeasurement }

    @Published private(set) var measurements: [String: UWBMeasurement] = [:]
    @Published private(set) var lastError: String?
    /// Concurrent sessions this phone tries to run; shrinks when iOS refuses one, resets on `stop()`.
    @Published private(set) var sessionBudget = UWBSessionPolicy.initialBudget
    /// The user denied Nearby Interaction; no sessions are opened until UWB is stopped and started again.
    @Published private(set) var permissionDenied = false
    /// Latest distance per neighbor, updated with every measurement (not throttled like `measurements`).
    private(set) var readings: [String: UWBReading] = [:]
    /// Archived token for a neighbor, to send over the BLE link.
    var sendToken: ((Data, String) -> Void)?
    var onMeasurement: ((String, UWBMeasurement) -> Void)?

    private struct Peer {
        let session: NISession
        var peerToken: Data?
        var tokenSentAt: Date?
        /// Session opened, a new peer token received or a distance measured, whichever is latest.
        var progressAt: Date
    }

    private var peers: [String: Peer] = [:]
    private var reopenAfter: [String: Date] = [:]
    private var silentUntil: [String: Date] = [:]
    private var measuringStart: [String: Date] = [:]
    private var running = false
    private let motion = CMMotionManager()

    var isRunning: Bool { running }
    /// Running and allowed to range.
    var isActive: Bool { running && !permissionDenied }
    /// A session is open for another neighbor without going over the budget.
    var hasFreeSlot: Bool { peers.count < sessionBudget }

    /// Gravity in the device frame (g units), or nil when Core Motion has no sample yet.
    var gravity: Vector3? {
        motion.deviceMotion.map { Vector3($0.gravity.x, $0.gravity.y, $0.gravity.z) }
    }

    /// Starts ranging, or only changes whether gravity is measured when it is already running.
    /// A mounted direction anchor needs gravity for its tilt.
    func start(measuresTilt: Bool) {
        if !running {
            running = true
            lastError = nil
        }
        if measuresTilt, motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive {
            motion.deviceMotionUpdateInterval = 0.1
            motion.startDeviceMotionUpdates()
        } else if !measuresTilt, motion.isDeviceMotionActive {
            motion.stopDeviceMotionUpdates()
        }
    }

    func reportError(_ message: String) {
        if lastError != message { lastError = message }
    }

    /// Stops every session. A later start begins afresh: full budget, and permission asked again.
    func stop() {
        running = false
        motion.stopDeviceMotionUpdates()
        for peer in peers.values { peer.session.invalidate() }
        peers.removeAll()
        reopenAfter.removeAll()
        silentUntil.removeAll()
        measuringStart.removeAll()
        readings.removeAll()
        measurements.removeAll()
        sessionBudget = UWBSessionPolicy.initialBudget
        permissionDenied = false
        lastError = nil
    }

    func hasSession(_ id: String) -> Bool { peers[id] != nil }

    /// Left out of selection for now: refused by iOS, or silent after a token swap.
    func isCoolingDown(_ id: String, at now: Date = Date()) -> Bool {
        now < reopenAfter[id] ?? .distantPast || now < silentUntil[id] ?? .distantPast
    }

    /// When the current session to `id` started measuring, if it is measuring now.
    func measuringSince(_ id: String, at now: Date = Date()) -> Date? {
        guard let reading = readings[id], now.timeIntervalSince(reading.at) <= Self.measuringWindow else { return nil }
        return measuringStart[id]
    }

    /// The latest distance to `id` if it is at most `maxAge` old.
    func reading(for id: String, at now: Date = Date(), maxAge: TimeInterval = 2) -> UWBReading? {
        guard let reading = readings[id], now.timeIntervalSince(reading.at) <= maxAge else { return nil }
        return reading
    }

    /// Keeps sessions with exactly `wanted` neighbors, resends tokens that got no answer and closes
    /// sessions that make no progress.
    func reconcile(wanted: Set<String>, at now: Date = Date()) {
        guard isActive else {
            for id in Array(peers.keys) { remove(id) }
            return
        }
        for id in Set(peers.keys).subtracting(wanted) { remove(id) }
        for id in wanted.sorted() {
            if let peer = peers[id], now.timeIntervalSince(peer.progressAt) > Self.progressTimeout {
                remove(id)
                silentUntil[id] = now.addingTimeInterval(Self.silentCooldown)
                continue
            }
            if peers[id] == nil {
                guard !isCoolingDown(id, at: now), openSession(for: id, at: now) else { continue }
            }
            if reading(for: id, at: now, maxAge: Self.tokenRetry) == nil,
               now.timeIntervalSince(peers[id]?.tokenSentAt ?? .distantPast) >= Self.tokenRetry {
                sendOwnToken(to: id, at: now)
            }
        }
    }

    /// A neighbor's token arrived and the caller wants a session with it. Runs our session with it;
    /// answers with our token when the neighbor's token changed, since it may have restarted and lost ours.
    func receive(token data: Data, from id: String) {
        guard isActive else { return }
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) else {
            lastError = "Invalid UWB token from \(id.prefix(8))"
            return
        }
        let now = Date()
        silentUntil[id] = nil
        let isNewSession = peers[id] == nil
        if isNewSession, now < reopenAfter[id] ?? .distantPast || !openSession(for: id, at: now) { return }
        let changed = peers[id]?.peerToken != data
        peers[id]?.peerToken = data
        // A resent, unchanged token is no progress: otherwise a pair in BLE range but out of UWB range
        // would keep both slots forever, since both ends resend every `tokenRetry`.
        if changed { peers[id]?.progressAt = now }
        if changed { peers[id]?.session.run(NINearbyPeerConfiguration(peerToken: token)) }
        if changed || isNewSession { sendOwnToken(to: id, at: now) }
    }

    /// The neighbor answered, so it is not silent any more.
    func peerAnswered(_ id: String) {
        silentUntil[id] = nil
    }

    @discardableResult
    private func openSession(for id: String, at now: Date) -> Bool {
        let session = NISession()
        session.delegate = self
        session.delegateQueue = .main
        guard session.discoveryToken != nil else {
            lastError = "UWB is not available on this iPhone"
            return false
        }
        peers[id] = Peer(session: session, progressAt: now)
        return true
    }

    private func sendOwnToken(to id: String, at now: Date = Date()) {
        guard let token = peers[id]?.session.discoveryToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { return }
        peers[id]?.tokenSentAt = now
        sendToken?(data, id)
    }

    private func remove(_ id: String) {
        peers.removeValue(forKey: id)?.session.invalidate()
        clearMeasurement(id)
    }

    private func clearMeasurement(_ id: String) {
        measurements[id] = nil
        readings[id] = nil
        measuringStart[id] = nil
    }

    private func peerId(for session: NISession) -> String? {
        peers.first { $0.value.session === session }?.key
    }

    private static let deniedMessage = "Nearby Interaction is not allowed, so distances come from Bluetooth only. Allow it in Settings › MeshMapper, then turn UWB ranging off and on."

    // MARK: NISessionDelegate

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let id = peerId(for: session), let object = nearbyObjects.first else { return }
        let now = Date()
        let measurement = UWBMeasurement(
            distance: object.distance.map { Double($0) },
            direction: object.direction.map { Vector3(Double($0.x), Double($0.y), Double($0.z)) },
            updatedAt: now)
        if let distance = measurement.distance, distance.isFinite, distance >= 0 {
            readings[id] = UWBReading(distance: distance, at: now)
            if measuringStart[id] == nil { measuringStart[id] = now }
            peers[id]?.progressAt = now
        }
        let shown = measurements[id]
        if shown == nil || (shown?.direction == nil) != (measurement.direction == nil)
            || measurement.updatedAt.timeIntervalSince(shown?.updatedAt ?? .distantPast) >= Self.displayInterval {
            measurements[id] = measurement
        }
        onMeasurement?(id, measurement)
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard let id = peerId(for: session) else { return }
        clearMeasurement(id)
        // On timeout the peer may come back; rerun the same configuration. On peerEnded, wait for a new token.
        if reason == .timeout, let config = session.configuration { session.run(config) }
    }

    func sessionWasSuspended(_ session: NISession) {
        guard let id = peerId(for: session) else { return }
        clearMeasurement(id)
    }

    func sessionSuspensionEnded(_ session: NISession) {
        if let config = session.configuration { session.run(config) }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        guard let id = peerId(for: session) else { return }
        let code = (error as? NIError)?.code
        let active = peers.values.filter { $0.peerToken != nil }.count
        // Start over with a fresh session after a pause; reconcile opens it and swaps tokens again.
        peers[id] = nil
        clearMeasurement(id)
        reopenAfter[id] = Date().addingTimeInterval(Self.reopenDelay)
        if code == .userDidNotAllow {
            // Don't ask again this run: close everything and let the mesh carry on with RSSI.
            permissionDenied = true
            for other in Array(peers.keys) { remove(other) }
            lastError = Self.deniedMessage
        } else if code == .activeSessionsLimitExceeded {
            sessionBudget = min(sessionBudget, UWBSessionPolicy.reducedBudget(active: active))
            lastError = "Too many UWB sessions on this iPhone; measuring at most \(sessionBudget) phones at once"
        } else {
            lastError = error.localizedDescription
        }
    }
}
