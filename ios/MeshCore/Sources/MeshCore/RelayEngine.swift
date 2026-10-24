import Foundation

/// What the transport must do after the engine handled an event.
public enum RelayAction: Equatable {
    case send(RelayEnvelope, to: String)
    case sendSummary(RelaySummary, to: String)
    /// A message for this phone: addressed to it, or a broadcast.
    case deliver(RelayDelivery)
}

public struct RelayDelivery: Equatable {
    public let envelope: RelayEnvelope
    /// Neighbor the accepted copy arrived from.
    public let fromNeighbor: String
    /// Local monotonic time of arrival, in seconds.
    public let receivedAt: TimeInterval

    /// Links traversed: one more than the number of relays.
    public var hops: Int { envelope.path.count + 1 }
}

public struct RelayStatistics: Equatable {
    public var originated = 0
    /// New messages accepted from neighbors.
    public var accepted = 0
    public var delivered = 0
    /// Copies handed to the transport.
    public var sent = 0
    public var duplicates = 0
    /// Copies that already passed through this phone, including its own messages coming back.
    public var loops = 0
    public var expired = 0
    /// Accepted but not stored for forwarding because no hops remained.
    public var hopLimited = 0
    public var invalid = 0
    /// Stored messages dropped to make room.
    public var evicted = 0
    /// Stored messages dropped because a receipt confirmed their delivery.
    public var cleared = 0

    public init() {}
}

/// Store-and-forward relay for `RelayEnvelope`s: epidemic routing with summary vectors, bounded
/// by hop count, TTL and storage.
///
/// - A new message goes to every relay-capable neighbor except those it came through.
/// - Messages with hops and TTL left stay stored. When a link becomes ready both sides send a
///   `RelaySummary`, and each answers with the stored messages the other lacks. Summaries repeat
///   every `summaryInterval`, which repairs copies lost on a link that dropped mid-transfer.
/// - Message IDs are remembered for longer than any TTL, so every phone delivers a message once.
/// - The destination of a unicast message answers with a receipt; phones that relay or receive
///   the receipt drop their stored copy.
///
/// `now` is local monotonic time in seconds; it must not jump with the wall clock. Not thread
/// safe: use one instance from one thread.
public final class RelayEngine {
    public struct Configuration {
        public var maxStored = 256
        public var maxSeen = 4_096
        /// Longer than the largest TTL, so a late copy of a live message is still recognized.
        public var seenLifetime: TimeInterval = 20 * 60
        public var summaryInterval: TimeInterval = 10
        /// A copy sent to a neighbor this recently may still be in flight, so a summary that lacks
        /// it does not trigger a resend.
        public var resendGuard: TimeInterval = 5
        public var defaultTTLMs = 10 * 60_000
        public var defaultHops = 6
        public var sendsReceipts = true

        public init() {}
    }

    private struct Stored {
        /// The copy as accepted (or created), before this phone's forwarding changes.
        let envelope: RelayEnvelope
        let receivedAt: TimeInterval
        /// Phones known to have the message: where it came from, its origin and relays, and
        /// neighbors whose summary listed it.
        var knownBy: Set<String>
        var sentTo: [String: TimeInterval] = [:]
    }

    public let selfId: String
    public let configuration: Configuration
    public private(set) var statistics = RelayStatistics()
    /// Ready neighbors, as reported by the transport.
    public private(set) var neighbors = Set<String>()
    /// Neighbors that sent a relay frame, so they run the relay. Others never get envelopes.
    public private(set) var relayCapable = Set<String>()

    private var stored: [UUID: Stored] = [:]
    private var seen: [UUID: TimeInterval] = [:]
    private var seenOrder: [UUID] = []
    private var lastSummary: [String: TimeInterval] = [:]

    public init(selfId: String, configuration: Configuration = Configuration()) {
        self.selfId = selfId
        self.configuration = configuration
    }

    public var storedCount: Int { stored.count }
    public func isStored(_ messageId: UUID) -> Bool { stored[messageId] != nil }
    public func hasSeen(_ messageId: UUID) -> Bool { seen[messageId] != nil }

    // MARK: Origination

