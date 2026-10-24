import Combine
import Foundation
import MeshCore
import SwiftUI
import UIKit

enum AppTab: Hashable {
    case track, start, network, position, gateway
}

enum DeviceRole: String, CaseIterable, Identifiable {
    case mobile, anchor, gateway
    var id: String { rawValue }
}

/// How this phone gets the position it publishes.
enum PositionChoice: String, CaseIterable, Identifiable {
    /// The phone's own GPS; without a usable fix it reports no position.
    case gps
    /// Typed coordinates (a fixed spot, for indoor demos).
    case manual
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

@MainActor
final class MeshModel: ObservableObject {
    // Ingesting our own packet consumes one hop, so neighbors receive 4 remaining hops.
    static let originHops = 5
    /// Reports not refreshed within this time are no longer resent or uploaded.
    static let staleAfter: TimeInterval = 30

    let bluetooth = BluetoothMesh()
    let gateway = GatewayClient()
    let location: LocationSource
    /// Luotsi's GPS check: GPS is only shared while it agrees with this phone's steps and compass.
    let gpsGuard: GPSGuard
    let tracker = BluetoothTracker()
    let predictor = MovementPredictor()
    let deviceID: String
    let epochID = UUID().uuidString
    @Published var serverURL: String { didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") } }
    // Only the internet (Cloudflare tunnel) endpoint needs it; a LAN URL works without one.
    @Published var gatewayToken: String { didSet { UserDefaults.standard.set(gatewayToken, forKey: "gatewayToken") } }
    @Published var selectedTab: AppTab = .track
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
    @Published var positionMode = "floor"
    @Published var accuracyKnown = false
    @Published var accuracyMeters = 1.0
    @Published var keepAwake: Bool {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake"); updateIdleTimer() }
    }
    @Published var positionChoice: PositionChoice {
        didSet { UserDefaults.standard.set(positionChoice.rawValue, forKey: "positionChoice") }
    }
    /// Demo switch: publish as if GPS were lost, so the dashboard places this phone from Bluetooth.
    @Published var simulateGPSLoss: Bool {
        didSet { UserDefaults.standard.set(simulateGPSLoss, forKey: "simulateGPSLoss") }
    }
    /// The settings sheet (the detailed tabs) on top of the map.
    @Published var showingSettings = false
    /// Source of the last report this phone published.
    @Published private(set) var lastSource: PositionSource?
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

    var positions: [DeviceUpdate] { store.latest.values.sorted { $0.id < $1.id } }
    private var freshPositions: [DeviceUpdate] { positions.filter { store.isFresh($0.id, within: Self.staleAfter) } }

    init() {
        let location = LocationSource()
        self.location = location
        gpsGuard = GPSGuard(location: location)
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "deviceID") ?? UUID().uuidString
        defaults.set(id, forKey: "deviceID")
        deviceID = id
        serverURL = defaults.string(forKey: "serverURL") ?? "http://192.168.1.20:3000"
        gatewayToken = defaults.string(forKey: "gatewayToken") ?? ""
        let frame = defaults.string(forKey: "frameID") ?? GeoFrame.defaultFrameId
        frameID = frame
        label = DashboardContract.truncatedLabel(defaults.string(forKey: "deviceLabel") ?? Self.friendlyName(for: id))
        keepAwake = defaults.object(forKey: "keepAwake") as? Bool ?? true
        positionChoice = PositionChoice(rawValue: defaults.string(forKey: "positionChoice") ?? "") ?? .gps
        simulateGPSLoss = defaults.bool(forKey: "simulateGPSLoss")
        role = DeviceRole(rawValue: defaults.string(forKey: "role") ?? "") ?? .mobile
        manualX = defaults.double(forKey: "manualX")
        manualY = defaults.double(forKey: "manualY")
        manualZ = defaults.double(forKey: "manualZ")
        store = MeshStore(frameId: frame, selfId: id)
        bluetooth.onPacket = { [weak self] data, neighbor in self?.receive(data, from: neighbor) }
        bluetooth.onNeighborReady = { [weak self] neighbor in self?.sync(to: neighbor) }
    }

    /// App launch: start GPS, and bring back the mesh (on by default) and the gateway (if it was on)
    /// so a phone needs no taps after the first setup.
    func launch() {
        location.start()
        gpsGuard.start()
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "meshRunning") as? Bool ?? true else { return }
        start()
        if defaults.bool(forKey: "gatewayWanted") { setGateway(true) }
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
        tracker.reset()
        predictor.reset()
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
        UserDefaults.standard.set(true, forKey: "meshRunning")
        // Publishing is what puts this phone (and its Bluetooth links) on the map, so it starts too.
        setPublishing(true)
    }

