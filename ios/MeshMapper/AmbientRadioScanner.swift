import CoreBluetooth
import Foundation
import MeshCore
import UIKit

/// Experimental passive scan of every Bluetooth LE advertisement in range, for ambient radio
/// fingerprinting (docs/AMBIENT_RADIO.md). It has its own central manager on its own queue and
/// never connects, so the mesh's discovery, links and relaying are left alone; it runs only while
/// `AmbientRadioView` is open and the user has started it, and stops when the app leaves the
/// foreground. The devices it hears are observations, never peers, relays or anchors.
///
/// A second central scanning for every service shares the radio with `BluetoothMesh`'s discovery;
/// how much that slows mesh link-up has not been measured yet (ARCHITECTURE.md T1).
@MainActor
final class AmbientRadioScanner: NSObject, ObservableObject {
    /// How much is kept: enough for a 20 s recording plus slack.
    static let horizon: TimeInterval = 120

    @Published private(set) var isScanning = false
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    /// Devices (not GhostCore peers) heard in the last `horizon` seconds.
    @Published private(set) var devicesHeard = 0
    /// When the current scan started.
    @Published private(set) var startedAt: Date?

    private let buffer: Buffer
    private var central: CBCentralManager?
    private var timer: Timer?
    private var backgroundObserver: NSObjectProtocol?

    override init() {
        buffer = Buffer(excludedServices: [BluetoothMesh.serviceID.uuidString])
        super.init()
    }

    func start() {
        guard !buffer.wantsScan else { return }
        buffer.wantsScan = true
        buffer.clear()
        startedAt = Date()
        if let central {
            isScanning = central.state == .poweredOn
            buffer.queue.async { Self.scan(central) }
        } else {
            central = CBCentralManager(delegate: self, queue: buffer.queue,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    func stop() {
        buffer.wantsScan = false
        if let central { buffer.queue.async { if central.state == .poweredOn { central.stopScan() } } }
        timer?.invalidate()
        timer = nil
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        isScanning = false
        startedAt = nil
    }

    /// Seconds of listening so far in this scan.
    var listenedFor: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    /// What was heard over the last `seconds`.
    func snapshot(seconds: TimeInterval) -> AmbientSnapshot {
        let now = Date().timeIntervalSince1970
        return buffer.snapshot(from: now - seconds, to: now)
    }

    private func refresh() {
        devicesHeard = buffer.deviceCount(now: Date().timeIntervalSince1970)
    }

    nonisolated private static func scan(_ central: CBCentralManager) {
        guard central.state == .poweredOn, !central.isScanning else { return }
        // Every service, duplicates allowed: one RSSI per advertisement, foreground only.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    /// The rolling recorder, shared between the scan queue and the main actor.
    private final class Buffer: @unchecked Sendable {
        let queue = DispatchQueue(label: "ambient-radio-scan", qos: .utility)
        private let lock = NSLock()
        private var recorder: AmbientRecorder
        private var lastPrune: TimeInterval = 0
        private var wants = false

        init(excludedServices: Set<String>) {
            recorder = AmbientRecorder(excludedServices: excludedServices, horizon: AmbientRadioScanner.horizon)
        }

        var wantsScan: Bool {
            get { lock.withLock { wants } }
            set { lock.withLock { wants = newValue } }
        }

        func add(_ advertisement: AmbientAdvertisement) {
            lock.withLock {
                guard wants else { return }
                recorder.add(advertisement)
                if advertisement.time - lastPrune > 10 {
                    recorder.prune(now: advertisement.time)
                    lastPrune = advertisement.time
                }
            }
        }

        func snapshot(from start: TimeInterval, to end: TimeInterval) -> AmbientSnapshot {
            lock.withLock { recorder.snapshot(from: start, to: end) }
        }

        func deviceCount(now: TimeInterval) -> Int {
            lock.withLock {
                recorder.prune(now: now)
                return recorder.emitterCount
            }
        }

        func clear() {
            lock.withLock { recorder.removeAll() }
        }
    }
}

extension AmbientRadioScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        if state == .poweredOn, buffer.wantsScan { Self.scan(central) }
        let scanning = state == .poweredOn && buffer.wantsScan
        Task { @MainActor in
            self.bluetoothState = state
            self.isScanning = scanning
        }
    }

    /// Reads only what matching needs: the identifier iOS assigned (digested at once), an Eddystone
    /// UID if there is one, RSSI, and the advertisement's class (digested; the manufacturer data
    /// itself is not kept). The local name is never read.
    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
        var serviceData: [String: Data] = [:]
        for (uuid, data) in advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:] {
            serviceData[uuid.uuidString] = data
        }
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        let advertisementClass = AmbientEmitterKey.advertisementClass(
            manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
            serviceUUIDs: services, connectable: connectable)
        buffer.add(AmbientAdvertisement(
            time: Date().timeIntervalSince1970, emitter: .best(identifier: peripheral.identifier, serviceData: serviceData),
            rssi: RSSI.doubleValue, advertisementClass: advertisementClass, serviceUUIDs: services))
    }
}

/// The recorded spots, kept on this phone only: a file-protected JSON file in Application Support,
/// excluded from iCloud backup, never relayed or uploaded.
@MainActor
final class FingerprintStore: ObservableObject {
    @Published private(set) var database = FingerprintDatabase()
    private let url: URL

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = folder.appendingPathComponent("ambient-fingerprints.json")
        if let data = try? Data(contentsOf: url), let stored = try? FingerprintDatabase.decode(data) { database = stored }
    }

    func add(_ fingerprint: RadioFingerprint) {
        database.add(fingerprint)
        save()
    }

    func remove(id: String) {
        database.remove(id: id)
        save()
    }

    func removeAll() {
        database = FingerprintDatabase()
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try database.encoded().write(to: url, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var file = url
            try file.setResourceValues(values)
        } catch {
            // The spots stay in memory for this session; nothing else depends on the file.
        }
    }
}