    /// Creates a message from this phone and sends it to every relay-capable neighbor. Kept for
    /// neighbors that appear later, until its TTL runs out or a receipt confirms delivery.
    public func originate(
        kind: String,
        body: String,
        to destinationId: String? = nil,
        ttlMs: Int? = nil,
        hops: Int? = nil,
        acknowledges: UUID? = nil,
        now: TimeInterval,
        wallClock: Date = Date()
    ) throws -> (RelayEnvelope, [RelayAction]) {
        let envelope = RelayEnvelope(
            originId: selfId,
            destinationId: destinationId,
            kind: kind,
            body: body,
            createdAt: (wallClock.timeIntervalSince1970 * 1000).rounded(),
            ttlMs: ttlMs ?? configuration.defaultTTLMs,
            hopsRemaining: hops ?? configuration.defaultHops,
            acknowledges: acknowledges
        )
        _ = try envelope.encoded()
        remember(envelope.messageId, at: now)
        statistics.originated += 1
        var actions: [RelayAction] = []
        store(Stored(envelope: envelope, receivedAt: now, knownBy: [selfId]), actions: &actions, now: now)
        return (envelope, actions)
    }

    // MARK: Receiving

    /// Handles a relay frame from a ready neighbor. Other frame types are ignored.
    public func receive(_ frame: Frame, from neighbor: String, now: TimeInterval) -> [RelayAction] {
        switch frame.type {
        case .relayMessage:
            guard let envelope = try? RelayEnvelope.decode(frame.payload) else {
                statistics.invalid += 1
                return []
            }
            return receive(envelope, from: neighbor, now: now)
        case .relaySummary:
            guard let summary = try? RelaySummary.decode(frame.payload) else {
                statistics.invalid += 1
                return []
            }
            return receive(summary, from: neighbor, now: now)
        default:
            return []
        }
    }

    public func receive(_ envelope: RelayEnvelope, from neighbor: String, now: TimeInterval) -> [RelayAction] {
        guard (try? envelope.validate()) != nil else {
            statistics.invalid += 1
            return []
        }
        relayCapable.insert(neighbor)
        let id = envelope.messageId
        guard envelope.originId != selfId, !envelope.path.contains(selfId) else {
            statistics.loops += 1
            stored[id]?.knownBy.insert(neighbor)
            return []
        }
        guard seen[id] == nil else {
            statistics.duplicates += 1
            stored[id]?.knownBy.insert(neighbor)
            return []
        }
        remember(id, at: now)
        guard !envelope.isExpired else {
            statistics.expired += 1
            return []
        }
        statistics.accepted += 1

        var actions: [RelayAction] = []
        if envelope.isReceipt, let confirmed = envelope.acknowledges {
            // Delivered: stop carrying the message, and don't accept a late copy of it.
            if stored.removeValue(forKey: confirmed) != nil { statistics.cleared += 1 }
            remember(confirmed, at: now)
        }
        let isForMe = envelope.destinationId == selfId
        if isForMe || envelope.destinationId == nil {
            statistics.delivered += 1
            actions.append(.deliver(RelayDelivery(envelope: envelope, fromNeighbor: neighbor, receivedAt: now)))
        }
        if isForMe {
            if configuration.sendsReceipts, !envelope.isReceipt {
                let info = RelayReceiptInfo(path: envelope.path, ageMs: envelope.ageMs)
                if let (_, receiptActions) = try? originate(
                    kind: RelayEnvelope.receiptKind, body: info.encodedBody(), to: envelope.originId,
                    ttlMs: envelope.ttlMs, acknowledges: id, now: now
                ) {
                    actions += receiptActions
                }
            }
            return actions
        }
        guard envelope.hopsRemaining > 0 else {
            statistics.hopLimited += 1
            return actions
        }
        let known = Set(envelope.path + [envelope.originId, neighbor])
        store(Stored(envelope: envelope, receivedAt: now, knownBy: known), actions: &actions, now: now)
        return actions
    }

    /// Answers a neighbor's summary with the stored messages it lacks.
    public func receive(_ summary: RelaySummary, from neighbor: String, now: TimeInterval) -> [RelayAction] {
        guard (try? summary.validate()) != nil else {
            statistics.invalid += 1
            return []
        }
        relayCapable.insert(neighbor)
        let has = Set(summary.have)
        var actions: [RelayAction] = []
        for id in storedIdsOldestFirst() {
            guard var entry = stored[id] else { continue }
            if has.contains(id) {
                entry.knownBy.insert(neighbor)
                stored[id] = entry
                continue
            }
            guard !entry.knownBy.contains(neighbor) else { continue }
            if let sentAt = entry.sentTo[neighbor], now - sentAt < configuration.resendGuard { continue }
            guard let copy = outgoingCopy(of: entry, now: now) else { continue }
            entry.sentTo[neighbor] = now
            stored[id] = entry
            statistics.sent += 1
            actions.append(.send(copy, to: neighbor))
        }
        return actions
    }

