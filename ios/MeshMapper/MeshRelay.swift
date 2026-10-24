import Combine
import Foundation
import MeshCore
import UIKit

/// Messaging over the Bluetooth mesh. Drives `RelayEngine` (store-and-forward messages, frame
/// types 5 and 6) and `RecordRelay` (GhostCore contract records, frame type 7). `BluetoothMesh`
/// owns it and starts and stops it with the mesh. Main thread only, like `BluetoothMesh`.
final class MeshRelay: ObservableObject {
    struct SentMessage: Identifiable {
        let envelope: RelayEnvelope
        let sentAt: Date
        var receipt: RelayDelivery?
        var id: UUID { envelope.messageId }
    }

    struct ReceivedMessage: Identifiable {
        let delivery: RelayDelivery
        /// This phone's wall clock on arrival, for reading only.
        let arrivedAt: Date
        var id: UUID { delivery.envelope.messageId }
    }

    static let maxListed = 200

    @Published private(set) var isRunning = false
    @Published private(set) var selfId: String?
    @Published private(set) var sent: [SentMessage] = []
    @Published private(set) var received: [ReceivedMessage] = []
    @Published private(set) var statistics = RelayStatistics()
    @Published private(set) var storedCount = 0
    /// Ready neighbors that run the relay.
    @Published private(set) var relayNeighbors: [String] = []
    /// Labels of phones seen in a Hello or as a message origin or relay; empty when unknown.
    @Published private(set) var knownPeers: [String: String] = [:]
    @Published private(set) var recordStatistics = RecordRelayStatistics()
    /// Relays of the latest accepted record from each origin, oldest first.
    @Published private(set) var recordRoutes: [String: [String]] = [:]

    /// Every delivered message, receipts included, for modules that send their own kinds.
    var onDelivery: ((RelayDelivery) -> Void)?
    /// Every accepted contract record, as it arrives. `takeReceivedRecords()` returns them too.
    var onRecord: ((ReceivedRecord) -> Void)?

    static let maxPendingRecords = 512

    /// Relay test T3: this phone's beacon run while sending, and what arrived from others' runs.
    @Published private(set) var beaconRun: String?
    @Published private(set) var beaconsSent = 0
    @Published private(set) var beaconStats: [String: BeaconStats] = [:]
    private var beaconTimer: Timer?
    private var beaconHops = 2

    private unowned let bluetooth: BluetoothMesh
    private let log: MeshEventLog
    private var engine: RelayEngine?
    private var records: RecordRelay?
    private var pendingRecords: [ReceivedRecord] = []
    private var linked = Set<String>()

    init(bluetooth: BluetoothMesh, log: MeshEventLog) {
        self.bluetooth = bluetooth
        self.log = log
    }

    /// Seconds on a clock that keeps counting while the phone sleeps and never follows wall clock
    /// changes. Ages and TTLs use it; wall clocks on different phones are never compared.
    static func monotonicNow() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    func start(selfId: String) {
        engine = RelayEngine(selfId: selfId)
        records = RecordRelay(selfId: selfId)
        pendingRecords = []
        recordRoutes = [:]
        self.selfId = selfId
        isRunning = true
        linked = []
        sent = []
        received = []
        refresh()
    }

    func stop() {
        stopBeacon()
        engine = nil
        records = nil
        pendingRecords = []
        isRunning = false
        linked = []
        refresh()
    }

    // MARK: Transport events

    func updateNeighbors(_ ready: Set<String>) {
        guard let engine, ready != linked else { return }
        let now = Self.monotonicNow()
        for neighbor in linked.subtracting(ready).sorted() {
            engine.neighborLost(neighbor)
            records?.neighborLost(neighbor)
            log.note("relay", "neighbor gone \(name(neighbor))")
        }
        for neighbor in ready.subtracting(linked).sorted() {
            if let label = bluetooth.neighbors.first(where: { $0.deviceId == neighbor })?.label { knownPeers[neighbor] = label }
            learn(neighbor)
            perform(engine.neighborReady(neighbor, now: now))
            if let records { perform(records.neighborReady(neighbor, now: now)) }
        }
        linked = ready
        refresh()
    }

