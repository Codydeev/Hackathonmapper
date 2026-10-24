import Combine
import CoreBluetooth
import Foundation
import MeshCore

// A phone advertising the mesh service. Its device ID is known only after a handshake with it.
struct RadioPeer: Identifiable {
    let id: UUID
    var rssi = RSSIStatistics()
    var lastSeen = Date()
    var deviceId: String?
}

// A mesh device with at least one ready (handshaken) link.
struct Neighbor: Identifiable {
    let deviceId: String
    var label: String?
    var outgoing: UUID?   // we are central; CBPeripheral identifier
    var incoming: UUID?   // we are peripheral; CBCentral identifier
    var rssi: RSSIStatistics?   // connection RSSI, only measurable on an outgoing link
    var lastPacket: Date?
    var id: String { deviceId }
}

enum LinkID: Hashable {
    case outgoing(UUID)
    case incoming(UUID)
}

// All manager callbacks and callers run on the main queue.
final class BluetoothMesh: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate {
    static let serviceID = CBUUID(string: "F7A40001-5AB1-4E90-A989-21B5E52E2210")
    static let characteristicID = CBUUID(string: "F7A40002-5AB1-4E90-A989-21B5E52E2210")
    // App resource budget for logical neighbors, not an iOS limit.
    static let maxNeighbors = 8
    // Connect, discovery, subscription and handshake must all finish within this time.
    static let linkSetupTimeout: TimeInterval = 10
    static let incompatibleBackoff: TimeInterval = 60

    @Published private(set) var peers: [UUID: RadioPeer] = [:]
    @Published private(set) var neighbors: [String: Neighbor] = [:]
    @Published private(set) var status = "Bluetooth stopped"
    @Published private(set) var lastError: String?
    // Payload of a position frame and the device ID of the neighbor it arrived from.
    var onPacket: ((Data, String) -> Void)?
    // Called with the neighbor's device ID each time one of its links completes the handshake.
    var onLinkReady: ((String) -> Void)?

    private enum OutgoingState { case connecting, linking, ready }

    private struct OutgoingLink {
        let peripheral: CBPeripheral
        var state = OutgoingState.connecting
        let startedAt = Date()
        var readyAt: Date?
        var characteristic: CBCharacteristic?
        var notifying = false
        var hello: Hello?
        var outbox = LinkOutbox()
        var writing = false
        var assembler = FrameAssembler()
    }

    private struct IncomingLink {
        let central: CBCentral
        let startedAt = Date()
        var hello: Hello?
        var outbox = LinkOutbox()
        var assembler = FrameAssembler()
    }