    // MARK: Topology and time

    /// A neighbor gained a ready link. Starts the summary exchange.
    public func neighborReady(_ neighbor: String, now: TimeInterval) -> [RelayAction] {
        neighbors.insert(neighbor)
        lastSummary[neighbor] = now
        return [.sendSummary(summary(), to: neighbor)]
    }

    public func neighborLost(_ neighbor: String) {
        neighbors.remove(neighbor)
        relayCapable.remove(neighbor)
        lastSummary[neighbor] = nil
    }

    /// Drops expired messages and old IDs, and repeats summaries. Call about once per second.
    public func tick(now: TimeInterval) -> [RelayAction] {
        for (id, entry) in stored where outgoingAgeMs(of: entry, now: now) >= entry.envelope.ttlMs {
            stored[id] = nil
            statistics.expired += 1
        }
        let cutoff = now - configuration.seenLifetime
        var expiredSeen = 0
        while expiredSeen < seenOrder.count, let firstSeen = seen[seenOrder[expiredSeen]], firstSeen < cutoff {
            seen[seenOrder[expiredSeen]] = nil
            expiredSeen += 1
        }
        seenOrder.removeFirst(expiredSeen)

        var actions: [RelayAction] = []
        for neighbor in neighbors.sorted() where now - (lastSummary[neighbor] ?? -.infinity) >= configuration.summaryInterval {
            lastSummary[neighbor] = now
            actions.append(.sendSummary(summary(), to: neighbor))
        }
        return actions
    }

    /// The most recently seen message IDs, newest first.
    public func summary() -> RelaySummary {
        RelaySummary(have: Array(seenOrder.suffix(RelaySummary.maxIds).reversed()))
    }

    public func reset() {
        statistics = RelayStatistics()
        neighbors.removeAll()
        relayCapable.removeAll()
        stored.removeAll()
        seen.removeAll()
        seenOrder.removeAll()
        lastSummary.removeAll()
    }

    // MARK: Internals

    private func store(_ entry: Stored, actions: inout [RelayAction], now: TimeInterval) {
        var entry = entry
        for neighbor in relayCapable.intersection(neighbors).sorted() where !entry.knownBy.contains(neighbor) {
            guard let copy = outgoingCopy(of: entry, now: now) else { break }
            entry.sentTo[neighbor] = now
            statistics.sent += 1
            actions.append(.send(copy, to: neighbor))
        }
        if stored.count >= configuration.maxStored {
            // Make room by dropping the message closest to expiry.
            let victim = stored.min { remainingMs(of: $0.value, now: now) < remainingMs(of: $1.value, now: now) }
            if let victim {
                stored[victim.key] = nil
                statistics.evicted += 1
            }
        }
        stored[entry.envelope.messageId] = entry
    }

    /// Age a copy sent now would carry: the age on arrival plus the time held here.
    private func outgoingAgeMs(of entry: Stored, now: TimeInterval) -> Int {
        entry.envelope.ageMs + Int((max(0, now - entry.receivedAt) * 1000).rounded())
    }

    private func remainingMs(of entry: Stored, now: TimeInterval) -> Int {
        entry.envelope.ttlMs - outgoingAgeMs(of: entry, now: now)
    }

    private func outgoingCopy(of entry: Stored, now: TimeInterval) -> RelayEnvelope? {
        let envelope = entry.envelope
        let age = outgoingAgeMs(of: entry, now: now)
        guard age < envelope.ttlMs else { return nil }
        if envelope.originId == selfId {
            return envelope.copy(ageMs: age, hopsRemaining: envelope.hopsRemaining, path: envelope.path)
        }
        return envelope.relayed(by: selfId, heldMs: age - envelope.ageMs)
    }

    private func storedIdsOldestFirst() -> [UUID] {
        stored.sorted { $0.value.receivedAt < $1.value.receivedAt }.map(\.key)
    }

    private func remember(_ id: UUID, at now: TimeInterval) {
        guard seen[id] == nil else { return }
        if seenOrder.count >= configuration.maxSeen {
            seen[seenOrder.removeFirst()] = nil
        }
        seen[id] = now
        seenOrder.append(id)
    }
}
