import Combine
import Foundation
import MeshCore
import SwiftUI
import UIKit

enum AppTab: Hashable {
    case network, position, gateway
}

enum DeviceRole: String, CaseIterable, Identifiable {
    case mobile, anchor, gateway
    var id: String { rawValue }
}

struct KnownDevice: Identifiable {
    let update: DeviceUpdate
    let receivedAt: Date
    /// Phones that relayed the accepted copy, oldest first; empty if it came straight from the
    /// origin, nil for this phone's own reports.
    let path: [String]?
    var id: String { update.id }
}

struct MeshDiagnostics {
    var received = 0
    var accepted = 0
    var duplicate = 0
    var relayed = 0
    var rejected = 0
}

enum PositionSource: String, CaseIterable, Identifiable {
    case manual, fused
    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "Manual coordinates"
        case .fused: return "Motion + BLE anchors"
        }
    }
}

/// What the Position tab shows of the fusion engine; refreshed each second and on every step.
struct FusionStatus {
    var tracking = false
    var x: Double?
    var z: Double?
    var accuracy: Double?
    var headingDegrees = 0.0
    var headingOffsetDegrees = 0.0
    var steps = 0
    var walked = 0.0
    var walking = false
    var receiverOffsetDB: Double?
    var ranges: [AnchorRange] = []
    var fix: RangeFix?
    var calibration = PathLossCalibration.uncalibrated
    var accepted = 0
    var rejected = 0
    var recoveries = 0
}

@MainActor
final class MeshModel: ObservableObject {
    // Ingesting our own packet consumes one hop, so neighbors receive 4 remaining hops.
    static let originHops = 5
    /// Reports not refreshed within this time are no longer resent or uploaded.
    static let staleAfter: TimeInterval = 30

    let bluetooth = BluetoothMesh()
    let gateway = GatewayClient()
    let motion = MotionTracker()
    let deviceID: String
    let epochID = UUID().uuidString
    @Published var serverURL: String { didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") } }
    // Only the internet (Cloudflare tunnel) endpoint needs it; a LAN URL works without one.
    @Published var gatewayToken: String { didSet { UserDefaults.standard.set(gatewayToken, forKey: "gatewayToken") } }
    @Published var selectedTab: AppTab = .network
    @Published var frameID: String { didSet { UserDefaults.standard.set(frameID, forKey: "frameID") } }
    @Published var label: String {
        didSet {
            if label.utf16.count > DashboardContract.maxLabelLength { label = DashboardContract.truncatedLabel(label) }
            UserDefaults.standard.set(label, forKey: "deviceLabel")
        }
    }
    @Published var role: DeviceRole { didSet { UserDefaults.standard.set(role.rawValue, forKey: "role") } }
    @Published var manualX: Double { didSet { UserDefaults.standard.set(manualX, forKey: "manualX") } }
    @Published var manualY: Double { didSet { UserDefaults.standard.set(manualY, forKey: "manualY") } }
    @Published var manualZ: Double { didSet { UserDefaults.standard.set(manualZ, forKey: "manualZ") } }
    @Published var positionSource: PositionSource {
        didSet { UserDefaults.standard.set(positionSource.rawValue, forKey: "positionSource") }
    }
    @Published private(set) var fusionStatus = FusionStatus()
    @Published var positionMode = "floor"
    @Published var accuracyKnown = false
    @Published var accuracyMeters = 1.0
    @Published var keepAwake = true { didSet { updateIdleTimer() } }
    @Published private(set) var devices: [KnownDevice] = []
    @Published private(set) var diagnostics = MeshDiagnostics()
    @Published private(set) var isRunning = false
    @Published private(set) var isPublishing = false
    @Published private(set) var lastSequence: Int?
    @Published private(set) var lastError: String?
    /// Direct BLE neighbors by app device ID, as included in this phone's last report.
    @Published private(set) var directNeighbors: [NeighborObservation] = []
    private var sequence = 0
    private var ticks = 0
    /// Relay path of each accepted report from another phone.
    private var paths: [String: [String]] = [:]
    private let store: MeshStore
    private var timer: Timer?
    private var fusion = FusionEngine()
    /// Barometric altitude when tracking started; height changes are measured from it.
    private var altitudeBaseline: Double?

    var positions: [DeviceUpdate] { store.latest.values.sorted { $0.id < $1.id } }
    private var freshPositions: [DeviceUpdate] { positions.filter { store.isFresh($0.id, within: Self.staleAfter) } }

    init() {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "deviceID") ?? UUID().uuidString
        defaults.set(id, forKey: "deviceID")
        deviceID = id
        serverURL = defaults.string(forKey: "serverURL") ?? "http://192.168.1.20:3000"
        gatewayToken = defaults.string(forKey: "gatewayToken") ?? ""
        let frame = defaults.string(forKey: "frameID") ?? "demo-room-v1"
        frameID = frame
        label = DashboardContract.truncatedLabel(defaults.string(forKey: "deviceLabel") ?? "Mapping phone")
        role = DeviceRole(rawValue: defaults.string(forKey: "role") ?? "") ?? .mobile
        manualX = defaults.double(forKey: "manualX")
        manualY = defaults.double(forKey: "manualY")
        manualZ = defaults.double(forKey: "manualZ")
        positionSource = PositionSource(rawValue: defaults.string(forKey: "positionSource") ?? "") ?? .manual
        store = MeshStore(frameId: frame, selfId: id)
        bluetooth.onPacket = { [weak self] data, neighbor in self?.receive(data, from: neighbor) }
        bluetooth.onNeighborReady = { [weak self] neighbor in self?.sync(to: neighbor) }
        motion.onSample = { [weak self] sample in self?.handleMotion(sample) }
    }

