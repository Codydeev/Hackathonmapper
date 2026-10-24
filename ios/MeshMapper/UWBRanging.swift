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

/// One Nearby Interaction session per neighbor; both phones run a session configured with the
/// other's token, swapped over the BLE link. All callbacks and callers run on the main queue.
final class UWBRanging: NSObject, ObservableObject, NISessionDelegate {
    /// A session that has measured nothing this long resends its token, in case the swap was lost.
    static let tokenRetry: TimeInterval = 5
    /// Wait before reopening a session iOS refused or invalidated.
    static let reopenDelay: TimeInterval = 30
    /// Nearby Interaction reports many times a second; the UI list refreshes at most this often.
    static let displayInterval: TimeInterval = 0.5

    static var supportsDistance: Bool { NISession.deviceCapabilities.supportsPreciseDistanceMeasurement }
    /// False on many iPhones with the second-generation UWB chip (U2) unless the phone moves with
    /// camera assistance, which a mounted anchor cannot do. Only phones reporting true can be anchors.
    static var supportsDirection: Bool { NISession.deviceCapabilities.supportsDirectionMeasurement }

    @Published private(set) var measurements: [String: UWBMeasurement] = [:]
    @Published private(set) var lastError: String?
    /// Archived token for a neighbor, to send over the BLE link.
    var sendToken: ((Data, String) -> Void)?
    var onMeasurement: ((String, UWBMeasurement) -> Void)?

    private struct Peer {
        let session: NISession
        var peerToken: Data?
        var tokenSentAt: Date?
    }

    private var peers: [String: Peer] = [:]
    private var reopenAfter: [String: Date] = [:]
    private var running = false
    private let motion = CMMotionManager()

    /// Gravity in the device frame (g units), or nil when Core Motion has no sample yet.
    var gravity: Vector3? {
        motion.deviceMotion.map { Vector3($0.gravity.x, $0.gravity.y, $0.gravity.z) }
    }

    func start(measuresTilt: Bool) {
        running = true
        lastError = nil
        if measuresTilt, motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive {
            motion.deviceMotionUpdateInterval = 0.1
            motion.startDeviceMotionUpdates()
        }
    }

    func reportError(_ message: String) {
        if lastError != message { lastError = message }
    }

    func stop() {
        running = false
        motion.stopDeviceMotionUpdates()
        for peer in peers.values { peer.session.invalidate() }
        peers.removeAll()
        reopenAfter.removeAll()
        measurements.removeAll()
    }

    /// Keeps sessions with exactly `wanted` neighbors and resends tokens that got no answer.
    func reconcile(wanted: Set<String>, at now: Date = Date()) {
        guard running else { return }
        for id in Set(peers.keys).subtracting(wanted) { remove(id) }
        for id in wanted {
            if peers[id] == nil {
                guard now >= reopenAfter[id] ?? .distantPast, openSession(for: id) else { continue }
            }
            if measurements[id] == nil, now.timeIntervalSince(peers[id]?.tokenSentAt ?? .distantPast) >= Self.tokenRetry {
                sendOwnToken(to: id, at: now)
            }
        }
    }

    /// A neighbor's token arrived. Runs our session with it; answers with our token when the
    /// neighbor's token changed, since it may have restarted and lost ours.
    func receive(token data: Data, from id: String) {
        guard running else { return }
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) else {
            lastError = "Invalid UWB token from \(id.prefix(8))"
            return
        }
        let isNewSession = peers[id] == nil
        if isNewSession, Date() < reopenAfter[id] ?? .distantPast || !openSession(for: id) { return }
        let changed = peers[id]?.peerToken != data
        peers[id]?.peerToken = data
        if changed { peers[id]?.session.run(NINearbyPeerConfiguration(peerToken: token)) }
        if changed || isNewSession { sendOwnToken(to: id) }
    }

    @discardableResult
    private func openSession(for id: String) -> Bool {
        let session = NISession()
        session.delegate = self
        session.delegateQueue = .main
        guard session.discoveryToken != nil else {
            lastError = "UWB is not available on this iPhone"
            return false
        }
        peers[id] = Peer(session: session)
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
        measurements[id] = nil
    }

    private func peerId(for session: NISession) -> String? {
        peers.first { $0.value.session === session }?.key
    }

    // MARK: NISessionDelegate

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let id = peerId(for: session), let object = nearbyObjects.first else { return }
        let measurement = UWBMeasurement(
            distance: object.distance.map { Double($0) },
            direction: object.direction.map { Vector3(Double($0.x), Double($0.y), Double($0.z)) },
            updatedAt: Date())
        let shown = measurements[id]
        if shown == nil || (shown?.direction == nil) != (measurement.direction == nil)
            || measurement.updatedAt.timeIntervalSince(shown?.updatedAt ?? .distantPast) >= Self.displayInterval {
            measurements[id] = measurement
        }
        onMeasurement?(id, measurement)
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard let id = peerId(for: session) else { return }
        measurements[id] = nil
        // On timeout the peer may come back; rerun the same configuration. On peerEnded, wait for a new token.
        if reason == .timeout, let config = session.configuration { session.run(config) }
    }

    func sessionWasSuspended(_ session: NISession) {
        guard let id = peerId(for: session) else { return }
        measurements[id] = nil
    }

    func sessionSuspensionEnded(_ session: NISession) {
        if let config = session.configuration { session.run(config) }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        guard let id = peerId(for: session) else { return }
        // Start over with a fresh session after a pause; reconcile opens it and swaps tokens again.
        peers[id] = nil
        measurements[id] = nil
        reopenAfter[id] = Date().addingTimeInterval(Self.reopenDelay)
        lastError = (error as? NIError)?.code == .activeSessionsLimitExceeded
            ? "Too many UWB sessions on this iPhone; fewer phones can be measured at once"
            : error.localizedDescription
    }
}
