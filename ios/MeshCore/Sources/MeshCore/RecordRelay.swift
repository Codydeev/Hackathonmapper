import Foundation

/// A contract `RelayMessage` this phone accepted, as handed to the pipeline.
public struct ReceivedRecord: Equatable {
    /// The copy as it arrived; its `freshness.ageAtHandoff` includes every earlier hold.
    public let message: RelayMessage
    public let fromNeighbor: String
    /// Unix seconds on this phone's clock.
    public let receivedAt: Double
    /// Local monotonic seconds. The record's age now is
    /// `message.freshness.age(receivedAt: receivedAtMonotonic, now: <monotonic now>)`.
    public let receivedAtMonotonic: TimeInterval

    /// Links traversed: one more than the number of relays.
    public var hops: Int { message.path.count + 1 }
}

public enum RecordAction: Equatable {
    /// Queue `message` for `neighbor` under the outbox `key`; a newer message with the same key
    /// replaces a queued one. `droppable` messages may be skipped when the link is backed up.
    case send(RelayMessage, to: String, key: String, droppable: Bool)
    case deliver(ReceivedRecord)
}

public struct RecordRelayStatistics: Equatable {
    public var published = 0
    public var accepted = 0
    /// Copies handed to the transport.
    public var sent = 0
    public var duplicates = 0
    /// Copies that already passed through this phone, including its own records coming back.
    public var loops = 0
    /// Older sequence than the latest accepted, or from a retired epoch.
    public var outOfOrder = 0
    /// Already older than `maxAge` on arrival.
    public var stale = 0
    /// Stored records dropped because they aged past `maxAge`.
    public var expired = 0
    public var invalid = 0

    public init() {}
}

/// Carries GhostCore contract `RelayMessage`s (frame type 7) across the mesh.
///
/// - Positions, assessments and predictions are state: only the latest per origin and payload type
///   matters. They are ordered by epoch and sequence (a restart's new epoch retires the old one),
///   stored, and handed to neighbors that link later, with the time held added to `freshness`.
/// - Observation batches are events: deduplicated by `messageId` and forwarded, never stored.
/// - Every accepted record is delivered to this phone's pipeline and forwarded with
///   `RelayMessage.relayed(by:heldFor:)`, which refuses loops and spent hop budgets.
///
/// `now` is local monotonic seconds. Not thread safe: use one instance from one thread.
public final class RecordRelay {
    public struct Configuration {
        public var maxStreams = 512
        public var maxSeen = 4_096
        public var seenLifetime: TimeInterval = 10 * 60
        /// Retired epochs remembered per origin.
        public var maxRetiredEpochs = 100

        public init() {}
    }

    private struct Stream: Hashable {
        let originId: String
        let type: String
    }

    private struct Latest {
        let message: RelayMessage
        let receivedAt: TimeInterval
        /// Neighbor it came from; this phone's ID for its own records.
        let source: String
    }

    public let selfId: String
    public let configuration: Configuration
    public private(set) var statistics = RecordRelayStatistics()
    public private(set) var neighbors = Set<String>()

    private var latest: [Stream: Latest] = [:]
    private var currentEpoch: [String: String] = [:]
    private var retiredEpochs: [String: [String]] = [:]
    private var seen: [String: TimeInterval] = [:]
    private var seenOrder: [String] = []

    public init(selfId: String, configuration: Configuration = Configuration()) {
        self.selfId = selfId
        self.configuration = configuration
    }

    public var storedCount: Int { latest.count }

    /// The stored latest record of `type` ("position", "integrity", "prediction") from `originId`.
    public func latest(from originId: String, type: String) -> RelayMessage? {
        latest[Stream(originId: originId, type: type)]?.message
    }

    public static func payloadType(_ payload: RelayMessage.Payload) -> String {
        switch payload {
        case .position: return "position"
        case .integrity: return "integrity"
        case .prediction: return "prediction"
        case .observations: return "observations"
        }
    }

    /// Outbox key: one queued message per origin and type, so a slow link sends only the newest.
    public static func outboxKey(_ message: RelayMessage) -> String {
        let type = payloadType(message.payload)
        guard type == "observations" else { return "record:\(message.originId):\(type)" }
        return "record:\(message.originId):observations:\(message.messageId)"
    }

    // MARK: Events

    /// Sends one of this phone's records, built by the pipeline, to every ready neighbor.
    public func publish(_ message: RelayMessage, now: TimeInterval) throws -> [RecordAction] {
        guard message.originId == selfId, message.path.isEmpty else { throw GhostCoreContractError.invalid("originId") }
        _ = try message.encoded()
        guard seen[message.messageId] == nil else { return [] }
        remember(message.messageId, at: now)
        statistics.published += 1
        if isState(message) {
            let stream = Stream(originId: selfId, type: Self.payloadType(message.payload))
            if let previous = latest[stream], previous.message.epochId == message.epochId,
               previous.message.sequence >= message.sequence {
                throw GhostCoreContractError.invalid("sequence")
            }
            store(message, stream: stream, receivedAt: now, source: selfId)
        }
        return neighbors.sorted().map { send(message, to: $0) }
    }

    public func receive(_ frame: Frame, from neighbor: String, now: TimeInterval, wallClock: Double) -> [RecordAction] {
        guard frame.type == .record else { return [] }
        guard let message = try? RelayMessage.decode(frame.payload) else {
            statistics.invalid += 1
            return []
        }
        return receive(message, from: neighbor, now: now, wallClock: wallClock)
    }

