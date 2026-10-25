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
    /// Dead reckoning fused with RSSI to BLE anchors; GPS or no position until tracking starts.
    case fused
    var id: String { rawValue }

    var title: String {
        switch self {
        case .gps: return "GPS"
        case .manual: return "Fixed spot (manual)"
        case .fused: return "Motion + BLE anchors"
        }
    }
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
    /// An anchor sends each neighbor at most this many UWB fixes per second.
    static let fixesPerSecond = 2.0

    let bluetooth = BluetoothMesh()
    let gateway = GatewayClient()
    let motion = MotionTracker()
    let location = LocationSource()
    let tracker = BluetoothTracker()
    let predictor = MovementPredictor()
    /// GhostCore: decides what this phone publishes and what the map shows (ARCHITECTURE.md §6).
    let ghost = GhostCoreHub()
    let uwb = UWBRanging()
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
    @Published var role: DeviceRole {
        didSet {
            UserDefaults.standard.set(role.rawValue, forKey: "role")
            // Anchor and target do different UWB work; turn it on again for the new role. Turning it
            // off restarts the sessions, so neighbors get a token that no longer says "anchor".
            if uwbEnabled, role != oldValue { setUWB(false) }
        }
    }
    /// Direction the back of the mounted anchor faces, in degrees from map +z towards map +x.
    @Published var anchorHeading: Double { didSet { UserDefaults.standard.set(anchorHeading, forKey: "anchorHeading") } }
    /// "UWB positioning": a target publishes fresh fixes from a direction anchor, and an anchor sends
    /// them. Off by default and after every launch: UWB is optional, not on the mesh's critical path.
    @Published private(set) var uwbEnabled = false
    /// UWB distances to linked UWB phones, carried in this phone's `neighbors` (wire v5) so the
    /// signal map uses them instead of RSSI ranges. Persisted; on by default on phones with UWB.
    @Published private(set) var uwbRangingEnabled: Bool
    /// Latest UWB fix from each direction anchor, by anchor device ID.
    @Published private(set) var rangingFixes: [String: ReceivedFix] = [:]
    @Published var manualX: Double { didSet { UserDefaults.standard.set(manualX, forKey: "manualX") } }
    @Published var manualY: Double { didSet { UserDefaults.standard.set(manualY, forKey: "manualY") } }
    @Published var manualZ: Double { didSet { UserDefaults.standard.set(manualZ, forKey: "manualZ") } }
    @Published private(set) var fusionStatus = FusionStatus()
    @Published var positionMode = "floor"
    @Published var accuracyKnown = false
    @Published var accuracyMeters = 1.0
    @Published var keepAwake: Bool {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake"); updateIdleTimer() }
    }
    @Published var positionChoice: PositionChoice {
        didSet {
            UserDefaults.standard.set(positionChoice.rawValue, forKey: "positionChoice")
            updateMotionTracker()
        }
    }
    /// Demo switch: publish as if GPS were lost, so the dashboard places this phone from Bluetooth.
    /// GhostCore's GPS check: only GPS the integrity engine trusts is shared. Takes effect on the next start.
    /// Off by default until field test T4 shows real phones reach "trusted": with it on and no
    /// independent evidence, a phone's GPS is never shared (seen on the simulator, which has no motion).
    @Published var gpsCheck: Bool { didSet { UserDefaults.standard.set(gpsCheck, forKey: "gpsCheck") } }
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
    /// Position updates run every 0.2 s; the 1 s tick keeps calibration, sync and tracking.
    static let publishInterval: TimeInterval = 0.2
    /// Unchanged positions are still republished this often, as before (a stationary anchor too).
    static let heartbeatInterval: TimeInterval = 1
    /// A move smaller than this between fast updates is not worth a new report.
    static let minPublishedMove = 0.05
    private var fastTimer: Timer?
    /// Set by the fast loop: publish only when the position changed, else once per heartbeat.
    private var publishOnlyChanges = false
    private var lastPublished: (position: Position, mode: String, accuracy: Double?, source: PositionSource, at: Date)?
    /// Relay path of each accepted report from another phone.
    private var paths: [String: [String]] = [:]
    /// Neighbors whose ranging token said they are direction anchors.
    private var anchorNeighbors = Set<String>()
    /// Neighbors `UWBSessionPolicy` chose for a UWB session at the last reconcile.
    private var selectedRangingPeers = Set<String>()
    private var lastFixSent: [String: Date] = [:]
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
        let frame = defaults.string(forKey: "frameID") ?? GeoFrame.defaultFrameId
        frameID = frame
        label = DashboardContract.truncatedLabel(defaults.string(forKey: "deviceLabel") ?? Self.friendlyName(for: id))
        keepAwake = defaults.object(forKey: "keepAwake") as? Bool ?? true
        positionChoice = PositionChoice(rawValue: defaults.string(forKey: "positionChoice") ?? "") ?? .gps
        simulateGPSLoss = defaults.bool(forKey: "simulateGPSLoss")
        gpsCheck = defaults.bool(forKey: "gpsCheck")
        role = DeviceRole(rawValue: defaults.string(forKey: "role") ?? "") ?? .mobile
        manualX = defaults.double(forKey: "manualX")
        manualY = defaults.double(forKey: "manualY")
        manualZ = defaults.double(forKey: "manualZ")
        anchorHeading = defaults.double(forKey: "anchorHeading")
        uwbRangingEnabled = (defaults.object(forKey: "uwbRanging") as? Bool ?? true) && UWBRanging.supportsDistance
        store = MeshStore(frameId: frame, selfId: id)
        bluetooth.onPacket = { [weak self] data, neighbor in self?.receive(data, from: neighbor) }
        bluetooth.onNeighborReady = { [weak self] neighbor in self?.sync(to: neighbor) }
        bluetooth.onRanging = { [weak self] type, data, neighbor in self?.receiveRanging(type, data, from: neighbor) }
        uwb.sendToken = { [weak self] token, neighbor in self?.sendRangingToken(token, to: neighbor) }
        uwb.onMeasurement = { [weak self] neighbor, measurement in self?.measured(neighbor, measurement) }
        motion.onSample = { [weak self] sample in self?.handleMotion(sample) }
    }

    /// App launch: start GPS, and bring back the mesh (on by default) and the gateway (if it was on)
    /// so a phone needs no taps after the first setup.
    func launch() {
        location.start()
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
        ghost.reset(selfId: deviceID, frameId: frameID, gpsCheck: gpsCheck)
        ghost.onPeerLink = { [weak self] peer, up in
            guard let self else { return }
            if up { self.bluetooth.blockedDeviceIds.remove(peer) } else { self.bluetooth.blockedDeviceIds.insert(peer) }
        }
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
        updateMotionTracker()
        refreshFusionStatus()
        lastError = nil
        ticks = 0
        updateIdleTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        fastTimer = Timer.scheduledTimer(withTimeInterval: Self.publishInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fastTick() }
        }
        UserDefaults.standard.set(true, forKey: "meshRunning")
        // Publishing is what puts this phone (and its Bluetooth links) on the map, so it starts too.
        setPublishing(true)
        updateRanging()
    }

    /// Fused tracking's own Core Motion feed runs only while fused tracking is chosen or tracking: the
    /// GhostCore positioning service already runs one, and Apple advises one motion manager per app.
    private func updateMotionTracker() {
        if isRunning && (positionChoice == .fused || fusion.isTracking) { motion.start() } else { motion.stop() }
    }

    func stop() {
        setUWB(false)
        isRunning = false
        isPublishing = false
        updateRanging()
        timer?.invalidate()
        timer = nil
        fastTimer?.invalidate()
        fastTimer = nil
        lastPublished = nil
        bluetooth.stop()
        gateway.stop()
        motion.stop()
        fusion.stop()
        refreshFusionStatus()
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
        if publishOnlyChanges, let last = lastPublished,
           Date().timeIntervalSince(last.at) < Self.heartbeatInterval,
           last.source == source, last.mode == mode, last.accuracy == accuracyMeters,
           abs(last.position.x - position.x) < Self.minPublishedMove,
           abs(last.position.y - position.y) < Self.minPublishedMove,
           abs(last.position.z - position.z) < Self.minPublishedMove {
            return
        }
        let nextSequence = sequence + 1
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let neighbors = bluetooth.neighborObservations(at: now).map { withUWB($0, at: now) }
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
            lastPublished = (position, mode, accuracyMeters, source, Date())
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

    /// The GPS fix as a position in this phone's frame, if there is a usable one and GPS is not
    /// being simulated as lost.
    var gpsPosition: (position: Position, accuracy: Double)? {
        guard !simulateGPSLoss, let fix = location.usableFix(),
              let position = GeoFrame.position(frameId: frameID, latitude: fix.coordinate.latitude,
                                               longitude: fix.coordinate.longitude) else { return nil }
        // Core Location's accuracy is a ~68 % radius; the wire carries a 95 % radius.
        return (position, min(fix.horizontalAccuracy * Self.gpsR95PerAccuracy, DashboardContract.maxAccuracyMeters))
    }

    /// 95 % over 68 % radius of a 2-D Gaussian: sqrt(-2 ln 0.05) / sqrt(-2 ln 0.32).
    static let gpsR95PerAccuracy = 1.62

    /// With UWB on, a target publishes fresh UWB fixes; typed coordinates only when chosen; the fused
    /// estimate only while tracking (started from a known point or an RSSI fix), so no position is
    /// invented. Otherwise GPS or no position, as GhostCore decides: with GPS check on, only GPS the
    /// integrity engine trusts is shared.
    private func publishCurrent() {
        let usesUWB = uwbEnabled && role != .anchor
        if usesUWB, let fix = currentFix?.fix {
            let floor = positionMode == "floor"
            publish(position: Position(x: fix.position.x, y: floor ? 0 : fix.position.y, z: fix.position.z),
                    mode: positionMode, accuracyMeters: fix.accuracyMeters, source: .uwb)
            return
        }
        if positionChoice == .manual, !usesUWB { publishManual(); return }
        if positionChoice == .fused, let filter = fusion.filter {
            let floor = positionMode == "floor"
            publish(position: Position(x: filter.x, y: floor ? 0 : trackedHeight, z: filter.z), mode: positionMode,
                    accuracyMeters: min(filter.r95, DashboardContract.maxAccuracyMeters), source: .fused)
            return
        }
        // GPS (a 95 % radius on the wire), or a placeholder with `none` so the others place this
        // phone from its Bluetooth links.
        let publication = ghost.publication
        publish(position: publication.position, mode: "floor", accuracyMeters: publication.accuracyMeters,
                source: publication.source)
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
        updateMotionTracker()
        altitudeBaseline = motion.relativeAltitude
        lastError = nil
        refreshFusionStatus()
    }

    /// Starts at the RSSI-only fix, which needs three or more anchors; the user faces +z.
    func startTrackingFromFix() {
        guard isRunning else { lastError = "Start the mesh before tracking"; return }
        guard fusion.startFromFix(heading: 0) else { lastError = "No RSSI fix yet: link to three or more anchors"; return }
        updateMotionTracker()
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
        updateMotionTracker()
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
        status.accuracy = fusion.filter?.r95
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

    /// Every 0.2 s: advance the position estimate and publish it when it moved. Fusion only uses
    /// RSSI samples newer than the last one it took, so running it this often counts nothing twice.
    private func fastTick() {
        guard isRunning else { return }
        updateFusion()
        guard isPublishing else { return }
        // Each published report is a new measurement with a new sequence, including stationary anchors.
        publishOnlyChanges = true
        publishCurrent()
        publishOnlyChanges = false
    }

    private func tick() {
        guard isRunning else { return }
        // GhostCore first: it decides whether this phone's GPS may be published this second. It runs once per
        // second; the 0.2 s fast loop publishes using its latest decision.
        let floor = positionMode == "floor"
        let records = ghost.step(.init(
            reports: positions, receivedAt: store.receivedAt, paths: paths, location: location.latest,
            simulateGPSLoss: simulateGPSLoss,
            declared: positionChoice == .manual
                ? (Position(x: manualX, y: floor ? 0 : manualY, z: manualZ), accuracyKnown ? accuracyMeters : nil) : nil,
            observations: bluetooth.observations, records: bluetooth.relay.takeReceivedRecords()))
        for record in records { bluetooth.relay.send(record: record) }
        if ticks % 5 == 0 { fusion.setCalibration(PathLossCalibration.fit(anchorLinks())) }
        reconcileRanging()
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
            rangingFixes.removeAll()
            lastFixSent.removeAll()
            restartRanging()
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
        restartRanging()
    }

    /// UWB distances to linked UWB phones, carried in this phone's `neighbors`. Persisted.
    func setUWBRanging(_ enabled: Bool) {
        if enabled, !UWBRanging.supportsDistance {
            lastError = "This iPhone has no UWB chip (needs iPhone 11 or newer, not SE)"
            return
        }
        uwbRangingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "uwbRanging")
        // After a denied permission, turning distances on again asks again (stop() clears it).
        if enabled, uwb.permissionDenied { uwb.stop() }
        updateRanging()
    }

    /// UWB positioning changes what this phone's token says (a direction anchor or not), so the
    /// sessions start over and every neighbor gets a new token; a denied permission is asked again.
    private func restartRanging() {
        if uwb.isRunning { uwb.stop() }
        anchorNeighbors.removeAll()
        selectedRangingPeers = []
        updateRanging()
    }

    /// Sessions run while the mesh runs and either UWB ranging or UWB positioning is on. Only a
    /// direction anchor sending fixes needs gravity for its tilt.
    private func updateRanging() {
        if isRunning, UWBRanging.supportsDistance, uwbRangingEnabled || uwbEnabled {
            uwb.start(measuresTilt: sendsFixes)
            reconcileRanging()
        } else if uwb.isRunning {
            uwb.stop()
            anchorNeighbors.removeAll()
            selectedRangingPeers = []
        }
    }

    /// This phone measures neighbors and sends them UWB fixes.
    private var sendsFixes: Bool { uwbEnabled && isDirectionAnchor }

    /// Picks the neighbors for UWB sessions. Both ends rank from the same mesh reports, so they
    /// usually pick each other; with more candidates than sessions a one-sided pick times out
    /// (no answer within `UWBRanging.progressTimeout`) and that neighbor cools down for a while.
    private func selectRangingPeers(at now: Date) {
        selectedRangingPeers = uwb.isActive
            ? UWBSessionPolicy.select(rangingCandidates(at: now), budget: uwb.sessionBudget, now: now)
            : []
    }

    private func reconcileRanging(at now: Date = Date()) {
        guard uwb.isRunning else { return }
        selectRangingPeers(at: now)
        uwb.reconcile(wanted: selectedRangingPeers, at: now)
    }

    /// Linked neighbors that may get a session. Capability is learned by trying: a neighbor that
    /// never answers a token (no UWB, UWB off, or no free slot) cools down in `UWBRanging`. Anchors
    /// sending fixes and mounted side by side would use up each other's sessions, so they never
    /// pair. With ranging off only links to a direction anchor are candidates, for its fixes.
    private func rangingCandidates(at now: Date) -> [UWBPeerCandidate] {
        let linked = Set(bluetooth.neighbors.map(\.deviceId))
        anchorNeighbors.formIntersection(linked)
        let selfUnplaced = lastSource == PositionSource.none
        var candidates: [UWBPeerCandidate] = []
        for neighbor in bluetooth.neighbors {
            let id = neighbor.deviceId
            let report = store.latest[id]
            let peerIsAnchor = anchorNeighbors.contains(id) || report?.role == DeviceRole.anchor.rawValue
            if sendsFixes, peerIsAnchor { continue }
            let anchorLink = sendsFixes || anchorNeighbors.contains(id)
            guard uwbRangingEnabled || anchorLink, !uwb.isCoolingDown(id, at: now) else { continue }
            var samples: [Double] = []
            if let own = (neighbor.connectionRSSI ?? neighbor.advertisementRSSI)?.smoothed { samples.append(own) }
            if let theirs = report?.neighbors?.first(where: { $0.id == deviceID })?.rssi { samples.append(Double(theirs)) }
            candidates.append(UWBPeerCandidate(
                id: id,
                rssi: samples.isEmpty ? nil : samples.reduce(0.0, +) / Double(samples.count),
                isDirectionAnchor: anchorLink,
                touchesUnplaced: selfUnplaced || report?.positionSource == PositionSource.none,
                // A session still swapping tokens is held too, or near-equal candidates would take
                // turns closing each other's sessions before either measured.
                measuringSince: uwb.measuringSince(id, at: now) ?? uwb.openedAt(id)))
        }
        return candidates
    }

    /// Adds this phone's fresh UWB distance to a neighbor observation, within the limits
    /// `DeviceUpdate.validate` and the dashboard accept.
    private func withUWB(_ observation: NeighborObservation, at now: Date) -> NeighborObservation {
        guard uwbRangingEnabled, let reading = uwb.reading(for: observation.id, at: now),
              reading.distance.isFinite, reading.distance >= 0,
              reading.distance <= DashboardContract.maxUWBDistanceMeters else { return observation }
        return NeighborObservation(id: observation.id, rssi: observation.rssi, ageMs: observation.ageMs,
                                   uwbDistanceM: reading.distance)
    }

    private func sendRangingToken(_ token: Data, to neighbor: String) {
        do {
            // Only an anchor that sends fixes says so; a parked one is an ordinary ranging peer.
            let payload = try RangingToken(token: token, isAnchor: sendsFixes).encoded()
            bluetooth.send(payload, type: .rangingToken, key: "rangingToken", to: neighbor)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func receiveRanging(_ type: FrameType, _ data: Data, from neighbor: String) {
        guard isRunning else { return }
        do {
            switch type {
            case .rangingToken:
                let token = try RangingToken.decode(data)
                if token.isAnchor { anchorNeighbors.insert(neighbor) } else { anchorNeighbors.remove(neighbor) }
                guard uwb.isActive else { return }
                uwb.peerAnswered(neighbor, token: token.token)
                let now = Date()
                selectRangingPeers(at: now)
                // Only a selected peer gets a session, so the budget holds.
                if selectedRangingPeers.contains(neighbor) { uwb.receive(token: token.token, from: neighbor) }
                uwb.reconcile(wanted: selectedRangingPeers, at: now)
            case .rangingFix:
                guard uwbEnabled else { return }
                let fix = try RangingFix.decode(data)
                guard role != .anchor, fix.targetId == deviceID, fix.anchorId == neighbor else { return }
                rangingFixes[neighbor] = ReceivedFix(fix: fix, receivedAt: Date())
            default:
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
        case .invalidRanging: return "Received an invalid UWB ranging message; it was ignored."
        }
    }
}
