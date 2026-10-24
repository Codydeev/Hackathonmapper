import Combine
import Foundation
import MeshCore
import SwiftUI
import UIKit

enum DeviceRole: String, CaseIterable, Identifiable {
    case mobile, anchor, gateway
    var id: String { rawValue }
}

struct KnownDevice: Identifiable {
    let update: DeviceUpdate
    let receivedAt: Date
    // Hops left when this phone accepted the report; nil for this phone's own reports.
    let hopsRemaining: Int?
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

    let bluetooth = BluetoothMesh()
    let gateway = GatewayClient()
    let deviceID: String
    let epochID = UUID().uuidString
    @Published var serverURL: String { didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") } }
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
    @Published var keepAwake = true { didSet { updateIdleTimer() } }
    @Published private(set) var devices: [KnownDevice] = []
    @Published private(set) var diagnostics = MeshDiagnostics()
    @Published private(set) var isRunning = false
    @Published private(set) var isPublishing = false
    @Published private(set) var lastSequence: Int?
    @Published private(set) var lastError: String?
    /// Direct BLE neighbors by app device ID, as included in this phone's last report.
    @Published private(set) var directNeighbors: [NeighborObservation] = []
    private var neighborTracker = DirectNeighborTracker(originHops: MeshModel.originHops)
    private var sequence = 0
    private var ticks = 0
    private var receipts: [String: (at: Date, hopsRemaining: Int?)] = [:]
    private let store: MeshStore
    private var timer: Timer?

    var positions: [DeviceUpdate] { store.latest.values.sorted { $0.id < $1.id } }

    init() {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "deviceID") ?? UUID().uuidString
        defaults.set(id, forKey: "deviceID")
        deviceID = id
        serverURL = defaults.string(forKey: "serverURL") ?? "http://192.168.1.20:3000"
        frameID = defaults.string(forKey: "frameID") ?? "demo-room-v1"
        label = DashboardContract.truncatedLabel(defaults.string(forKey: "deviceLabel") ?? "Mapping phone")
        role = DeviceRole(rawValue: defaults.string(forKey: "role") ?? "") ?? .mobile
        manualX = defaults.double(forKey: "manualX")
        manualY = defaults.double(forKey: "manualY")
        manualZ = defaults.double(forKey: "manualZ")
        store = MeshStore(frameId: frameID)
        bluetooth.onPacket = { [weak self] data, link in self?.receive(data, link: link) }
        bluetooth.onLinkReady = { [weak self] in self?.sync() }
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
        receipts.removeAll()
        neighborTracker.reset()
        directNeighbors = []
        devices = []
        diagnostics = MeshDiagnostics()
        gateway.reset()
        isRunning = true
        bluetooth.start()
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
        updateIdleTimer()
    }

    func setGateway(_ enabled: Bool) {
        guard enabled else { gateway.stop(); return }
        guard isRunning else { lastError = "Start the mesh before enabling the gateway"; return }
        gateway.enqueue(positions)
        gateway.start(origin: serverURL, gatewayId: deviceID, frameId: frameID)
    }

    func setPublishing(_ enabled: Bool) {
        guard enabled else { isPublishing = false; return }
        guard isRunning else { lastError = "Start the mesh before publishing"; return }
        isPublishing = true
        publishManual()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        // Connections are not assumed to survive backgrounding; rescan and re-advertise.
        if phase == .active, isRunning { bluetooth.start() }
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
        let neighbors = neighborTracker.neighbors(isLinkOpen: bluetooth.isLinkOpen, rssi: bluetooth.rssi(forLink:))
        directNeighbors = neighbors
        let update = DeviceUpdate(id: deviceID, label: trimmed.isEmpty ? nil : trimmed, epochId: epochID,
                                  sequence: nextSequence, role: role.rawValue, position: position,
                                  positionMode: mode, accuracyMeters: accuracyMeters, neighbors: neighbors)
        do {
            let packet = MeshPacket(frameId: frameID, hopsRemaining: Self.originHops, update: update)
            try accept(packet, hopsRemaining: nil)
            sequence = nextSequence
            lastSequence = nextSequence
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            isPublishing = false
        }
    }

    private func publishManual() {
        let floor = positionMode == "floor"
        publish(position: Position(x: manualX, y: floor ? 0 : manualY, z: manualZ),
                mode: positionMode, accuracyMeters: accuracyKnown ? accuracyMeters : nil)
    }

    private func tick() {
        guard isRunning else { return }
        // Each published report is a new measurement with a new sequence, including stationary anchors.
        if isPublishing { publishManual() }
        // Re-upload unchanged identities as a gateway heartbeat, not a new measurement.
        if gateway.enabled { gateway.enqueue(positions) }
        ticks += 1
        if ticks % 5 == 0 { sync() }
    }

    private func receive(_ data: Data, link: String) {
        guard isRunning else { return }
        diagnostics.received += 1
        do {
            let packet = try MeshPacket.decode(data)
            if packet.frameId == frameID {
                neighborTracker.record(packet, link: link, selfId: deviceID)
            }
            // Reports returning to their own origin are never re-applied.
            guard packet.update.id != deviceID else { diagnostics.duplicate += 1; return }
            try accept(packet, hopsRemaining: packet.hopsRemaining)
        } catch {
            diagnostics.rejected += 1
            lastError = error.localizedDescription
        }
    }

    private func accept(_ packet: MeshPacket, hopsRemaining: Int?) throws {
        let id = packet.update.id
        let previous = store.latest[id]
        let relay = try store.ingest(packet)
        guard store.latest[id] != previous else {
            diagnostics.duplicate += 1
            return
        }
        receipts[id] = (Date(), hopsRemaining)
        if hopsRemaining != nil { diagnostics.accepted += 1 }
        devices = positions.compactMap { update in
            receipts[update.id].map { KnownDevice(update: update, receivedAt: $0.at, hopsRemaining: $0.hopsRemaining) }
        }
        if gateway.enabled { gateway.enqueue(positions) }
        if let relay {
            bluetooth.broadcast(try relay.encoded())
            if hopsRemaining != nil { diagnostics.relayed += 1 }
        }
    }

    private func sync() {
        guard isRunning else { return }
        for packet in store.relayPackets.values {
            do { bluetooth.broadcast(try packet.encoded()) } catch { lastError = error.localizedDescription }
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && isRunning
    }
}