    func receive(_ frame: Frame, from neighbor: String) {
        if frame.type == .record {
            guard let records else { return }
            let invalid = records.statistics.invalid
            perform(records.receive(frame, from: neighbor, now: Self.monotonicNow(), wallClock: Date().timeIntervalSince1970))
            if records.statistics.invalid > invalid { log.note("record", "invalid record from \(name(neighbor))") }
            refresh()
            return
        }
        guard let engine else { return }
        let before = engine.statistics
        perform(engine.receive(frame, from: neighbor, now: Self.monotonicNow()))
        let after = engine.statistics
        if frame.type == .relayMessage {
            if after.duplicates > before.duplicates { log.note("relay", "duplicate from \(name(neighbor)) suppressed") }
            if after.loops > before.loops { log.note("relay", "looped copy from \(name(neighbor)) dropped") }
            if after.expired > before.expired { log.note("relay", "expired copy from \(name(neighbor)) dropped") }
            if after.invalid > before.invalid { log.note("relay", "invalid message from \(name(neighbor))") }
        }
        refresh()
    }

    func tick() {
        records?.tick(now: Self.monotonicNow())
        guard let engine else { return }
        let expired = engine.statistics.expired
        perform(engine.tick(now: Self.monotonicNow()))
        if engine.statistics.expired > expired {
            log.note("relay", "\(engine.statistics.expired - expired) stored message(s) reached their TTL")
        }
        refresh()
    }

    // MARK: Sending

    /// Sends a message from this phone. Returns a readable error, or nil on success.
    @discardableResult
    func send(kind: String = "text", body: String, to destination: String?, ttlMs: Int, hops: Int) -> String? {
        guard let engine else { return "Start the mesh first" }
        do {
            let (envelope, actions) = try engine.originate(
                kind: kind, body: body, to: destination, ttlMs: ttlMs, hops: hops,
                now: Self.monotonicNow(), wallClock: Date())
            let isBeacon = kind == BeaconPayload.kind
            if !isBeacon {
                sent.insert(SentMessage(envelope: envelope, sentAt: Date()), at: 0)
                if sent.count > Self.maxListed { sent.removeLast() }
            }
            let copies = actions.filter { if case .send = $0 { return true } else { return false } }.count
            log.note(isBeacon ? "t3" : "relay", "sent \(envelope.messageId.uuidString) \(kind)\(isBeacon ? " " + body : "") to "
                     + "\(destination.map(name) ?? "everyone"), TTL \(ttlMs / 1000) s, \(hops) hops, "
                     + "\(copies) neighbor(s) now")
            perform(actions)
            refresh()
            return nil
        } catch {
            return "Message not sent: at most \(RelayEnvelope.maxBodyBytes) bytes, TTL up to \(RelayEnvelope.maxTTLMs / 60_000) min, 0–\(RelayEnvelope.maxHops) hops"
        }
    }

    // MARK: Relay test T3

