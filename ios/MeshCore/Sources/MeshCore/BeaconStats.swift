import Foundation

/// Body of a relay-test beacon: one per second from the sending phone, numbered within a run.
public struct BeaconPayload: Codable, Equatable {
    public static let kind = "t3.beacon"

    public let run: String
    public let seq: Int

    public init(run: String, seq: Int) {
        self.run = run
        self.seq = seq
    }

    public var body: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public static func decode(body: String) -> BeaconPayload? {
        try? JSONDecoder().decode(BeaconPayload.self, from: Data(body.utf8))
    }
}

/// What one phone received of another phone's beacon run, for test T3 (AC-3): delivery ratio,
/// routes, and ages. Delivery counts sequences from the first to the last one received, so beacons
/// lost after the last arrival only show against the sender's own count.
public struct BeaconStats: Equatable {
    public let originId: String
    public let run: String
    public private(set) var sequences = Set<Int>()
    /// `ageMs` of each received beacon, in arrival order.
    public private(set) var agesMs: [Int] = []
    /// Arrivals per relay path, joined with " > "; "" is a direct link.
    public private(set) var routes: [String: Int] = [:]
    /// Beacons delivered more than once: duplicate suppression failed.
    public private(set) var duplicates = 0

    public init(originId: String, run: String) {
        self.originId = originId
        self.run = run
    }

    /// Records a delivered envelope. False when it isn't a beacon of this run.
    @discardableResult
    public mutating func record(_ envelope: RelayEnvelope) -> Bool {
        guard envelope.kind == BeaconPayload.kind, envelope.originId == originId,
              let beacon = BeaconPayload.decode(body: envelope.body), beacon.run == run else { return false }
        guard sequences.insert(beacon.seq).inserted else {
            duplicates += 1
            return true
        }
        agesMs.append(envelope.ageMs)
        routes[Self.routeKey(envelope.path), default: 0] += 1
        return true
    }

    public static func routeKey(_ path: [String]) -> String { path.joined(separator: " > ") }

    public var received: Int { sequences.count }
    public var firstSequence: Int? { sequences.min() }
    public var lastSequence: Int? { sequences.max() }

    /// Beacons the sender must have sent between the first and last received.
    public var expected: Int {
        guard let first = firstSequence, let last = lastSequence else { return 0 }
        return last - first + 1
    }

    public var deliveryRatio: Double? {
        expected > 0 ? Double(received) / Double(expected) : nil
    }

    /// Share of received beacons that came over exactly `path`.
    public func share(of path: [String]) -> Double? {
        received > 0 ? Double(routes[Self.routeKey(path)] ?? 0) / Double(received) : nil
    }

    /// Nearest-rank percentile of the ages, 0...100.
    public func ageMs(percentile: Double) -> Int? {
        guard !agesMs.isEmpty else { return nil }
        let sorted = agesMs.sorted()
        let rank = Int((percentile / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }

    public var medianAgeMs: Int? { ageMs(percentile: 50) }
}
