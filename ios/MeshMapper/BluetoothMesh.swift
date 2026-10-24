import Combine
import CoreBluetooth
import Foundation
import MeshCore

/// A phone seen advertising the mesh service. Bluetooth identifiers differ per observer and
/// rotate, so they are for debugging only; mesh identity comes from the link Hello.
struct RadioPeer: Identifiable {
    let id: UUID
    var name: String
    /// Advertisement RSSI: advertising channels at an irregular rate.
    var rssi = RSSIStatistics()
    var lastSeen = Date()
    /// Advertised transmit power, when present. iPhones normally leave it out.
    var txPower: Int?
}

/// A mesh device with at least one ready link, identified through the link Hello.
struct MeshNeighbor: Identifiable {
    let deviceId: String
    let label: String?
    let outgoing: Bool
    let incoming: Bool
    /// Connection RSSI, sampled at 1 Hz; only available where this phone is the central.
    let connectionRSSI: RSSIStatistics?
    let advertisementRSSI: RSSIStatistics?
    let lastHeard: Date?
    var id: String { deviceId }
}

struct MeshIdentity {
    let deviceId: String
    let label: String?
    let frameId: String
}

enum LinkID: Hashable {
    /// This phone is the central; CBPeripheral identifier.
    case outgoing(UUID)
    /// This phone is the peripheral; CBCentral identifier.
    case incoming(UUID)

    var isOutgoing: Bool {
        if case .outgoing = self { return true }
        return false
    }
}

enum LinkState {
    case connecting, linking, ready
}

private struct Link {
    var state: LinkState
    let startedAt: Date
    var readyAt: Date?
    /// Central: notifications enabled. Peripheral: the central subscribed.
    var subscribed = false
    /// Hello mismatch on an incoming link, which a peripheral cannot disconnect.
    var rejected = false
    var deviceId: String?
    var label: String?
    var lastHeard: Date?
    var outbox = LinkOutbox()
    var assembler = FrameAssembler()
    var connectionRSSI = RSSIStatistics()
}

// All manager callbacks and callers run on the main queue.
final class BluetoothMesh: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate {
    static let serviceID = CBUUID(string: "F7A40001-5AB1-4E90-A989-21B5E52E2210")
    static let characteristicID = CBUUID(string: "F7A40002-5AB1-4E90-A989-21B5E52E2210")
    /// Logical neighbors per phone; an app resource budget, not an iOS limit.
    static let maxNeighbors = 8
    /// Connect, discovery, subscription and Hello must finish within this time.
    static let linkTimeout: TimeInterval = 10
    static let rejectRetryDelay: TimeInterval = 60
    /// A link that stayed ready this long resets its peripheral's failure backoff.
    static let stableLinkAge: TimeInterval = 30
    static let droppableBacklog = 16

    @Published private(set) var peers: [UUID: RadioPeer] = [:]
    @Published private(set) var neighbors: [MeshNeighbor] = []
    @Published private(set) var pendingLinks = 0
    @Published private(set) var status = "Bluetooth stopped"
    @Published private(set) var lastError: String?
    /// One snapshot per peer and channel, refreshed every second while running. Each carries the
    /// raw RSSI samples since the previous refresh, so read every refresh to see every sample.
    @Published private(set) var sightings: [PeerSighting] = []
    /// `sightings` as shared-contract records, in the mesh frame; same refresh.
    @Published private(set) var observations: [PeerObservation] = []
    /// Test only, for proving multi-hop with phones in one room: refuse links to these app device
    /// IDs. Set it on both phones of a pair. Not persisted, so a restart clears it.
    @Published var blockedDeviceIds = Set<String>() {
        didSet { closeBlockedLinks() }
    }
    /// Timestamped link and relay events for hardware test evidence.
    let eventLog = MeshEventLog()
    /// Store-and-forward messages (frame types 5 and 6); runs while the mesh runs.
    private(set) lazy var relay = MeshRelay(bluetooth: self, log: eventLog)
    /// Position packet payload plus the device ID of the neighbor it arrived from.
    var onPacket: ((Data, String) -> Void)?
    /// A neighbor gained its first ready link.
    var onNeighborReady: ((String) -> Void)?
    /// Link-local ranging frame (`.rangingToken` or `.rangingFix`) plus the neighbor's device ID.
    var onRanging: ((FrameType, Data, String) -> Void)?

