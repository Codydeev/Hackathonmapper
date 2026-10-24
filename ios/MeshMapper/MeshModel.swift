import Combine
import Foundation
import MeshCore

@MainActor
final class MeshModel: ObservableObject {
    let bluetooth = BluetoothMesh()
    let gateway = GatewayClient()
    let deviceID: String
    let epochID = UUID().uuidString
    @Published var serverURL: String { didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") } }
    @Published var frameID: String { didSet { UserDefaults.standard.set(frameID, forKey: "frameID") } }
    @Published var label: String { didSet { UserDefaults.standard.set(label, forKey: "deviceLabel") } }
    @Published private(set) var positions: [DeviceUpdate] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    private var sequence = 0
    private let store: MeshStore
    private var timer: Timer?

    init() {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "deviceID") ?? UUID().uuidString
        defaults.set(id, forKey: "deviceID")
        deviceID = id
        serverURL = defaults.string(forKey: "serverURL") ?? "http://laptop.local:3000"
        frameID = defaults.string(forKey: "frameID") ?? "demo-room-v1"
        label = defaults.string(forKey: "deviceLabel") ?? "Mapping phone"
        store = MeshStore(frameId: frameID)
        bluetooth.onPacket = { [weak self] data in self?.receive(data) }
        bluetooth.onLinkReady = { [weak self] in self?.sync() }
    }

    func start() {
        guard !isRunning else { return }
        let frame = frameID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !frame.isEmpty, frame.count <= 128 else { lastError = "Frame ID must contain 1–128 characters"; return }
        if frame != frameID { frameID = frame }
        store.reset(frameId: frameID)
        positions = []
        gateway.reset()
        isRunning = true
        bluetooth.start()
        lastError = nil
        var ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                // Re-upload unchanged identities as a gateway heartbeat, not a new measurement.
                if self.gateway.enabled { self.gateway.enqueue(self.positions) }
                ticks += 1
                if ticks % 5 == 0 { self.sync() }
            }
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        bluetooth.stop()
        gateway.stop()
    }

    func setGateway(_ enabled: Bool) {
        guard enabled, isRunning else { gateway.stop(); return }
        gateway.enqueue(positions)
        gateway.start(origin: serverURL, gatewayId: deviceID, frameId: frameID)
    }

    // Solver integration point: coordinates must already be in the selected shared frame.
    func publish(position: Position, mode: String, accuracyMeters: Double? = nil) {
        guard isRunning else { lastError = "Start the mesh before publishing"; return }
        let nextSequence = sequence + 1
        let update = DeviceUpdate(id: deviceID, label: label, epochId: epochID, sequence: nextSequence,
                                  role: "mobile", position: position, positionMode: mode, accuracyMeters: accuracyMeters)
        do {
            let packet = MeshPacket(frameId: frameID, hopsRemaining: 8, update: update)
            try accept(packet)
            sequence = nextSequence
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    private func receive(_ data: Data) {
        guard isRunning else { return }
        do { try accept(MeshPacket.decode(data)) } catch { lastError = error.localizedDescription }
    }

    private func accept(_ packet: MeshPacket) throws {
        let relay = try store.ingest(packet)
        positions = store.latest.values.sorted { $0.id < $1.id }
        if gateway.enabled { gateway.enqueue(positions) }
        if let relay { bluetooth.broadcast(try relay.encoded()) }
    }

    private func sync() {
        guard isRunning else { return }
        for packet in store.relayPackets.values {
            do { bluetooth.broadcast(try packet.encoded()) } catch { lastError = error.localizedDescription }
        }
    }
}