    func start() {
        guard !isRunning else { return }
        let frame = frameID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard frame.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil else {
            lastError = "Frame ID must be 1–64 letters, digits, '.', '_' or '-'"
            return
        }
        if frame != frameID { frameID = frame }
        store.reset(frameId: frameID)
        paths.removeAll()
        directNeighbors = []
        devices = []
        diagnostics = MeshDiagnostics()
        gateway.reset()
        isRunning = true
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        bluetooth.start(MeshIdentity(deviceId: deviceID, label: trimmed.isEmpty ? nil : trimmed, frameId: frameID))
        // A new session may use another frame: calibration and tracking start over.
        fusion = FusionEngine()
        altitudeBaseline = nil
        motion.start()
        refreshFusionStatus()
        lastError = nil
        ticks = 0
        updateIdleTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func stop() {
        isRunning = false
        isPublishing = false
        timer?.invalidate()
        timer = nil
        bluetooth.stop()
        gateway.stop()
        motion.stop()
        fusion.stop()
        refreshFusionStatus()
        updateIdleTimer()
    }

    func setGateway(_ enabled: Bool) {
        guard enabled else { gateway.stop(); return }
        guard isRunning else { lastError = "Start the mesh before enabling the gateway"; return }
        if usesTunnelURL, gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastError = "Internet URLs need the gateway token printed by `npm run tunnel`"
            return
        }
        gateway.enqueue(freshPositions)
        gateway.start(origin: serverURL, gatewayId: deviceID, frameId: frameID, token: gatewayToken)
    }

    func checkGatewayConnection() {
        gateway.checkConnection(origin: serverURL, token: gatewayToken)
    }

    /// Opens `meshmapper://gateway?url=…&token=…` from the dashboard's QR code: fills in the
    /// gateway settings, shows the Gateway tab and checks the connection. It never starts uploading.
    func applyConnectLink(_ link: URL) {
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let server = items.first { $0.name == "url" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parsed = URLComponents(string: server)
        guard link.scheme?.lowercased() == "meshmapper", link.host?.lowercased() == "gateway",
              ["http", "https"].contains(parsed?.scheme?.lowercased() ?? ""), parsed?.host?.isEmpty == false else {
            lastError = "That QR code is not a MeshMapper gateway link"
            return
        }
        if gateway.enabled { gateway.stop() }
        serverURL = server
        gatewayToken = items.first { $0.name == "token" }?.value ?? ""
        lastError = nil
        selectedTab = .gateway
        checkGatewayConnection()
    }

    /// Cloudflare quick-tunnel URLs always need the token; a custom tunnel hostname may too.
    var usesTunnelURL: Bool {
        URLComponents(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines))?
            .host?.lowercased().hasSuffix(".trycloudflare.com") == true
    }