    private enum Retry {
        case backoff
        case after(TimeInterval)
    }

    private var central: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    private var characteristic: CBMutableCharacteristic?
    private var serviceAdded = false
    private var running = false
    private var identity: MeshIdentity?
    private var links: [LinkID: Link] = [:]
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var remoteCharacteristics: [UUID: CBCharacteristic] = [:]
    private var subscribers: [UUID: CBCentral] = [:]
    private var writing = Set<UUID>()
    private var retryAfter: [UUID: Date] = [:]
    private var failures: [UUID: Int] = [:]
    /// Device ID learned from the Hello of each peripheral this phone connected to.
    private var peripheralDevice: [UUID: String] = [:]
    private var relayTokens: [String: Int] = [:]
    /// Final connection snapshots of links that closed since the last refresh.
    private var lostSightings: [PeerSighting] = []
    /// Per peer and channel since the last summary: snapshots with new samples, raw samples, latest.
    private var observationTally: [String: (snapshots: Int, samples: Int, last: PeerSighting)] = [:]
    private var ticks = 0
    private var timer: Timer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func start(_ identity: MeshIdentity) {
        self.identity = identity
        running = true
        eventLog.note("mesh", "start \(MeshEventLog.short(identity.deviceId)) frame \(identity.frameId) wire v\(MeshProtocol.version)")
        relay.start(selfId: identity.deviceId)
        activate()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Rescans and re-advertises, for example after returning to the foreground.
    func resume() {
        activate()
    }

    func stop() {
        if running { eventLog.note("mesh", "stop") }
        running = false
        relay.stop()
        timer?.invalidate()
        timer = nil
        if central.state == .poweredOn { central.stopScan() }
        if peripheralManager.state == .poweredOn {
            peripheralManager.stopAdvertising()
            // Removing the service ends remote subscriptions, so no stale links survive a restart.
            peripheralManager.removeAllServices()
        }
        characteristic = nil
        serviceAdded = false
        for peripheral in peripherals.values where peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        links.removeAll()
        peripherals.removeAll()
        remoteCharacteristics.removeAll()
        subscribers.removeAll()
        writing.removeAll()
        retryAfter.removeAll()
        failures.removeAll()
        peripheralDevice.removeAll()
        relayTokens.removeAll()
        peers.removeAll()
        sightings = []
        observations = []
        lostSightings = []
        refreshNeighbors()
        status = "Bluetooth stopped"
    }

    private func activate() {
        guard running else { return }
        guard central.state == .poweredOn, peripheralManager.state == .poweredOn else {
            if central.state == .unauthorized || peripheralManager.state == .unauthorized {
                status = "Bluetooth permission denied. Allow it in Settings > Privacy & Security > Bluetooth, then return here."
            } else {
                status = "Bluetooth unavailable: \(stateName(central.state)) / \(stateName(peripheralManager.state))"
            }
            return
        }
        central.scanForPeripherals(withServices: [Self.serviceID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
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
        eventLog.note("radio", "central \(stateName(central.state))")
        if central.state != .poweredOn {
            links = links.filter { !$0.key.isOutgoing }
            peripherals.removeAll()
            remoteCharacteristics.removeAll()
            writing.removeAll()
            refreshNeighbors()
        }
        activate()
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        eventLog.note("radio", "peripheral \(stateName(peripheral.state))")
        if peripheral.state != .poweredOn {
            characteristic = nil
            serviceAdded = false
            links = links.filter { $0.key.isOutgoing }
            subscribers.removeAll()
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
        let now = Date()
        guard peers[id] != nil || peers.count < 100 else { return }
        var peer = peers[id] ?? RadioPeer(id: id, name: peripheral.name ?? "Mapping phone")
        peer.rssi.record(RSSI.intValue, at: now)
        peer.lastSeen = now
        if let power = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber { peer.txPower = power.intValue }
        peers[id] = peer
        peripherals[id] = peripheral

        guard peripheral.state == .disconnected, links[.outgoing(id)] == nil,
              now >= retryAfter[id] ?? .distantPast else { return }
        // Already linked to this device in the other direction, or excluded by the test filter.
        if let deviceId = peripheralDevice[id], hasReadyLink(to: deviceId) || blockedDeviceIds.contains(deviceId) { return }
        guard links.keys.filter(\.isOutgoing).count < Self.maxNeighbors,
              readyNeighborIds.count < Self.maxNeighbors else { return }
        peripheral.delegate = self
        links[.outgoing(id)] = Link(state: .connecting, startedAt: now)
        central.connect(peripheral, options: nil)
        refreshNeighbors()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        guard running, links[.outgoing(id)] != nil else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        links[.outgoing(id)]?.state = .linking
        peripheral.discoverServices([Self.serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        closeOutgoing(peripheral.identifier, retry: .backoff, reason: error?.localizedDescription)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        closeOutgoing(peripheral.identifier, retry: .backoff, reason: error?.localizedDescription)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let id = peripheral.identifier
        if let error { closeOutgoing(id, retry: .backoff, reason: error.localizedDescription); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else {
            closeOutgoing(id, retry: .after(Self.rejectRetryDelay), reason: "Nearby device has no mesh service")
            return
        }
        peripheral.discoverCharacteristics([Self.characteristicID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let id = peripheral.identifier
        if let error { closeOutgoing(id, retry: .backoff, reason: error.localizedDescription); return }
        guard let value = service.characteristics?.first(where: { $0.uuid == Self.characteristicID }),
              value.properties.contains(.write), value.properties.contains(.notify) else {
            closeOutgoing(id, retry: .after(Self.rejectRetryDelay), reason: "Nearby device has an incompatible mesh service")
            return
        }
        remoteCharacteristics[id] = value
        peripheral.setNotifyValue(true, for: value)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        if let error { closeOutgoing(id, retry: .backoff, reason: error.localizedDescription); return }
        guard characteristic.isNotifying else {
            closeOutgoing(id, retry: .backoff, reason: "Nearby phone stopped notifications")
            return
        }
        guard links[.outgoing(id)] != nil else { return }
        links[.outgoing(id)]?.subscribed = true
        sendHello(on: .outgoing(id))
        updateReadiness(.outgoing(id))
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        let id = peripheral.identifier
        links[.outgoing(id)]?.connectionRSSI.record(RSSI.intValue)
        peers[id]?.lastSeen = Date()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard running, error == nil, characteristic.uuid == Self.characteristicID, let data = characteristic.value else { return }
        receive(data, on: .outgoing(peripheral.identifier))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        writing.remove(id)
        if let error { closeOutgoing(id, retry: .backoff, reason: error.localizedDescription); return }
        links[.outgoing(id)]?.outbox.chunkSent()
        pumpWrite(id)
    }

    /// Ends an outgoing link and schedules the next attempt. Safe to call more than once.
    private func closeOutgoing(_ id: UUID, retry: Retry, reason: String? = nil) {
        guard let link = links.removeValue(forKey: .outgoing(id)) else { return }
        if let reason { lastError = reason }
        remoteCharacteristics[id] = nil
        writing.remove(id)
        if let peripheral = peripherals[id], peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        let now = Date()
        let delay: TimeInterval
        switch retry {
        case .after(let fixed):
            delay = fixed
        case .backoff:
            if let readyAt = link.readyAt, now.timeIntervalSince(readyAt) >= Self.stableLinkAge { failures[id] = nil }
            let count = (failures[id] ?? 0) + 1
            failures[id] = count
            delay = ReconnectBackoff.delay(afterFailures: count)
        }
        retryAfter[id] = now.addingTimeInterval(delay)
        var statistics = link.connectionRSSI
        if let identity, link.state == .ready,
           let last = PeerSighting.take(from: &statistics, observerId: identity.deviceId, peerId: link.deviceId,
                                        transportHandle: id, label: link.label, channel: .connection, linkState: .lost,
                                        lastHeardAt: link.lastHeard, now: now) {
            lostSightings.append(last)
        }
        let peer = link.deviceId.map(MeshEventLog.short) ?? "radio \(MeshEventLog.short(id.uuidString))"
        let held = link.readyAt.map { String(format: " after %.0f s ready", now.timeIntervalSince($0)) } ?? " (never ready)"
        eventLog.note("link", "closed out \(peer)\(held): \(reason ?? "closed"); retry in \(String(format: "%.1f", delay)) s")
        refreshNeighbors()
    }

    // MARK: Peripheral role (incoming links)

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard running else { return }
        let id = central.identifier
        let incoming = links.keys.filter { !$0.isOutgoing }.count
        guard links[.incoming(id)] != nil || incoming < Self.maxNeighbors else { return }
        subscribers[id] = central
        links[.incoming(id)] = Link(state: .linking, startedAt: Date(), subscribed: true)
        sendHello(on: .incoming(id))
        refreshNeighbors()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribers[central.identifier] = nil
        if let link = links.removeValue(forKey: .incoming(central.identifier)) {
            let peer = link.deviceId.map(MeshEventLog.short) ?? "radio \(MeshEventLog.short(central.identifier.uuidString))"
            let held = link.readyAt.map { String(format: " after %.0f s ready", Date().timeIntervalSince($0)) } ?? " (never ready)"
            eventLog.note("link", "closed in \(peer)\(held): central unsubscribed")
        }
        refreshNeighbors()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Respond exactly once, to the first request, and fail the whole batch if any request fails.
        guard let first = requests.first else { return }
        func isOpen(_ request: CBATTRequest) -> Bool {
            links[.incoming(request.central.identifier)].map { !$0.rejected } ?? false
        }
        let valid = running && requests.allSatisfy { request in
            request.characteristic.uuid == Self.characteristicID && request.offset == 0
                && request.value != nil && isOpen(request)
        }
        guard valid else {
            peripheral.respond(to: first, withResult: .unlikelyError)
            return
        }
        for request in requests {
            receive(request.value ?? Data(), on: .incoming(request.central.identifier))
        }
        // A peripheral cannot disconnect a central, but a failed write makes it close the link and
        // back off. Without this, a central rejected for the neighbor limit already holds our valid
        // Hello, treats the link as ready and keeps sending packets that are dropped here.
        peripheral.respond(to: first, withResult: requests.allSatisfy(isOpen) ? .success : .unlikelyError)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { pumpNotifications() }

    // MARK: Handshake

    private func sendHello(on linkId: LinkID) {
        guard let identity,
              let payload = try? Hello(frameId: identity.frameId, deviceId: identity.deviceId, label: identity.label).encoded(),
              let framed = Framing.encode(payload, type: .hello) else { return }
        enqueue(framed, key: "hello", on: linkId)
    }

    private func handleHello(_ payload: Data, on linkId: LinkID) {
        guard let identity, links[linkId] != nil else { return }
        guard let hello = try? Hello.decode(payload) else {
            reject(linkId, reason: "Invalid hello from a nearby phone")
            return
        }
        guard hello.protocolVersion == MeshProtocol.version else {
            reject(linkId, reason: "A nearby phone runs mesh protocol \(hello.protocolVersion); this phone runs \(MeshProtocol.version). Update all phones.")
            return
        }
        guard hello.frameId == identity.frameId else {
            reject(linkId, reason: "A nearby phone uses frame \(hello.frameId)")
            return
        }
        guard hello.deviceId != identity.deviceId else {
            reject(linkId, reason: "Linked to itself")
            return
        }
        if case .outgoing(let id) = linkId { peripheralDevice[id] = hello.deviceId }
        guard !blockedDeviceIds.contains(hello.deviceId) else {
            reject(linkId, reason: "Ignoring \(hello.label ?? MeshEventLog.short(hello.deviceId)) (test filter)")
            return
        }
        links[linkId]?.deviceId = hello.deviceId
        links[linkId]?.label = hello.label
        updateReadiness(linkId)
    }

    private func reject(_ linkId: LinkID, reason: String) {
        switch linkId {
        case .outgoing(let id):
            closeOutgoing(id, retry: .after(Self.rejectRetryDelay), reason: reason)
        case .incoming:
            // A peripheral cannot disconnect a central. The central receives our Hello and disconnects,
            // or its next write fails and it backs off. Nothing more is sent or accepted here.
            if links[linkId]?.state == .ready { links[linkId]?.state = .linking }
            links[linkId]?.rejected = true
            links[linkId]?.outbox.removeAll()
            lastError = reason
            eventLog.note("link", "refused in: \(reason)")
            refreshNeighbors()
        }
    }

    private func closeBlockedLinks() {
        for (linkId, link) in links {
            guard let deviceId = link.deviceId, blockedDeviceIds.contains(deviceId) else { continue }
            reject(linkId, reason: "Ignoring \(link.label ?? MeshEventLog.short(deviceId)) (test filter)")
        }
        eventLog.note("filter", blockedDeviceIds.isEmpty ? "test filter off"
                      : "test filter ignores " + blockedDeviceIds.sorted().map(MeshEventLog.short).joined(separator: ", "))
        refreshNeighbors()
    }

    /// A link is ready once subscribed and a valid Hello arrived from the other side.
    private func updateReadiness(_ linkId: LinkID) {
        guard let link = links[linkId], link.state != .ready, !link.rejected, link.subscribed,
              let deviceId = link.deviceId else { return }
        let isNewNeighbor = !hasReadyLink(to: deviceId)
        if isNewNeighbor, readyNeighborIds.count >= Self.maxNeighbors {
            reject(linkId, reason: "Neighbor limit (\(Self.maxNeighbors)) reached")
            return
        }
        links[linkId]?.state = .ready
        links[linkId]?.readyAt = Date()
        eventLog.note("link", "ready \(linkId.isOutgoing ? "out" : "in") \(link.label ?? "") \(MeshEventLog.short(deviceId)) "
                      + String(format: "after %.1f s, chunk %d B", Date().timeIntervalSince(link.startedAt), chunkLimit(linkId)))
        reconcileLinks(to: deviceId)
        refreshNeighbors()
        if isNewNeighbor { onNeighborReady?(deviceId) }
    }

    /// Keeps the link initiated by the lower device ID (app.md). Only the higher side holds a
    /// redundant outgoing link it can close; a peripheral cannot close an incoming one.
    private func reconcileLinks(to deviceId: String) {
        guard let identity, identity.deviceId > deviceId else { return }
        let ready = links.filter { $0.value.deviceId == deviceId && $0.value.state == .ready }.keys
        guard ready.contains(where: { !$0.isOutgoing }) else { return }
        for case .outgoing(let id) in ready {
            closeOutgoing(id, retry: .after(5))
        }
    }

    private func hasReadyLink(to deviceId: String) -> Bool {
        links.values.contains { $0.deviceId == deviceId && $0.state == .ready }
    }

    private var readyNeighborIds: Set<String> {
        Set(links.values.compactMap { $0.state == .ready ? $0.deviceId : nil })
    }

    private func preferredLink(to deviceId: String) -> LinkID? {
        guard let identity else { return nil }
        let ready = links.filter { $0.value.deviceId == deviceId && $0.value.state == .ready }.keys
        let canonicalIsOutgoing = identity.deviceId < deviceId
        return ready.first { $0.isOutgoing == canonicalIsOutgoing } ?? ready.first
    }

    // MARK: Sending

    /// Queues a position packet once per ready neighbor, except `excluded`. A newer packet with
    /// the same `key` replaces one still queued on a link.
    func broadcast(_ payload: Data, key: String, except excluded: String? = nil) {
        guard running, let framed = Framing.encode(payload, type: .position) else { return }
        for deviceId in readyNeighborIds where deviceId != excluded {
            if let linkId = preferredLink(to: deviceId) { enqueue(framed, key: key, on: linkId) }
        }
    }

    /// Queues a frame for one neighbor. A `droppable` frame is skipped while that link already has
    /// `droppableBacklog` frames waiting, so a slow link sheds events instead of queueing them.
    func send(_ payload: Data, type: FrameType = .position, key: String, to deviceId: String, droppable: Bool = false) {
        guard running, let framed = Framing.encode(payload, type: type),
              let linkId = preferredLink(to: deviceId) else { return }
        if droppable, (links[linkId]?.outbox.pendingCount ?? 0) >= Self.droppableBacklog { return }
        enqueue(framed, key: key, on: linkId)
    }

    /// Broadcasts after a random 0–100 ms delay so neighbors that received the same packet don't
    /// all transmit at once. A later relay with the same key supersedes a pending one.
    func relay(_ payload: Data, key: String, except excluded: String) {
        let token = (relayTokens[key] ?? 0) &+ 1
        relayTokens[key] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int.random(in: 0...100))) { [weak self] in
            guard let self, self.relayTokens[key] == token else { return }
            self.broadcast(payload, key: key, except: excluded)
        }
    }

    private func enqueue(_ framed: Data, key: String, on linkId: LinkID) {
        links[linkId]?.outbox.enqueue(framed, key: key)
        switch linkId {
        case .outgoing(let id): pumpWrite(id)
        case .incoming: pumpNotifications()
        }
    }

    /// Largest chunk this link sends in one ATT operation; logged so MTU problems show in test logs.
    private func chunkLimit(_ linkId: LinkID) -> Int {
        switch linkId {
        case .outgoing(let id): return peripherals[id]?.maximumWriteValueLength(for: .withoutResponse) ?? 0
        case .incoming(let id): return subscribers[id]?.maximumUpdateValueLength ?? 0
        }
    }

    private func pumpWrite(_ id: UUID) {
        guard running, !writing.contains(id), let peripheral = peripherals[id], peripheral.state == .connected,
              let value = remoteCharacteristics[id],
              // Fit a single ATT write: a longer one becomes a prepared write, which the peer rejects.
              let chunk = links[.outgoing(id)]?.outbox.nextChunk(
                maxLength: peripheral.maximumWriteValueLength(for: .withoutResponse)) else { return }
        writing.insert(id)
        peripheral.writeValue(chunk, for: value, type: .withResponse)
    }

    private func pumpNotifications() {
        guard running, let characteristic else { return }
        for (linkId, link) in links where !link.outbox.isEmpty {
            guard case .incoming(let id) = linkId, let subscriber = subscribers[id] else { continue }
            while let chunk = links[linkId]?.outbox.nextChunk(maxLength: subscriber.maximumUpdateValueLength) {
                // Resume from peripheralManagerIsReady(toUpdateSubscribers:).
                guard peripheralManager.updateValue(chunk, for: characteristic, onSubscribedCentrals: [subscriber]) else { return }
                links[linkId]?.outbox.chunkSent()
            }
        }
    }

    // MARK: Receiving

    private func receive(_ data: Data, on linkId: LinkID) {
        guard running, var link = links[linkId] else { return }
        let frames: [Frame]
        do {
            frames = try link.assembler.append(data)
        } catch {
            links[linkId]?.assembler.reset()
            if case .outgoing(let id) = linkId {
                closeOutgoing(id, retry: .backoff, reason: "Invalid BLE frame; is every phone on the same app version?")
            } else {
                lastError = "Invalid BLE frame; is every phone on the same app version?"
            }
            return
        }
        link.lastHeard = Date()
        links[linkId] = link
        for frame in frames {
            switch frame.type {
            case .hello:
                handleHello(frame.payload, on: linkId)
            case .position, .rangingToken, .rangingFix, .relayMessage, .relaySummary, .record:
                guard let current = links[linkId], current.state == .ready, let deviceId = current.deviceId else { continue }
                switch frame.type {
                case .position: onPacket?(frame.payload, deviceId)
                case .relayMessage, .relaySummary, .record: relay.receive(frame, from: deviceId)
                default: onRanging?(frame.type, frame.payload, deviceId)
                }
            }
        }
    }

    // MARK: Neighbors

    /// Ready links for `DeviceUpdate.neighbors`: connection RSSI where this phone is the central,
    /// otherwise the neighbor's advertisement RSSI. Link quality only, never a distance.
    func neighborObservations(at now: Date = Date()) -> [NeighborObservation] {
        refreshNeighbors()
        return neighbors.prefix(DashboardContract.maxNeighbors).map { neighbor in
            let rssi = (neighbor.connectionRSSI ?? neighbor.advertisementRSSI)?.smoothed.map { Int($0.rounded()) }
            let age = neighbor.lastHeard.map {
                min(DashboardContract.maxAgeMs, max(0, Int((now.timeIntervalSince($0) * 1000).rounded())))
            }
            return NeighborObservation(id: neighbor.deviceId, rssi: rssi, ageMs: age)
        }
    }

    private func refreshNeighbors() {
        neighbors = readyNeighborIds.sorted().map { deviceId in
            let ready = links.filter { $0.value.deviceId == deviceId && $0.value.state == .ready }
            let outgoing = ready.first { $0.key.isOutgoing }?.value
            let advertisement = peripheralDevice.first { $0.value == deviceId }.flatMap { peers[$0.key]?.rssi }
            return MeshNeighbor(
                deviceId: deviceId,
                label: ready.values.compactMap(\.label).first,
                outgoing: outgoing != nil,
                incoming: ready.keys.contains { !$0.isOutgoing },
                connectionRSSI: (outgoing?.connectionRSSI.sampleCount ?? 0) > 0 ? outgoing?.connectionRSSI : nil,
                advertisementRSSI: advertisement,
                lastHeard: ready.values.compactMap(\.lastHeard).max()
            )
        }
        pendingLinks = links.values.filter { $0.state != .ready }.count
        relay.updateNeighbors(readyNeighborIds)
    }

    /// Logs, every 10 s, how many snapshots per peer and channel carried new samples (test T2).
    private func tallyObservations() {
        for sighting in sightings where !sighting.samples.isEmpty {
            let key = (sighting.peerId ?? "radio " + MeshEventLog.short(sighting.transportHandle?.uuidString ?? "?"))
                + " " + sighting.channel.rawValue
            let tally = observationTally[key]
            observationTally[key] = ((tally?.snapshots ?? 0) + 1, (tally?.samples ?? 0) + sighting.samples.count, sighting)
        }
        ticks += 1
        guard ticks % 10 == 0, !observationTally.isEmpty else { return }
        for (key, tally) in observationTally.sorted(by: { $0.key < $1.key }) {
            let smoothed = tally.last.smoothedRSSI.map { String(format: "%.1f", $0) } ?? "–"
            let deviation = tally.last.rssiStandardDeviation.map { String(format: "%.1f", $0) } ?? "–"
            eventLog.note("obs", "10 s: \(key) \(tally.last.linkState.rawValue): \(tally.snapshots) snapshots with samples, "
                          + "\(tally.samples) raw, smoothed \(smoothed) dBm, sd \(deviation) dB")
        }
        observationTally = [:]
    }

    /// Snapshots every peer heard in the last 30 s, draining raw RSSI samples into them.
    private func takeSightings(at now: Date) -> [PeerSighting] {
        guard let identity else { return [] }
        var result: [PeerSighting] = []
        for (linkId, link) in links {
            guard case .outgoing(let id) = linkId,
                  let sighting = PeerSighting.take(
                    from: &links[linkId]!.connectionRSSI, observerId: identity.deviceId, peerId: link.deviceId,
                    transportHandle: id, label: link.label, channel: .connection,
                    linkState: link.state == .ready ? .ready : .linking, lastHeardAt: link.lastHeard, now: now)
            else { continue }
            result.append(sighting)
        }
        for (id, peer) in peers where now.timeIntervalSince(peer.lastSeen) <= 30 {
            // The device ID is known only if this phone once connected to the peer and got its Hello.
            let deviceId = peripheralDevice[id]
            let ready = deviceId.map(hasReadyLink(to:)) ?? false
            let linking = links[.outgoing(id)].map { $0.state != .ready } ?? false
            let readyLinks = links.values.filter { $0.deviceId == deviceId && $0.state == .ready }
            guard let sighting = PeerSighting.take(
                from: &peers[id]!.rssi, observerId: identity.deviceId, peerId: deviceId, transportHandle: id,
                label: readyLinks.compactMap(\.label).first, channel: .advertisement,
                linkState: ready ? .ready : linking ? .linking : .advertised,
                lastHeardAt: readyLinks.compactMap(\.lastHeard).max(), txPower: peer.txPower, now: now)
            else { continue }
            result.append(sighting)
        }
        return result.sorted { ($0.peerId ?? "~", $0.channel.rawValue) < ($1.peerId ?? "~", $1.channel.rawValue) }
    }

    private func tick() {
        guard running else { return }
        let now = Date()
        for (linkId, link) in links {
            links[linkId]?.assembler.expire(at: now)
            guard case .outgoing(let id) = linkId else { continue }
            if link.state != .ready, now.timeIntervalSince(link.startedAt) > Self.linkTimeout {
                closeOutgoing(id, retry: .backoff, reason: "Link setup timed out")
                continue
            }
            if let readyAt = link.readyAt, now.timeIntervalSince(readyAt) >= Self.stableLinkAge { failures[id] = nil }
            if peripherals[id]?.state == .connected { peripherals[id]?.readRSSI() }
        }
        for (id, peer) in peers where now.timeIntervalSince(peer.lastSeen) > 30 && links[.outgoing(id)] == nil {
            if let peripheral = peripherals[id], peripheral.state != .disconnected {
                central.cancelPeripheralConnection(peripheral)
            }
            peers[id] = nil
            peripherals[id] = nil
            retryAfter[id] = nil
            failures[id] = nil
            peripheralDevice[id] = nil
        }
        refreshNeighbors()
        sightings = lostSightings + takeSightings(at: now)
        lostSightings = []
        tallyObservations()
        if let identity {
            observations = sightings.compactMap { $0.observation(frameId: identity.frameId) }
        }
        relay.tick()
    }
}