    /// Sends a numbered broadcast beacon every second until stopped (BLE_MESH_TEST_PROTOCOL.md, T3).
    func startBeacon(hops: Int) {
        stopBeacon()
        guard engine != nil else { return }
        let run = String(UUID().uuidString.prefix(8))
        beaconRun = run
        beaconsSent = 0
        beaconHops = hops
        log.note("t3", "beacon run \(run) started: 1 Hz, \(hops) hops, TTL 30 s")
        beaconTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sendBeacon() }
        sendBeacon()
    }

    func stopBeacon() {
        beaconTimer?.invalidate()
        beaconTimer = nil
        if let run = beaconRun { log.note("t3", "beacon run \(run) stopped after \(beaconsSent) beacons") }
        beaconRun = nil
    }

    func resetBeaconStats() {
        beaconStats = [:]
        log.note("t3", "received beacon statistics reset")
    }

    private func sendBeacon() {
        guard let run = beaconRun else { return }
        if send(kind: BeaconPayload.kind, body: BeaconPayload(run: run, seq: beaconsSent).body, to: nil,
                ttlMs: 30_000, hops: beaconHops) == nil {
            beaconsSent += 1
        }
    }

    // MARK: Contract records

    /// Sends one of this phone's records (built by the pipeline: origin = this phone, empty path).
    /// Returns a readable error, or nil on success.
    @discardableResult
    func send(record message: RelayMessage) -> String? {
        guard let records else { return "Start the mesh first" }
        do {
            perform(try records.publish(message, now: Self.monotonicNow()))
            log.note("record", "published \(RecordRelay.payloadType(message.payload)) \(message.messageId) "
                     + "epoch \(message.epochId) seq \(message.sequence) hops \(message.hopsRemaining)")
            refresh()
            return nil
        } catch {
            log.note("record", "not sent: \(RecordRelay.payloadType(message.payload)) seq \(message.sequence): \(error)")
            return "Record not sent: \(error)"
        }
    }

    /// Records accepted since the last call, oldest first: this phone's pipeline input.
    func takeReceivedRecords() -> [ReceivedRecord] {
        defer { pendingRecords.removeAll() }
        return pendingRecords
    }

    // MARK: Names

    func name(_ deviceId: String) -> String {
        if deviceId == selfId { return "this phone" }
        if let label = knownPeers[deviceId], !label.isEmpty { return label }
        return MeshEventLog.short(deviceId)
    }

    /// "Origin → relay → … → this phone" for a delivered copy.
    func route(_ envelope: RelayEnvelope) -> String {
        ([envelope.originId] + envelope.path).map(name).joined(separator: " → ") + " → this phone"
    }

    // MARK: Internals

    private func perform(_ actions: [RecordAction]) {
        for action in actions {
            switch action {
            case .send(let message, let neighbor, let key, let droppable):
                guard let payload = try? message.encoded() else { continue }
                bluetooth.send(payload, type: .record, key: key, to: neighbor, droppable: droppable)
            case .deliver(let record):
                let message = record.message
                log.note("record", "received \(RecordRelay.payloadType(message.payload)) \(message.messageId) from \(message.originId) "
                         + "epoch \(message.epochId) seq \(message.sequence) path [\(message.path.joined(separator: ","))] "
                         + String(format: "ageAtHandoff %.3f", message.freshness.ageAtHandoff) + " via \(name(record.fromNeighbor))")
                if pendingRecords.count >= Self.maxPendingRecords { pendingRecords.removeFirst() }
                pendingRecords.append(record)
                learn(record.message.originId)
                record.message.path.forEach(learn)
                recordRoutes[record.message.originId] = record.message.path
                onRecord?(record)
            }
        }
    }

    private func perform(_ actions: [RelayAction]) {
        for action in actions {
            switch action {
            case .send(let envelope, let neighbor):
                guard let payload = try? envelope.encoded() else { continue }
                // One outbox entry per message, so queued messages never replace each other.
                bluetooth.send(payload, type: .relayMessage, key: "relay:" + envelope.messageId.uuidString, to: neighbor)
            case .sendSummary(let summary, let neighbor):
                guard let payload = try? summary.encoded() else { continue }
                bluetooth.send(payload, type: .relaySummary, key: "relaySummary", to: neighbor)
            case .deliver(let delivery):
                deliver(delivery)
            }
        }
    }

    private func deliver(_ delivery: RelayDelivery) {
        let envelope = delivery.envelope
        learn(envelope.originId)
        envelope.path.forEach(learn)
        let id = MeshEventLog.short(envelope.messageId.uuidString)
        if envelope.isReceipt {
            if let confirmed = envelope.acknowledges, let index = sent.firstIndex(where: { $0.id == confirmed }) {
                sent[index].receipt = delivery
                let info = RelayReceiptInfo.decode(body: envelope.body)
                let delivered = info.map { ([selfId ?? ""] + $0.path).map(name).joined(separator: " → ") } ?? "?"
                log.note("relay", "receipt: \(MeshEventLog.short(confirmed.uuidString)) reached \(name(envelope.originId)) "
                         + "via \(delivered), age ≥ \(info?.ageMs ?? -1) ms; receipt came \(route(envelope)), \(delivery.hops) hop(s)")
            }
        } else if envelope.kind == BeaconPayload.kind, let beacon = BeaconPayload.decode(body: envelope.body) {
            var stats = beaconStats[envelope.originId].flatMap { $0.run == beacon.run ? $0 : nil }
                ?? BeaconStats(originId: envelope.originId, run: beacon.run)
            stats.record(envelope)
            beaconStats[envelope.originId] = stats
            log.note("t3", "received \(envelope.messageId.uuidString) \(envelope.body) from \(envelope.originId) "
                     + "path [\(envelope.path.joined(separator: ","))] ageMs \(envelope.ageMs) via \(name(delivery.fromNeighbor))")
        } else {
            received.insert(ReceivedMessage(delivery: delivery, arrivedAt: Date()), at: 0)
            if received.count > Self.maxListed { received.removeLast() }
            log.note("relay", "received \(id) \(envelope.kind) \(route(envelope)), \(delivery.hops) hop(s), "
                     + "age ≥ \(envelope.ageMs) ms, \(envelope.hopsRemaining) hops left, from \(name(delivery.fromNeighbor))")
        }
        onDelivery?(delivery)
    }

    private func learn(_ deviceId: String) {
        guard deviceId != selfId, knownPeers[deviceId] == nil else { return }
        knownPeers[deviceId] = ""
    }

    private func refresh() {
        if let records, recordStatistics != records.statistics { recordStatistics = records.statistics }
        guard let engine else {
            relayNeighbors = []
            return
        }
        if statistics != engine.statistics { statistics = engine.statistics }
        if storedCount != engine.storedCount { storedCount = engine.storedCount }
        let capable = linked.intersection(engine.relayCapable).sorted()
        if relayNeighbors != capable { relayNeighbors = capable }
    }
}

