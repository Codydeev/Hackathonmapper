import Combine
import Foundation
import MeshCore
import UIKit

/// Store-and-forward messaging over the Bluetooth mesh: drives `RelayEngine` with frame types 5
/// and 6. `BluetoothMesh` owns it and starts and stops it with the mesh. Main thread only, like
/// `BluetoothMesh`.
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

    /// Every delivered message, receipts included, for modules that send their own kinds.
    var onDelivery: ((RelayDelivery) -> Void)?

    private unowned let bluetooth: BluetoothMesh
    private let log: MeshEventLog
    private var engine: RelayEngine?
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
        self.selfId = selfId
        isRunning = true
        linked = []
        sent = []
        received = []
        refresh()
    }

    func stop() {
        engine = nil
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
            log.note("relay", "neighbor gone \(name(neighbor))")
        }
        for neighbor in ready.subtracting(linked).sorted() {
            if let label = bluetooth.neighbors.first(where: { $0.deviceId == neighbor })?.label { knownPeers[neighbor] = label }
            learn(neighbor)
            perform(engine.neighborReady(neighbor, now: now))
        }
        linked = ready
        refresh()
    }

    func receive(_ frame: Frame, from neighbor: String) {
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
            sent.insert(SentMessage(envelope: envelope, sentAt: Date()), at: 0)
            if sent.count > Self.maxListed { sent.removeLast() }
            let copies = actions.filter { if case .send = $0 { return true } else { return false } }.count
            log.note("relay", "sent \(MeshEventLog.short(envelope.messageId.uuidString)) \(kind) to "
                     + "\(destination.map(name) ?? "everyone"), TTL \(ttlMs / 1000) s, \(hops) hops, "
                     + "\(copies) neighbor(s) now")
            perform(actions)
            refresh()
            return nil
        } catch {
            return "Message not sent: at most \(RelayEnvelope.maxBodyBytes) bytes, TTL up to \(RelayEnvelope.maxTTLMs / 60_000) min, 0–\(RelayEnvelope.maxHops) hops"
        }
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

    static let capacity = 2_000

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