    private var central: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    private var characteristic: CBMutableCharacteristic?
    private var serviceAdded = false
    private var running = false
    private var identity: Hello?
    private var outgoing: [UUID: OutgoingLink] = [:]
    private var incoming: [UUID: IncomingLink] = [:]
    private var backoff: [UUID: (until: Date, failures: Int)] = [:]
    // Outgoing links we cancelled on purpose because a canonical link to the same neighbor exists.
    private var retiring = Set<UUID>()
    private var connectionRSSI: [String: RSSIStatistics] = [:]
    private var lastPacket: [String: Date] = [:]
    private var timer: Timer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func start(identity: Hello) {
        self.identity = identity
        running = true
        lastError = nil
        activate()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    // Foreground return: connections are not assumed to survive backgrounding, so rescan and re-advertise.
    func resume() {
        guard running else { return }
        activate()
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        if central.state == .poweredOn { central.stopScan() }
        for link in outgoing.values where link.peripheral.state != .disconnected {
            central.cancelPeripheralConnection(link.peripheral)
        }
        if peripheralManager.state == .poweredOn {
            peripheralManager.stopAdvertising()
            // Removing the service drops every subscription, so no stale incoming links survive a restart.
            peripheralManager.removeAllServices()
        }
        characteristic = nil
        serviceAdded = false
        outgoing.removeAll()
        incoming.removeAll()
        backoff.removeAll()
        retiring.removeAll()
        connectionRSSI.removeAll()
        lastPacket.removeAll()
        peers.removeAll()
        neighbors.removeAll()
        status = "Bluetooth stopped"
    }

    private func activate() {
        guard running else { return }
        guard central.state == .poweredOn, peripheralManager.state == .poweredOn else {
            status = "Bluetooth unavailable: \(stateName(central.state)) / \(stateName(peripheralManager.state))"
            return
        }
        if !central.isScanning {
            central.scanForPeripherals(withServices: [Self.serviceID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
        if serviceAdded {
            if !peripheralManager.isAdvertising {
                peripheralManager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID]])
            }
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

    // MARK: Manager state

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            outgoing.removeAll()
            retiring.removeAll()
            refreshNeighbors()
        }
        activate()
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state != .poweredOn {
            characteristic = nil
            serviceAdded = false
            incoming.removeAll()
            refreshNeighbors()
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

    // MARK: Central role (outgoing links)

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard running else { return }
        let id = peripheral.identifier
        guard peers[id] != nil || peers.count < 100 else { return }
        var peer = peers[id] ?? RadioPeer(id: id)
        peer.rssi.record(RSSI.intValue)
        peer.lastSeen = Date()
        peers[id] = peer

        guard outgoing[id] == nil, Date() >= (backoff[id]?.until ?? .distantPast),
              outgoing.count < Self.maxNeighbors, neighbors.count < Self.maxNeighbors else { return }
        // Already linked to this device, possibly through its incoming connection: don't open a duplicate.
        if let deviceId = peer.deviceId, neighbors[deviceId] != nil { return }
        peripheral.delegate = self
        outgoing[id] = OutgoingLink(peripheral: peripheral)
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        guard running, outgoing[id] != nil else { central.cancelPeripheralConnection(peripheral); return }
        outgoing[id]?.state = .linking
        peripheral.discoverServices([Self.serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dropOutgoing(peripheral.identifier, error: error?.localizedDescription)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dropOutgoing(peripheral.identifier, error: error?.localizedDescription)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let id = peripheral.identifier
        if let error { dropOutgoing(id, error: error.localizedDescription); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else {
            dropOutgoing(id, error: "Nearby phone has no mesh service", retryAfter: Self.incompatibleBackoff)
            return
        }
        peripheral.discoverCharacteristics([Self.characteristicID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let id = peripheral.identifier
        if let error { dropOutgoing(id, error: error.localizedDescription); return }
        guard let value = service.characteristics?.first(where: { $0.uuid == Self.characteristicID }),
              value.properties.contains(.write), value.properties.contains(.notify) else {
            dropOutgoing(id, error: "Nearby phone runs an incompatible app version", retryAfter: Self.incompatibleBackoff)
            return
        }
        outgoing[id]?.characteristic = value
        peripheral.setNotifyValue(true, for: value)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        if let error { dropOutgoing(id, error: error.localizedDescription); return }
        guard characteristic.isNotifying else { dropOutgoing(id, error: "Neighbor stopped notifications"); return }
        guard outgoing[id] != nil, !(outgoing[id]?.notifying ?? true) else { return }
        outgoing[id]?.notifying = true
        // The hello is the first message on every link.
        if let identity, let payload = try? identity.encoded(), let framed = Frame.encode(.hello, payload) {
            outgoing[id]?.outbox.enqueue(framed, key: "hello")
            pumpWrite(id)
        }
        completeOutgoingIfReady(id)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, let deviceId = outgoing[peripheral.identifier]?.hello?.deviceId else { return }
        connectionRSSI[deviceId, default: RSSIStatistics()].record(RSSI.intValue)
        neighbors[deviceId]?.rssi = connectionRSSI[deviceId]
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        guard running, error == nil, characteristic.uuid == Self.characteristicID, let data = characteristic.value,
              outgoing[id] != nil else { return }
        do {
            let frames = try outgoing[id]?.assembler.append(data) ?? []
            for frame in frames { handle(frame, on: .outgoing(id)) }
        } catch {
            lastError = "Invalid data from neighbor; reconnecting"
            dropOutgoing(id, error: nil)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        outgoing[id]?.writing = false
        if let error { dropOutgoing(id, error: error.localizedDescription); return }
        outgoing[id]?.outbox.chunkSent()
        pumpWrite(id)
    }

    private func pumpWrite(_ id: UUID) {
        guard running, let link = outgoing[id], !link.writing, link.peripheral.state == .connected,
              let value = link.characteristic else { return }
        // Size every chunk to fit one ATT write. Larger writes become prepared writes with non-zero
        // offsets, which the receiving peripheral manager cannot reassemble.
        let maxLength = link.peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard let chunk = outgoing[id]?.outbox.nextChunk(maxLength: maxLength) else { return }
        outgoing[id]?.writing = true
        link.peripheral.writeValue(chunk, for: value, type: .withResponse)
    }

    private func completeOutgoingIfReady(_ id: UUID) {
        guard let link = outgoing[id], link.state != .ready, link.notifying, let hello = link.hello else { return }
        outgoing[id]?.state = .ready
        outgoing[id]?.readyAt = Date()
        linkReady(hello)
    }

    // Removes an outgoing link immediately; later Core Bluetooth callbacks for it are ignored.
    private func dropOutgoing(_ id: UUID, error: String?, retryAfter: TimeInterval? = nil) {
        guard let link = outgoing.removeValue(forKey: id) else { return }
        if link.peripheral.state != .disconnected { central.cancelPeripheralConnection(link.peripheral) }
        let now = Date()
        if retiring.remove(id) != nil {
            backoff[id] = (now.addingTimeInterval(5), 0)
        } else {
            // Exponential backoff with jitter; a link that was stable for 30 s starts over.
            let stable = link.readyAt.map { now.timeIntervalSince($0) >= 30 } ?? false
            let failures = stable ? 0 : (backoff[id]?.failures ?? 0) + 1
            let delay = retryAfter ?? min(60, 5 * pow(2, Double(max(0, failures - 1))))
            backoff[id] = (now.addingTimeInterval(delay + Double.random(in: 0...2)), failures)
            if let error { lastError = error }
        }
        refreshNeighbors()
    }

    // MARK: Peripheral role (incoming links)

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        let id = central.identifier
        // Centrals beyond the budget are never registered; their writes fail and they back off.
        guard running, incoming[id] == nil, incoming.count < Self.maxNeighbors else { return }
        var link = IncomingLink(central: central)
        if let identity, let payload = try? identity.encoded(), let framed = Frame.encode(.hello, payload) {
            link.outbox.enqueue(framed, key: "hello")
        }
        incoming[id] = link
        pumpNotifications()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard incoming.removeValue(forKey: central.identifier) != nil else { return }
        refreshNeighbors()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Respond exactly once per callback, to the first request, failing the batch if any request is invalid.
        guard let first = requests.first else { return }
        let valid = running && requests.allSatisfy { request in
            request.characteristic.uuid == Self.characteristicID && request.offset == 0 &&
                request.value != nil && incoming[request.central.identifier] != nil
        }
        guard valid else { peripheral.respond(to: first, withResult: .unlikelyError); return }
        peripheral.respond(to: first, withResult: .success)
        for request in requests {
            let id = request.central.identifier
            do {
                let frames = try incoming[id]?.assembler.append(request.value ?? Data()) ?? []
                for frame in frames { handle(frame, on: .incoming(id)) }
            } catch {
                lastError = "Invalid data from neighbor"
            }
        }
    }

    private func pumpNotifications() {
        guard running, let characteristic else { return }
        for id in Array(incoming.keys) {
            while let link = incoming[id],
                  let chunk = incoming[id]?.outbox.nextChunk(maxLength: link.central.maximumUpdateValueLength) {
                guard peripheralManager.updateValue(chunk, for: characteristic, onSubscribedCentrals: [link.central]) else { return }
                incoming[id]?.outbox.chunkSent()
            }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { pumpNotifications() }

    // MARK: Handshake and routing

    private func handle(_ frame: Frame, on link: LinkID) {
        switch frame.type {
        case .hello:
            receiveHello(frame.payload, on: link)
        case .position:
            // No mesh data is processed before the link's handshake.
            guard let deviceId = helloOf(link)?.deviceId, neighbors[deviceId] != nil else { return }
            lastPacket[deviceId] = Date()
            neighbors[deviceId]?.lastPacket = lastPacket[deviceId]
            onPacket?(frame.payload, deviceId)
        }
    }

    private func helloOf(_ link: LinkID) -> Hello? {
        switch link {
        case .outgoing(let id): return outgoing[id]?.state == .ready ? outgoing[id]?.hello : nil
        case .incoming(let id): return incoming[id]?.hello
        }
    }

    private func receiveHello(_ payload: Data, on link: LinkID) {
        guard let identity else { return }
        let hello: Hello
        do { hello = try Hello.decode(payload) } catch {
            if case .outgoing(let id) = link {
                dropOutgoing(id, error: "Invalid handshake from neighbor", retryAfter: Self.incompatibleBackoff)
            }
            return
        }
        guard hello.isCompatible(frameId: identity.frameId), hello.deviceId != identity.deviceId else {
            // A peripheral can't disconnect a central; the central sees our hello and disconnects itself.
            if case .outgoing(let id) = link {
                let reason = hello.frameId != identity.frameId
                    ? "Nearby phone uses frame \(hello.frameId)"
                    : "Nearby phone runs protocol \(hello.protocolVersion); update all phones"
                dropOutgoing(id, error: hello.deviceId == identity.deviceId ? nil : reason, retryAfter: Self.incompatibleBackoff)
            }
            return
        }
        switch link {
        case .outgoing(let id):
            guard outgoing[id]?.hello == nil else { return }
            outgoing[id]?.hello = hello
            peers[id]?.deviceId = hello.deviceId
            completeOutgoingIfReady(id)
        case .incoming(let id):
            guard incoming[id] != nil, incoming[id]?.hello == nil else { return }
            incoming[id]?.hello = hello
            linkReady(hello)
        }
    }

    private func linkReady(_ hello: Hello) {
        refreshNeighbors()
        reconcile(hello.deviceId)
        if neighbors[hello.deviceId] != nil { onLinkReady?(hello.deviceId) }
    }

    // Keep one physical link per neighbor: the connection initiated by the lower device ID wins
    // once it is ready. The working link is kept until then, so there is no churn.
    private func reconcile(_ deviceId: String) {
        guard let identity else { return }
        let ready = outgoing.filter { $0.value.state == .ready && $0.value.hello?.deviceId == deviceId }
            .sorted { ($0.value.readyAt ?? .distantPast) < ($1.value.readyAt ?? .distantPast) }
        let hasIncoming = incoming.values.contains { $0.hello?.deviceId == deviceId }
        let keepOutgoing = identity.deviceId < deviceId || !hasIncoming
        for (offset, entry) in ready.enumerated() where !keepOutgoing || offset > 0 {
            retiring.insert(entry.key)
            dropOutgoing(entry.key, error: nil)
        }
    }

    private func preferredLink(for neighbor: Neighbor) -> LinkID? {
        guard let identity else { return nil }
        let out = neighbor.outgoing.map(LinkID.outgoing)
        let inc = neighbor.incoming.map(LinkID.incoming)
        return identity.deviceId < neighbor.deviceId ? (out ?? inc) : (inc ?? out)
    }

    private func refreshNeighbors() {
        var result: [String: Neighbor] = [:]
        for (id, link) in outgoing where link.state == .ready {
            guard let hello = link.hello else { continue }
            var neighbor = result[hello.deviceId] ?? Neighbor(deviceId: hello.deviceId)
            neighbor.label = hello.label
            if neighbor.outgoing == nil { neighbor.outgoing = id }
            result[hello.deviceId] = neighbor
        }
        for (id, link) in incoming {
            guard let hello = link.hello else { continue }
            var neighbor = result[hello.deviceId] ?? Neighbor(deviceId: hello.deviceId)
            neighbor.label = neighbor.label ?? hello.label
            if neighbor.incoming == nil { neighbor.incoming = id }
            result[hello.deviceId] = neighbor
        }
        for deviceId in Array(result.keys) {
            result[deviceId]?.rssi = result[deviceId]?.outgoing == nil ? nil : connectionRSSI[deviceId]
            result[deviceId]?.lastPacket = lastPacket[deviceId]
        }
        neighbors = result
    }

    // MARK: Sending

    // Sends to every neighbor once, over its preferred link, except the neighbor the payload came from.
    func broadcast(_ payload: Data, key: String, excluding: String? = nil) {
        guard running, let framed = Frame.encode(.position, payload) else { return }
        for neighbor in neighbors.values where neighbor.deviceId != excluding {
            enqueue(framed, key: key, to: neighbor)
        }
    }

    func send(_ payload: Data, key: String, to deviceId: String) {
        guard running, let neighbor = neighbors[deviceId], let framed = Frame.encode(.position, payload) else { return }
        enqueue(framed, key: key, to: neighbor)
    }

    private func enqueue(_ framed: Data, key: String, to neighbor: Neighbor) {
        switch preferredLink(for: neighbor) {
        case .outgoing(let id):
            outgoing[id]?.outbox.enqueue(framed, key: key)
            pumpWrite(id)
        case .incoming(let id):
            incoming[id]?.outbox.enqueue(framed, key: key)
            pumpNotifications()
        case nil:
            break
        }
    }

    // MARK: Housekeeping

    private func tick() {
        guard running else { return }
        let now = Date()
        for (id, link) in outgoing {
            if link.state == .ready {
                link.peripheral.readRSSI()
            } else if now.timeIntervalSince(link.startedAt) > Self.linkSetupTimeout {
                dropOutgoing(id, error: nil)
            }
        }
        // A subscriber that never completes the handshake is forgotten; its writes then fail and it reconnects.
        for (id, link) in incoming where link.hello == nil && now.timeIntervalSince(link.startedAt) > Self.linkSetupTimeout {
            incoming[id] = nil
        }
        for id in Array(outgoing.keys) where outgoing[id]?.assembler.isStale(at: now, timeout: 10) == true {
            outgoing[id]?.assembler.reset()
        }
        for id in Array(incoming.keys) where incoming[id]?.assembler.isStale(at: now, timeout: 10) == true {
            incoming[id]?.assembler.reset()
        }
        for (id, peer) in peers where outgoing[id] == nil && now.timeIntervalSince(peer.lastSeen) > 30 {
            peers[id] = nil
        }
        for (id, entry) in backoff where entry.until < now.addingTimeInterval(-300) {
            backoff[id] = nil
        }
        if central.state == .poweredOn, peripheralManager.state == .poweredOn {
            status = "Scanning and advertising (foreground) · \(neighbors.count) linked"
        }
    }
}