/// Timestamped mesh events for hardware test evidence: wall clock for reading, monotonic seconds
/// for measuring intervals on one phone. Main thread only.
final class MeshEventLog: ObservableObject {
    struct Entry: Identifiable {
        let id: Int
        let wallClock: Date
        let monotonic: TimeInterval
        let category: String
        let detail: String
    }

    static let capacity = 10_000

    @Published private(set) var entries: [Entry] = []
    private var nextId = 0

    static func short(_ id: String) -> String { String(id.prefix(8)) }

    func note(_ category: String, _ detail: String) {
        nextId += 1
        entries.append(Entry(id: nextId, wallClock: Date(), monotonic: MeshRelay.monotonicNow(), category: category, detail: detail))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    func clear() {
        entries.removeAll()
    }

    /// JSON lines: a header describing this phone and build, then one object per event.
    func export(deviceId: String?, label: String?) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let info = Bundle.main.infoDictionary ?? [:]
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let header: [String: Any] = [
            "type": "header",
            "deviceId": deviceId ?? "",
            "label": label ?? "",
            "model": model,
            "ios": UIDevice.current.systemVersion,
            "appVersion": info["CFBundleShortVersionString"] as? String ?? "",
            "build": info["CFBundleVersion"] as? String ?? "",
            "wireVersion": MeshProtocol.version,
            "relaySchema": RelayEnvelope.schemaVersion,
            "exportedAt": formatter.string(from: Date()),
            "monotonicAtExport": MeshRelay.monotonicNow(),
        ]
        let lines = [header] + entries.map { entry -> [String: Any] in
            ["t": formatter.string(from: entry.wallClock), "mono": (entry.monotonic * 1000).rounded() / 1000,
             "cat": entry.category, "event": entry.detail]
        }
        return lines.compactMap { line in
            (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
        }.joined(separator: "\n")
    }
}