    func setPublishing(_ enabled: Bool) {
        guard enabled else { isPublishing = false; return }
        guard isRunning else { lastError = "Start the mesh before publishing"; return }
        isPublishing = true
        publishCurrent()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        // Connections are not assumed to survive backgrounding; rescan and re-advertise.
        if phase == .active, isRunning { bluetooth.resume() }
        updateIdleTimer()
    }

    // Solver integration point: coordinates must already be in the selected shared frame.
    func publish(position: Position, mode: String, accuracyMeters: Double? = nil) {
        guard isRunning else { lastError = "Start the mesh before publishing"; return }
        guard [position.x, position.y, position.z].allSatisfy({ abs($0) <= DashboardContract.maxCoordinate }) else {
            lastError = "Coordinates must be within ±\(Int(DashboardContract.maxCoordinate)) m"
            isPublishing = false
            return
        }
        if let accuracyMeters, !(0...DashboardContract.maxAccuracyMeters).contains(accuracyMeters) {
            lastError = "Accuracy must be between 0 and \(Int(DashboardContract.maxAccuracyMeters)) m"
            isPublishing = false
            return
        }
        let nextSequence = sequence + 1
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let neighbors = bluetooth.neighborObservations()
        directNeighbors = neighbors
        let update = DeviceUpdate(id: deviceID, label: trimmed.isEmpty ? nil : trimmed, epochId: epochID,
                                  sequence: nextSequence, role: role.rawValue, position: position,
                                  positionMode: mode, accuracyMeters: accuracyMeters, neighbors: neighbors)
        do {
            let packet = MeshPacket(frameId: frameID, hopsRemaining: Self.originHops, update: update)
            try accept(packet, from: nil)
            sequence = nextSequence
            lastSequence = nextSequence
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            isPublishing = false
        }
    }

    private func publishCurrent() {
        switch positionSource {
        case .manual: publishManual()
        case .fused: publishFused()
        }
    }

    private func publishManual() {
        let floor = positionMode == "floor"
        publish(position: Position(x: manualX, y: floor ? 0 : manualY, z: manualZ),
                mode: positionMode, accuracyMeters: accuracyKnown ? accuracyMeters : nil)
    }

    /// Publishes the fused estimate with its own accuracy. Nothing is published until tracking
    /// started from a known point or an RSSI fix, so no position is invented.
    private func publishFused() {
        guard let filter = fusion.filter else {
            lastError = "Start tracking on the Position tab before publishing fused positions"
            isPublishing = false
            return
        }
        let floor = positionMode == "floor"
        publish(position: Position(x: filter.x, y: floor ? 0 : trackedHeight, z: filter.z),
                mode: positionMode, accuracyMeters: min(filter.accuracy, DashboardContract.maxAccuracyMeters))
    }

    // MARK: Motion + BLE anchor tracking

    /// Anchors known through the mesh, other than this phone.
    var anchors: [DeviceUpdate] {
        positions.filter { $0.role == DeviceRole.anchor.rawValue && $0.id != deviceID }
    }

    /// Starts at the manual coordinates; the user faces +z (frame forward) while tapping.
    func startTracking() {
        guard isRunning else { lastError = "Start the mesh before tracking"; return }
        guard motion.isMotionAvailable else { lastError = "This device has no motion sensors"; return }
        fusion.start(x: manualX, z: manualZ, heading: 0)
        altitudeBaseline = motion.relativeAltitude
        lastError = nil
        refreshFusionStatus()
    }