    func stop() {
        isRunning = false
        isPublishing = false
        timer?.invalidate()
        timer = nil
        bluetooth.stop()
        gateway.stop()
        updateIdleTimer()
        UserDefaults.standard.set(false, forKey: "meshRunning")
    }

    func setGateway(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "gatewayWanted")
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
        showingSettings = true
        checkGatewayConnection()
    }

    /// Cloudflare quick-tunnel URLs always need the token; a custom tunnel hostname may too.
    var usesTunnelURL: Bool {
        URLComponents(string: GatewayClient.normalizedOrigin(serverURL))?
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
    func publish(position: Position, mode: String, accuracyMeters: Double? = nil, source: PositionSource = .manual) {
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
                                  positionMode: mode, accuracyMeters: accuracyMeters, neighbors: neighbors,
                                  positionSource: source)
        do {
            let packet = MeshPacket(frameId: frameID, hopsRemaining: Self.originHops, update: update)
            try accept(packet, from: nil)
            sequence = nextSequence
            lastSequence = nextSequence
            lastSource = source
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            isPublishing = false
        }
    }

    private func publishManual() {
        let floor = positionMode == "floor"
        publish(position: Position(x: manualX, y: floor ? 0 : manualY, z: manualZ),
                mode: positionMode, accuracyMeters: accuracyKnown ? accuracyMeters : nil, source: .manual)
    }

    /// The GPS fix as a position in this phone's frame, if there is a usable one, the GPS check
    /// has not rejected it (jammed or spoofed), and GPS is not being simulated as lost.
    var gpsPosition: (position: Position, accuracy: Double)? {
        guard !simulateGPSLoss, gpsGuard.allowsGPS,
              let fix = gpsGuard.usableFix(maxAccuracy: LocationSource.maxAccuracyMeters, maxAge: LocationSource.maxAge),
              let position = GeoFrame.position(frameId: frameID, latitude: fix.latitude,
                                               longitude: fix.longitude) else { return nil }
        return (position, min(fix.accuracy, DashboardContract.maxAccuracyMeters))
    }

    private func publishCurrent() {
        if positionChoice == .manual { publishManual(); return }
        if let gps = gpsPosition {
            publish(position: gps.position, mode: "floor", accuracyMeters: gps.accuracy, source: .gps)
        } else {
            // Placeholder only: `none` tells the dashboard to place this phone from its Bluetooth links.
            publish(position: Position(x: 0, y: 0, z: 0), mode: "floor", source: .none)
        }
    }

    /// Indoors GPS is often too poor to anchor anyone: pin this phone at a spot tapped on the map.
    func pinHere(latitude: Double, longitude: Double) {
        guard let position = GeoFrame.position(frameId: frameID, latitude: latitude, longitude: longitude) else {
            lastError = "This frame has no map origin; use \(GeoFrame.defaultFrameId)"
            return
        }
        manualX = position.x
        manualY = 0
        manualZ = position.z
        positionMode = "floor"
        accuracyKnown = true
        accuracyMeters = 5
        positionChoice = .manual
        if isPublishing { publishCurrent() }
    }

    func unpin() {
        positionChoice = .gps
        if isPublishing { publishCurrent() }
    }

    /// A short readable default name, stable for this phone ("Otter 42").
    static func friendlyName(for id: String) -> String {
        let words = ["Otter", "Lynx", "Moose", "Hare", "Fox", "Owl", "Seal", "Wolf", "Elk", "Crane", "Pike", "Bear"]
        let seed = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return "\(words[seed % words.count]) \(10 + (seed / words.count) % 90)"
    }

    private func tick() {
        guard isRunning else { return }
        // Each published report is a new measurement with a new sequence, including stationary anchors.
        if isPublishing { publishCurrent() }
        // Re-upload unchanged identities as a gateway heartbeat, not a new measurement.
        if gateway.enabled { gateway.enqueue(freshPositions) }
        // Places phones without GPS from Bluetooth, on this phone: no network needed.
        tracker.update(reports: positions, receivedAt: store.receivedAt, selfId: deviceID)
        // Phones Bluetooth lost: where the movement model says they have probably walked since.
        predictor.update(phones: tracker.phones, frameId: frameID)
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

/// Readable messages for errors shown in the app's status lines.
extension MeshCoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidUpdate: return "A position report broke the dashboard's limits and was dropped."
        case .invalidPacket: return "Received a malformed mesh packet; it was ignored."
        case .packetTooLarge: return "A mesh packet was too large to send."
        case .frameMismatch: return "A nearby phone uses a different frame ID; set the same frame on every phone."
        case .deviceCapacityReached: return "Too many phones in this mesh; new ones are ignored."
        case .epochCapacityReached: return "Too many app restarts seen this session; restart the mesh."
        case .invalidFrame: return "Received a corrupted Bluetooth frame; it was ignored."
        case .invalidHello: return "A nearby phone sent an invalid hello; update it to the same app version."
        }
    }
}
