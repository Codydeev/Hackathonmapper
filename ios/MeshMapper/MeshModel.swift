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

struct ReceivedFix {
    let fix: RangingFix
    let receivedAt: Date
}

struct MeshDiagnostics {
    var received = 0
    var accepted = 0
    var duplicate = 0
    var relayed = 0
    var rejected = 0
}

@MainActor
final class MeshModel: ObservableObject {
    // Ingesting our own packet consumes one hop, so neighbors receive 4 remaining hops.
    static let originHops = 5
    /// Reports not refreshed within this time are no longer resent or uploaded.
    static let staleAfter: TimeInterval = 30
    /// An anchor sends each neighbor at most this many UWB fixes per second.
    static let fixesPerSecond = 2.0

    let bluetooth = BluetoothMesh()
    let gateway = GatewayClient()
    let uwb = UWBRanging()
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
    @Published var role: DeviceRole {
        didSet {
            UserDefaults.standard.set(role.rawValue, forKey: "role")
            // Anchor and target do different UWB work; turn it on again for the new role.
            if uwbEnabled, role != oldValue { setUWB(false) }
        }
    }
    /// Direction the back of the mounted anchor faces, in degrees from map +z towards map +x.
    @Published var anchorHeading: Double { didSet { UserDefaults.standard.set(anchorHeading, forKey: "anchorHeading") } }
    /// Off by default and after every launch: UWB is optional, not on the mesh's critical path.
    @Published private(set) var uwbEnabled = false
    /// Latest UWB fix from each direction anchor, by anchor device ID.
    @Published private(set) var rangingFixes: [String: ReceivedFix] = [:]
    @Published var manualX: Double { didSet { UserDefaults.standard.set(manualX, forKey: "manualX") } }
    @Published var manualY: Double { didSet { UserDefaults.standard.set(manualY, forKey: "manualY") } }
    @Published var manualZ: Double { didSet { UserDefaults.standard.set(manualZ, forKey: "manualZ") } }
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
    /// Neighbors whose ranging token said they are direction anchors.
    private var anchorNeighbors = Set<String>()
    private var lastFixSent: [String: Date] = [:]
    private let store: MeshStore
    private var timer: Timer?

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
        anchorHeading = defaults.double(forKey: "anchorHeading")
        store = MeshStore(frameId: frame, selfId: id)
        bluetooth.onPacket = { [weak self] data, neighbor in self?.receive(data, from: neighbor) }
        bluetooth.onNeighborReady = { [weak self] neighbor in self?.sync(to: neighbor) }
        bluetooth.onRanging = { [weak self] type, data, neighbor in self?.receiveRanging(type, data, from: neighbor) }
        uwb.sendToken = { [weak self] token, neighbor in self?.sendRangingToken(token, to: neighbor) }
        uwb.onMeasurement = { [weak self] neighbor, measurement in self?.measured(neighbor, measurement) }
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
        lastError = nil
        ticks = 0
        updateIdleTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func stop() {
        setUWB(false)
        isRunning = false
        isPublishing = false
        timer?.invalidate()
        timer = nil
        bluetooth.stop()
        gateway.stop()
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

    /// With UWB on, a target publishes only fresh UWB fixes and never falls back to manual
    /// coordinates: the dashboard cannot tell the two apart.
    private func publishCurrent() {
        guard uwbEnabled, role != .anchor else { publishManual(); return }
        guard let fix = currentFix?.fix else { return }
        let floor = positionMode == "floor"
        publish(position: Position(x: fix.position.x, y: floor ? 0 : fix.position.y, z: fix.position.z),
                mode: positionMode, accuracyMeters: fix.accuracyMeters)
    }

    private func publishManual() {
        let floor = positionMode == "floor"
        publish(position: Position(x: manualX, y: floor ? 0 : manualY, z: manualZ),
                mode: positionMode, accuracyMeters: accuracyKnown ? accuracyMeters : nil)
    }

    private func tick() {
        guard isRunning else { return }
        // Each published report is a new measurement with a new sequence, including stationary anchors.
        if isPublishing { publishCurrent() }
        if uwbEnabled { uwb.reconcile(wanted: wantedRangingPeers) }
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

    // MARK: UWB positioning

    /// A mounted anchor that can measure direction; only these send fixes.
    var isDirectionAnchor: Bool { role == .anchor && UWBRanging.supportsDirection }

    /// Freshest usable fix, preferring the most accurate when several anchors see this phone.
    var currentFix: ReceivedFix? {
        let now = Date()
        return rangingFixes.values
            .filter { now.timeIntervalSince($0.receivedAt) <= RangingFix.maxAge }
            .min { $0.fix.accuracyMeters < $1.fix.accuracyMeters }
    }

    func setUWB(_ enabled: Bool) {
        guard enabled else {
            uwbEnabled = false
            uwb.stop()
            rangingFixes.removeAll()
            anchorNeighbors.removeAll()
            lastFixSent.removeAll()
            return
        }
        guard isRunning else { lastError = "Start the mesh before turning on UWB"; return }
        guard UWBRanging.supportsDistance else {
            lastError = "This iPhone has no UWB chip (needs iPhone 11 or newer, not SE)"
            return
        }
        if role == .anchor, !UWBRanging.supportsDirection {
            lastError = "This iPhone cannot measure UWB direction while mounted. Use an iPhone 11, 12 or 13 as the anchor."
            return
        }
        uwbEnabled = true
        lastError = nil
        uwb.start(measuresTilt: role == .anchor)
        uwb.reconcile(wanted: wantedRangingPeers)
    }

    /// Only links between a direction anchor and a non-anchor need a UWB session; anchors mounted
    /// side by side would otherwise use up each other's sessions. Anchors announce themselves with
    /// their token and keep resending it, so other phones never open sessions on a guess.
    private var wantedRangingPeers: Set<String> {
        let linked = Set(bluetooth.neighbors.map(\.deviceId))
        anchorNeighbors.formIntersection(linked)
        let isAnchor = { (id: String) in
            self.anchorNeighbors.contains(id) || self.store.latest[id]?.role == DeviceRole.anchor.rawValue
        }
        return isDirectionAnchor ? linked.filter { !isAnchor($0) } : linked.filter { anchorNeighbors.contains($0) }
    }

    private func sendRangingToken(_ token: Data, to neighbor: String) {
        do {
            let payload = try RangingToken(token: token, isAnchor: isDirectionAnchor).encoded()
            bluetooth.send(payload, type: .rangingToken, key: "rangingToken", to: neighbor)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func receiveRanging(_ type: FrameType, _ data: Data, from neighbor: String) {
        guard isRunning, uwbEnabled else { return }
        do {
            switch type {
            case .rangingToken:
                let token = try RangingToken.decode(data)
                if token.isAnchor { anchorNeighbors.insert(neighbor) } else { anchorNeighbors.remove(neighbor) }
                if wantedRangingPeers.contains(neighbor) { uwb.receive(token: token.token, from: neighbor) }
            case .rangingFix:
                let fix = try RangingFix.decode(data)
                guard role != .anchor, fix.targetId == deviceID, fix.anchorId == neighbor else { return }
                rangingFixes[neighbor] = ReceivedFix(fix: fix, receivedAt: Date())
            case .hello, .position:
                return
            }
        } catch {
            diagnostics.rejected += 1
            lastError = "Invalid UWB message from \(displayName(neighbor))"
        }
    }

    /// Anchor side: turns a measurement into a map position and sends it to the measured phone.
    private func measured(_ neighbor: String, _ measurement: UWBMeasurement) {
        guard isRunning, uwbEnabled, isDirectionAnchor,
              let distance = measurement.distance, let direction = measurement.direction else { return }
        guard let gravity = uwb.gravity else {
            uwb.reportError("No motion sensor data, so this anchor's tilt is unknown and it sends no fixes")
            return
        }
        guard measurement.updatedAt.timeIntervalSince(lastFixSent[neighbor] ?? .distantPast) >= 1 / Self.fixesPerSecond else { return }
        // In floor mode the anchor counts as y = 0, so fixes give heights relative to the floor
        // under it; targets in floor mode, the default, ignore height anyway.
        let floor = positionMode == "floor"
        let anchor = Position(x: manualX, y: floor ? 0 : manualY, z: manualZ)
        guard let fix = AnchorGeometry.fix(anchorId: deviceID, targetId: neighbor, anchor: anchor,
                                           headingDegrees: anchorHeading, gravity: gravity,
                                           distance: distance, direction: direction, floor: false),
              let payload = try? fix.encoded() else { return }
        lastFixSent[neighbor] = measurement.updatedAt
        bluetooth.send(payload, type: .rangingFix, key: "rangingFix", to: neighbor)
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && isRunning
    }
}
