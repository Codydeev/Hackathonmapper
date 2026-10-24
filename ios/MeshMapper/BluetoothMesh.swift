import Combine
import CoreBluetooth
import Foundation
import MeshCore

struct RadioPeer: Identifiable {
    let id: UUID
    var name: String
    var rssi = RSSIStatistics()
    var lastSeen = Date()
    var connected = false
}

// All manager callbacks and callers run on the main queue.
final class BluetoothMesh: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate {
    static let serviceID = CBUUID(string: "F7A40001-5AB1-4E90-A989-21B5E52E2210")
    static let characteristicID = CBUUID(string: "F7A40002-5AB1-4E90-A989-21B5E52E2210")
    @Published private(set) var peers: [UUID: RadioPeer] = [:]
    @Published private(set) var status = "Bluetooth stopped"
    @Published private(set) var lastError: String?
    var onPacket: ((Data) -> Void)?
    var onLinkReady: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    private var characteristic: CBMutableCharacteristic?
    private var serviceAdded = false
    private var running = false
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var remoteCharacteristics: [UUID: CBCharacteristic] = [:]
    private var subscribers: [UUID: CBCentral] = [:]
    private var writeQueues: [UUID: [Data]] = [:]
    private var writing = Set<UUID>()
    private var notifyQueues: [UUID: [Data]] = [:]
    private var receiveBuffers: [String: Data] = [:]
    private var receiveTimes: [String: Date] = [:]
    private var retryAfter: [UUID: Date] = [:]
    private var timer: Timer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func start() {
        running = true
        activate()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        central.stopScan()
        peripheralManager.stopAdvertising()
        for peer in peripherals.values where peer.state != .disconnected { central.cancelPeripheralConnection(peer) }
        writeQueues.removeAll()
        notifyQueues.removeAll()
        receiveBuffers.removeAll()
        receiveTimes.removeAll()
        writing.removeAll()
        status = "Bluetooth stopped"
    }