    public func receive(_ message: RelayMessage, from neighbor: String, now: TimeInterval, wallClock: Double) -> [RecordAction] {
        guard (try? message.validate()) != nil else {
            statistics.invalid += 1
            return []
        }
        guard message.originId != selfId, !message.path.contains(selfId) else {
            statistics.loops += 1
            return []
        }
        guard seen[message.messageId] == nil else {
            statistics.duplicates += 1
            return []
        }
        remember(message.messageId, at: now)
        guard message.freshness.ageAtHandoff <= message.freshness.maxAge else {
            statistics.stale += 1
            return []
        }
        if isState(message) {
            guard acceptsOrder(message) else {
                statistics.outOfOrder += 1
                return []
            }
            store(message, stream: Stream(originId: message.originId, type: Self.payloadType(message.payload)),
                  receivedAt: now, source: neighbor)
        }
        statistics.accepted += 1
        var actions: [RecordAction] = [.deliver(ReceivedRecord(
            message: message, fromNeighbor: neighbor, receivedAt: wallClock, receivedAtMonotonic: now))]
        if let copy = message.relayed(by: selfId, heldFor: 0) {
            for target in neighbors.sorted() where target != neighbor && target != message.originId && !message.path.contains(target) {
                statistics.sent += 1
                actions.append(.send(copy, to: target, key: Self.outboxKey(copy), droppable: !isState(copy)))
            }
        }
        return actions
    }

    /// A neighbor gained a ready link: hand it every stored record it may not have.
    public func neighborReady(_ neighbor: String, now: TimeInterval) -> [RecordAction] {
        neighbors.insert(neighbor)
        var actions: [RecordAction] = []
        for entry in latest.values.sorted(by: { $0.receivedAt < $1.receivedAt }) {
            let message = entry.message
            guard entry.source != neighbor, message.originId != neighbor, !message.path.contains(neighbor),
                  !message.freshness.isStale(receivedAt: entry.receivedAt, now: now) else { continue }
            let held = max(0, now - entry.receivedAt)
            let copy: RelayMessage?
            if message.originId == selfId {
                copy = RelayMessage(messageId: message.messageId, originId: message.originId, epochId: message.epochId,
                                    sequence: message.sequence, timestamp: message.timestamp, frameId: message.frameId,
                                    hopsRemaining: message.hopsRemaining, path: message.path,
                                    freshness: message.freshness.handedOn(heldFor: held), payload: message.payload)
            } else {
                copy = message.relayed(by: selfId, heldFor: held)
            }
            guard let copy else { continue }
            statistics.sent += 1
            actions.append(.send(copy, to: neighbor, key: Self.outboxKey(copy), droppable: false))
        }
        return actions
    }

    public func neighborLost(_ neighbor: String) {
        neighbors.remove(neighbor)
    }

    /// Drops stored records past their `maxAge` and old message IDs. Call about once per second.
    public func tick(now: TimeInterval) {
        for (stream, entry) in latest where entry.message.freshness.isStale(receivedAt: entry.receivedAt, now: now) {
            latest[stream] = nil
            statistics.expired += 1
        }
        let cutoff = now - configuration.seenLifetime
        var expiredSeen = 0
        while expiredSeen < seenOrder.count, let firstSeen = seen[seenOrder[expiredSeen]], firstSeen < cutoff {
            seen[seenOrder[expiredSeen]] = nil
            expiredSeen += 1
        }
        seenOrder.removeFirst(expiredSeen)
    }

    public func reset() {
        statistics = RecordRelayStatistics()
        neighbors.removeAll()
        latest.removeAll()
        currentEpoch.removeAll()
        retiredEpochs.removeAll()
        seen.removeAll()
        seenOrder.removeAll()
    }

    // MARK: Internals

    private func isState(_ message: RelayMessage) -> Bool {
        if case .observations = message.payload { return false }
        return true
    }

    private func send(_ message: RelayMessage, to neighbor: String) -> RecordAction {
        statistics.sent += 1
        return .send(message, to: neighbor, key: Self.outboxKey(message), droppable: !isState(message))
    }

    /// Same epoch: only a higher sequence. A new epoch retires the origin's previous one, whose
    /// records are dropped; a retired epoch is never accepted again.
    private func acceptsOrder(_ message: RelayMessage) -> Bool {
        let origin = message.originId
        if retiredEpochs[origin]?.contains(message.epochId) == true { return false }
        guard let current = currentEpoch[origin] else { return true }
        if current == message.epochId {
            let stream = Stream(originId: origin, type: Self.payloadType(message.payload))
            return latest[stream].map { message.sequence > $0.message.sequence } ?? true
        }
        return true
    }

    private func store(_ message: RelayMessage, stream: Stream, receivedAt: TimeInterval, source: String) {
        let origin = message.originId
        if let current = currentEpoch[origin], current != message.epochId {
            var retired = retiredEpochs[origin] ?? []
            retired.append(current)
            if retired.count > configuration.maxRetiredEpochs { retired.removeFirst() }
            retiredEpochs[origin] = retired
            latest = latest.filter { $0.key.originId != origin }
        }
        currentEpoch[origin] = message.epochId
        if latest[stream] == nil, latest.count >= configuration.maxStreams,
           let oldest = latest.min(by: { $0.value.receivedAt < $1.value.receivedAt }) {
            latest[oldest.key] = nil
        }
        latest[stream] = Latest(message: message, receivedAt: receivedAt, source: source)
    }

    private func remember(_ id: String, at now: TimeInterval) {
        guard seen[id] == nil else { return }
        if seenOrder.count >= configuration.maxSeen {
            seen[seenOrder.removeFirst()] = nil
        }
        seen[id] = now
        seenOrder.append(id)
    }
}