    /// Starts at the RSSI-only fix, which needs three or more anchors; the user faces +z.
    func startTrackingFromFix() {
        guard isRunning else { lastError = "Start the mesh before tracking"; return }
        guard fusion.startFromFix(heading: 0) else { lastError = "No RSSI fix yet: link to three or more anchors"; return }
        altitudeBaseline = motion.relativeAltitude
        lastError = nil
        refreshFusionStatus()
    }

    /// The user faces +z again; resets gyro heading drift.
    func alignHeading() {
        fusion.alignHeading(0)
        refreshFusionStatus()
    }

    func stopTracking() {
        fusion.stop()
        if positionSource == .fused { isPublishing = false }
        refreshFusionStatus()
    }

    /// The user stands next to an anchor: a strong position correction, not a reset.
    func markNear(anchor id: String) {
        guard let anchor = store.latest[id], anchor.role == DeviceRole.anchor.rawValue else { return }
        fusion.observePosition(x: anchor.position.x, z: anchor.position.z, sigma: 1)
        refreshFusionStatus()
    }

    /// Start height plus the barometric change since tracking started.
    private var trackedHeight: Double {
        guard let altitude = motion.relativeAltitude, let altitudeBaseline else { return manualY }
        return manualY + altitude - altitudeBaseline
    }

    private func handleMotion(_ sample: MotionSample) {
        if fusion.process(sample) != nil { refreshFusionStatus() }
    }

    private func updateFusion() {
        let uptime = ProcessInfo.processInfo.systemUptime
        if ticks % 5 == 0 { fusion.setCalibration(PathLossCalibration.fit(anchorLinks())) }
        fusion.ownHeight = positionMode == "floor" ? 0 : trackedHeight
        fusion.update(with: anchorSightings(uptime: uptime), at: uptime)
        refreshFusionStatus()
    }

    /// The latest raw RSSI of each linked anchor, timed on the motion clock (system uptime).
    private func anchorSightings(uptime: TimeInterval) -> [AnchorSighting] {
        let now = Date()
        return bluetooth.neighbors.compactMap { neighbor in
            guard let anchor = store.latest[neighbor.deviceId], anchor.role == DeviceRole.anchor.rawValue,
                  store.isFresh(anchor.id, within: Self.staleAfter) else { return nil }
            // Connection RSSI (1 Hz, links this phone opened) when current, else advertisements.
            let current = [neighbor.connectionRSSI, neighbor.advertisementRSSI].compactMap { $0 }.first { stats in
                stats.lastSampleAt.map { now.timeIntervalSince($0) <= MotionAwareRSSI.maxSampleAge } ?? false
            }
            guard let current, let raw = current.raw, let sampledAt = current.lastSampleAt else { return nil }
            return AnchorSighting(anchorId: anchor.id, position: anchor.position, positionAccuracy: anchor.accuracyMeters,
                                  rssi: Double(raw), sampleTime: uptime - now.timeIntervalSince(sampledAt))
        }
    }

    /// Links between anchors as reported in their own updates; both ends' positions are known,
    /// which calibrates the path-loss model and each anchor's radio.
    private func anchorLinks() -> [AnchorLinkObservation] {
        let fresh = positions.filter { $0.role == DeviceRole.anchor.rawValue && store.isFresh($0.id, within: Self.staleAfter) }
        let byId = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        return fresh.flatMap { observer in
            (observer.neighbors ?? []).compactMap { neighbor -> AnchorLinkObservation? in
                guard let target = byId[neighbor.id], let rssi = neighbor.rssi else { return nil }
                let p = observer.position
                let q = target.position
                let distance = ((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y) + (p.z - q.z) * (p.z - q.z)).squareRoot()
                return AnchorLinkObservation(observer: observer.id, target: target.id, distance: distance, rssi: Double(rssi))
            }
        }
    }