    private func activate() {
        guard running else { return }
        guard central.state == .poweredOn, peripheralManager.state == .poweredOn else {
            status = "Bluetooth unavailable: \(stateName(central.state)) / \(stateName(peripheralManager.state))"
            return
        }
        central.scanForPeripherals(withServices: [Self.serviceID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        if serviceAdded {
            peripheralManager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID]])
        } else if characteristic == nil {
            let value = CBMutableCharacteristic(type: Self.characteristicID, properties: [.write, .notify], value: nil, permissions: [.writeable])
            let service = CBMutableService(type: Self.serviceID, primary: true)
            service.characteristics = [value]
            characteristic = value
            peripheralManager.add(service)
        }
        status = "Scanning and advertising (foreground)"
    }

    private func stateName(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "on"
        case .poweredOff: return "off"
        case .unauthorized: return "permission denied"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "initializing"
        @unknown default: return "unknown"
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            peripherals.removeAll()
            remoteCharacteristics.removeAll()
            writeQueues.removeAll()
            writing.removeAll()
            for id in Array(peers.keys) { peers[id]?.connected = false }
        }
        activate()
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state != .poweredOn {
            characteristic = nil
            serviceAdded = false
            subscribers.removeAll()
            notifyQueues.removeAll()
        }
        activate()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { lastError = error.localizedDescription; characteristic = nil; return }
        serviceAdded = true
        activate()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { lastError = error.localizedDescription }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard running else { return }
        let id = peripheral.identifier
        guard peers[id] != nil || peers.count < 100 else { return }
        var peer = peers[id] ?? RadioPeer(id: id, name: peripheral.name ?? "Mapping phone")
        _ = peer.rssi.record(RSSI.intValue)
        peer.lastSeen = Date()
        peers[id] = peer
        guard peripherals.count < 8 || peripherals[id] != nil else { return }
        peripherals[id] = peripheral
        if peripheral.state == .disconnected, Date() >= (retryAfter[id] ?? .distantPast) {
            peripheral.delegate = self
            retryAfter[id] = Date().addingTimeInterval(5)
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard running else { central.cancelPeripheralConnection(peripheral); return }
        peers[peripheral.identifier]?.connected = true
        peripheral.discoverServices([Self.serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        disconnected(peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        disconnected(peripheral, error: error)
    }

    private func disconnected(_ peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        peers[id]?.connected = false
        remoteCharacteristics[id] = nil
        writeQueues[id] = nil
        writing.remove(id)
        receiveBuffers["n:\(id)"] = nil
        receiveTimes["n:\(id)"] = nil
        retryAfter[id] = Date().addingTimeInterval(5)
        if let error { lastError = error.localizedDescription }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { lastError = error.localizedDescription; central.cancelPeripheralConnection(peripheral); return }
        for service in peripheral.services ?? [] where service.uuid == Self.serviceID {
            peripheral.discoverCharacteristics([Self.characteristicID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { lastError = error.localizedDescription; central.cancelPeripheralConnection(peripheral); return }
        guard let value = service.characteristics?.first(where: { $0.uuid == Self.characteristicID }),
              value.properties.contains(.write), value.properties.contains(.notify) else { return }
        remoteCharacteristics[peripheral.identifier] = value
        peripheral.setNotifyValue(true, for: value)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { lastError = error.localizedDescription; return }
        if characteristic.isNotifying { onLinkReady?() }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        let id = peripheral.identifier
        guard var peer = peers[id] else { return }
        _ = peer.rssi.record(RSSI.intValue)
        peer.lastSeen = Date()
        peers[id] = peer
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard running, error == nil, characteristic.uuid == Self.characteristicID, let data = characteristic.value else { return }
        receive(data, from: "n:\(peripheral.identifier)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard subscribers.count < 8 || subscribers[central.identifier] != nil else { return }
        subscribers[central.identifier] = central
        if running { onLinkReady?() }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribers[central.identifier] = nil
        notifyQueues[central.identifier] = nil
        receiveBuffers["w:\(central.identifier)"] = nil
        receiveTimes["w:\(central.identifier)"] = nil
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard running, request.characteristic.uuid == Self.characteristicID,
                  request.offset == 0, let value = request.value,
                  subscribers[request.central.identifier] != nil else {
                peripheral.respond(to: request, withResult: .unlikelyError)
                continue
            }
            receive(value, from: "w:\(request.central.identifier)")
            peripheral.respond(to: request, withResult: .success)
        }
    }

    func broadcast(_ payload: Data) {
        guard running, !payload.isEmpty, payload.count <= 4096 else { return }
        let size = UInt32(payload.count)
        let framed = Data([UInt8((size >> 24) & 255), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]) + payload
        for (id, remote) in peripherals where remote.state == .connected && remoteCharacteristics[id] != nil {
            let chunks = split(framed, size: remote.maximumWriteValueLength(for: .withResponse))
            // Never drop individual chunks: a dropped chunk corrupts the stream framing.
            if (writeQueues[id]?.count ?? 0) + chunks.count <= 1024 {
                writeQueues[id, default: []].append(contentsOf: chunks)
                pumpWrite(id)
            } else { lastError = "BLE send queue full; latest positions will resync" }
        }
        for (id, subscriber) in subscribers {
            let chunks = split(framed, size: subscriber.maximumUpdateValueLength)
            if (notifyQueues[id]?.count ?? 0) + chunks.count <= 1024 {
                notifyQueues[id, default: []].append(contentsOf: chunks)
            } else { lastError = "BLE notification queue full; latest positions will resync" }
        }
        pumpNotifications()
    }

    private func split(_ data: Data, size: Int) -> [Data] {
        let size = max(1, size)
        return stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min($0 + size, data.count)) }
    }

    private func pumpWrite(_ id: UUID) {
        guard running, !writing.contains(id), let remote = peripherals[id], remote.state == .connected,
              let value = remoteCharacteristics[id], let chunk = writeQueues[id]?.first else { return }
        writing.insert(id)
        remote.writeValue(chunk, for: value, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        writing.remove(id)
        if let error {
            lastError = error.localizedDescription
            writeQueues[id] = nil
            central.cancelPeripheralConnection(peripheral)
            return
        }
        if writeQueues[id]?.isEmpty == false { writeQueues[id]?.removeFirst() }
        pumpWrite(id)
    }

    private func pumpNotifications() {
        guard running, let characteristic else { return }
        for id in Array(notifyQueues.keys) {
            guard let subscriber = subscribers[id] else { notifyQueues[id] = nil; continue }
            while let chunk = notifyQueues[id]?.first {
                guard peripheralManager.updateValue(chunk, for: characteristic, onSubscribedCentrals: [subscriber]) else { return }
                notifyQueues[id]?.removeFirst()
            }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { pumpNotifications() }

    private func receive(_ data: Data, from key: String) {
        var buffer = receiveBuffers[key] ?? Data()
        buffer.append(data)
        guard buffer.count <= 8192 else { receiveBuffers[key] = nil; receiveTimes[key] = nil; lastError = "BLE frame too large"; return }
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard (1...4096).contains(length) else { receiveBuffers[key] = nil; receiveTimes[key] = nil; lastError = "Invalid BLE frame"; return }
            guard buffer.count >= length + 4 else { break }
            let payload = Data(buffer.dropFirst(4).prefix(length))
            buffer = Data(buffer.dropFirst(length + 4))
            onPacket?(payload)
        }
        receiveBuffers[key] = buffer.isEmpty ? nil : buffer
        receiveTimes[key] = buffer.isEmpty ? nil : Date()
    }

    private func tick() {
        guard running else { return }
        for remote in peripherals.values where remote.state == .connected { remote.readRSSI() }
        for key in Array(receiveTimes.keys) where Date().timeIntervalSince(receiveTimes[key] ?? .distantPast) > 10 {
            receiveBuffers[key] = nil
            receiveTimes[key] = nil
        }
        for id in Array(peers.keys) where peers[id]?.connected == false && Date().timeIntervalSince(peers[id]?.lastSeen ?? .distantPast) > 30 {
            peers[id] = nil
            peripherals[id] = nil
            retryAfter[id] = nil
        }
    }
}