    private func refreshFusionStatus() {
        let now = ProcessInfo.processInfo.systemUptime
        var status = FusionStatus()
        status.tracking = fusion.isTracking
        status.x = fusion.filter?.x
        status.z = fusion.filter?.z
        status.accuracy = fusion.filter?.accuracy
        status.headingDegrees = fusion.heading * 180 / .pi
        status.headingOffsetDegrees = (fusion.filter?.headingOffset ?? 0) * 180 / .pi
        status.steps = fusion.deadReckoning.stepCount
        status.walked = fusion.walkedDistance
        status.walking = fusion.isWalking(at: now)
        status.receiverOffsetDB = fusion.filter?.receiverOffsetDB
        status.ranges = fusion.ranges
        status.fix = fusion.lastFix
        status.calibration = fusion.calibration
        status.accepted = fusion.acceptedUpdates
        status.rejected = fusion.rejectedUpdates
        status.recoveries = fusion.recoveries
        fusionStatus = status
    }

    private func tick() {
        guard isRunning else { return }
        updateFusion()
        // Each published report is a new measurement with a new sequence, including stationary anchors.
        if isPublishing { publishCurrent() }
        // Re-upload unchanged identities as a gateway heartbeat, not a new measurement.
        if gateway.enabled { gateway.enqueue(freshPositions) }
        ticks += 1
        if ticks % 5 == 0 { sync() }
    }

    /// Display name for a device ID: its reported label where known, otherwise a short ID.
    func displayName(_ id: String) -> String {
        if id == deviceID { return "this phone" }
        return store.latest[id]?.label
            ?? bluetooth.neighbors.first { $0.deviceId == id }?.label
            ?? shortID(id)
    }

    private func receive(_ data: Data, from neighbor: String) {
        guard isRunning else { return }
        diagnostics.received += 1
        do {
            let packet = try MeshPacket.decode(data)
            // Reports returning to their own origin are never re-applied.
            guard packet.update.id != deviceID else { diagnostics.duplicate += 1; return }
            try accept(packet, from: neighbor)
        } catch {
            diagnostics.rejected += 1
            lastError = error.localizedDescription
        }
    }

    /// `neighbor` is the device the packet arrived from; nil for this phone's own reports.
    private func accept(_ packet: MeshPacket, from neighbor: String?) throws {
        let id = packet.update.id
        let previous = store.latest[id]
        let relay = try store.ingest(packet)
        guard store.latest[id] != previous else {
            diagnostics.duplicate += 1
            return
        }
        paths[id] = neighbor == nil ? nil : packet.path
        if neighbor != nil { diagnostics.accepted += 1 }
        devices = positions.compactMap { update in
            store.receivedAt[update.id].map { KnownDevice(update: update, receivedAt: $0, path: paths[update.id]) }
        }
        if gateway.enabled { gateway.enqueue(freshPositions) }
        guard let relay else { return }
        let payload = try relay.encoded()
        if let neighbor {
            // Never echo a packet back over the link it came from.
            bluetooth.relay(payload, key: Self.positionKey(id), except: neighbor)
            diagnostics.relayed += 1
        } else {
            bluetooth.broadcast(payload, key: Self.positionKey(id))
        }
    }

    /// Outbox key: a newer report from the same origin replaces one still queued on a link.
    private static func positionKey(_ origin: String) -> String { "position:" + origin }

    /// Periodic resend of fresh cached reports. Hop counts and paths are never refreshed.
    private func sync() {
        guard isRunning else { return }
        for (id, packet) in store.relayPackets where store.isFresh(id, within: Self.staleAfter) {
            do { bluetooth.broadcast(try packet.encoded(), key: Self.positionKey(id)) } catch { lastError = error.localizedDescription }
        }
    }

    /// Brings a newly linked neighbor up to date without resending to every other link.
    private func sync(to neighbor: String) {
        guard isRunning else { return }
        for (id, packet) in store.relayPackets where store.isFresh(id, within: Self.staleAfter) {
            do { bluetooth.send(try packet.encoded(), key: Self.positionKey(id), to: neighbor) } catch { lastError = error.localizedDescription }
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && isRunning
    }
}
